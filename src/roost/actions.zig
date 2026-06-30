//! Wired actions — user-defined commands that run and route their output (by
//! exit code) into a pane. The product thesis: wiring tooling into the agent.
//!
//! ADDITIVE and entirely our own, and deliberately **std-only** (no GTK / no
//! Ghostty internals) so it unit-tests standalone like `md.zig`. The async
//! RUNNER and the routing live in `app.zig` / `tree.zig` / `ipc.zig`; this file
//! is just the data model + JSON load/merge.
//!
//! Two files, merged: a GLOBAL `<xdg-config>/roost/actions.json` and a per-repo
//! `<project>/.roost/actions.json`. Per-repo entries OVERRIDE global by `label`;
//! new ones append. Either file may be absent or malformed → it's skipped (we
//! never fail), mirroring `config.zig`'s tolerance. JSON shape:
//!
//!   { "actions": [
//!     { "label": "Run tests", "command": "composer pub crawl",
//!       "pin": true, "route": "agent",
//!       "on_success": "notify", "on_failure": "agent" }
//!   ] }

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.roost_actions);

/// Where an action's output is routed. `none` discards it.
pub const Route = enum { agent, shell, scratchpad, notify, none };

/// One user-defined action. String fields are owned by the allocator passed to
/// `load`/`parse`; free the whole list with `freeActions`.
pub const Action = struct {
    /// Display name + the key used to dedupe global vs per-repo. Required.
    label: []const u8,
    /// Shell command line, run via `/bin/sh -c <command>`. Required.
    command: []const u8,
    /// Working directory; null → the project root (filled by the runner).
    cwd: ?[]const u8 = null,
    /// Bundled symbolic icon name (reserved; the header lists actions in a single
    /// dropdown by label now, not per-action icon buttons). null → unused.
    icon: ?[]const u8 = null,
    /// Default route, used for whichever of success/failure has no override.
    route: Route = .notify,
    /// Route when the command exits 0 (overrides `route`).
    on_success: ?Route = null,
    /// Route when the command exits non-zero (overrides `route`).
    on_failure: ?Route = null,

    /// The route to use for a finished run with exit `code`.
    pub fn routeFor(self: Action, code: u8) Route {
        return if (code == 0)
            (self.on_success orelse self.route)
        else
            (self.on_failure orelse self.route);
    }
};

/// The top-level JSON object. `actions` defaults to empty so `{}` or a file with
/// no `actions` key parses cleanly.
const Root = struct { actions: []Action = &.{} };

/// Load + merge the global and per-repo action files. `config_dir` is the
/// resolved `<xdg-config>/roost` (null skips the global file); `project_path` is
/// the repo root (empty skips the per-repo file). Never fails: a missing or
/// malformed file is logged and skipped. The returned list is owned by `alloc`
/// (free with `freeActions`).
pub fn load(alloc: Allocator, config_dir: ?[]const u8, project_path: []const u8) []Action {
    const global = readFromDir(alloc, config_dir, "actions.json");
    defer freeActions(alloc, global);
    const repo = readFromDir(alloc, if (project_path.len > 0) project_path else null, ".roost" ++ std.fs.path.sep_str ++ "actions.json");
    defer freeActions(alloc, repo);
    // `load` owns `global`/`repo` cleanup (the defers above) on every path;
    // `merge` deep-copies into an independently-owned result, so there is no
    // shared ownership to double-free if merge errors mid-way.
    return merge(alloc, global, repo) catch &.{};
}

/// Read `<dir>/<rel>` and parse it; any error (no dir, missing file, bad JSON)
/// yields an empty list. Owned by `alloc`.
fn readFromDir(alloc: Allocator, dir: ?[]const u8, rel: []const u8) []Action {
    const d = dir orelse return &.{};
    const path = std.fs.path.join(alloc, &.{ d, rel }) catch return &.{};
    defer alloc.free(path);
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 256 * 1024) catch |err| {
        if (err != error.FileNotFound) log.warn("could not read actions '{s}' err={}", .{ path, err });
        return &.{};
    };
    defer alloc.free(bytes);
    return parse(alloc, bytes) catch |err| {
        log.warn("could not parse actions '{s}' err={}", .{ path, err });
        return &.{};
    };
}

/// Parse one actions JSON document into an owned, validated list. Entries with
/// an empty `label` or `command` are skipped. Unknown keys are ignored so an
/// older binary tolerates a newer file. Owned by `alloc` (free with
/// `freeActions`).
pub fn parse(alloc: Allocator, bytes: []const u8) ![]Action {
    const parsed = try std.json.parseFromSlice(Root, alloc, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged(Action) = .empty;
    errdefer {
        for (list.items) |a| freeAction(alloc, a);
        list.deinit(alloc);
    }
    for (parsed.value.actions) |a| {
        if (a.label.len == 0 or a.command.len == 0) {
            log.warn("skipping action with empty label/command", .{});
            continue;
        }
        try list.append(alloc, try dupAction(alloc, a));
    }
    return list.toOwnedSlice(alloc);
}

/// Merge `global` and `repo` into a fresh owned list: repo entries override a
/// global entry of the same label, then any new repo entries append. This
/// DEEP-COPIES the kept entries — it does NOT take ownership of the inputs (the
/// caller still owns and frees `global`/`repo`). Returned list owned by `alloc`
/// (free with `freeActions`); on error the partial result is freed here.
fn merge(alloc: Allocator, global: []Action, repo: []Action) ![]Action {
    var list: std.ArrayListUnmanaged(Action) = .empty;
    errdefer {
        for (list.items) |a| freeAction(alloc, a);
        list.deinit(alloc);
    }

    // Global entries, unless a repo entry overrides the same label.
    for (global) |g| {
        if (!hasLabel(repo, g.label)) try list.append(alloc, try dupAction(alloc, g));
    }
    // All repo entries append (and win on conflicts, handled above).
    for (repo) |r| try list.append(alloc, try dupAction(alloc, r));

    return list.toOwnedSlice(alloc);
}

fn hasLabel(actions: []const Action, label: []const u8) bool {
    for (actions) |a| if (std.mem.eql(u8, a.label, label)) return true;
    return false;
}

/// Deep-copy `a`'s owned strings into `alloc`.
fn dupAction(alloc: Allocator, a: Action) !Action {
    var out = a;
    out.label = try alloc.dupe(u8, a.label);
    errdefer alloc.free(out.label);
    out.command = try alloc.dupe(u8, a.command);
    errdefer alloc.free(out.command);
    out.cwd = if (a.cwd) |c| try alloc.dupe(u8, c) else null;
    errdefer if (out.cwd) |c| alloc.free(c);
    out.icon = if (a.icon) |i| try alloc.dupe(u8, i) else null;
    return out;
}

fn freeAction(alloc: Allocator, a: Action) void {
    alloc.free(a.label);
    alloc.free(a.command);
    if (a.cwd) |c| alloc.free(c);
    if (a.icon) |i| alloc.free(i);
}

/// Free a list produced by `load`/`parse`. Safe on an empty (`&.{}`) list.
pub fn freeActions(alloc: Allocator, actions: []const Action) void {
    if (actions.len == 0) return;
    for (actions) |a| freeAction(alloc, a);
    alloc.free(actions);
}

// ---------------------------------------------------------------------------
// Tests (pure: run with `zig test src/roost/actions.zig`)
// ---------------------------------------------------------------------------

test "parse: fields, defaults, and enum routes" {
    const alloc = std.testing.allocator;
    const json =
        \\{ "actions": [
        \\  { "label": "Run tests", "command": "composer pub crawl",
        \\    "pin": true, "route": "agent",
        \\    "on_success": "notify", "on_failure": "agent" },
        \\  { "label": "Bare", "command": "echo hi" }
        \\] }
    ;
    const list = try parse(alloc, json);
    defer freeActions(alloc, list);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("Run tests", list[0].label);
    try std.testing.expectEqualStrings("composer pub crawl", list[0].command);
    try std.testing.expectEqual(Route.agent, list[0].route);
    try std.testing.expectEqual(Route.notify, list[0].on_success.?);
    try std.testing.expectEqual(Route.agent, list[0].on_failure.?);
    // routeFor: success → on_success, failure → on_failure.
    try std.testing.expectEqual(Route.notify, list[0].routeFor(0));
    try std.testing.expectEqual(Route.agent, list[0].routeFor(1));

    // Defaults on the bare entry.
    try std.testing.expectEqual(Route.notify, list[1].route);
    try std.testing.expectEqual(@as(?Route, null), list[1].on_success);
    // routeFor falls back to `route` for both.
    try std.testing.expectEqual(Route.notify, list[1].routeFor(0));
    try std.testing.expectEqual(Route.notify, list[1].routeFor(1));
}

test "parse: skips empty label/command and ignores unknown keys" {
    const alloc = std.testing.allocator;
    const json =
        \\{ "actions": [
        \\  { "label": "", "command": "x" },
        \\  { "label": "y", "command": "" },
        \\  { "label": "ok", "command": "true", "bogus_key": 42 }
        \\] }
    ;
    const list = try parse(alloc, json);
    defer freeActions(alloc, list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("ok", list[0].label);
}

test "merge: per-repo overrides global by label, new ones append" {
    const alloc = std.testing.allocator;
    const global = try parse(alloc,
        \\{ "actions": [
        \\  { "label": "tests", "command": "global-tests", "route": "notify" },
        \\  { "label": "lint",  "command": "global-lint" }
        \\] }
    );
    defer freeActions(alloc, global);
    const repo = try parse(alloc,
        \\{ "actions": [
        \\  { "label": "tests", "command": "repo-tests", "route": "agent" },
        \\  { "label": "deploy", "command": "repo-deploy" }
        \\] }
    );
    defer freeActions(alloc, repo);
    const merged = try merge(alloc, global, repo);
    defer freeActions(alloc, merged);

    // lint (global only), tests (repo wins), deploy (repo only).
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("lint", merged[0].label);
    try std.testing.expectEqualStrings("tests", merged[1].label);
    try std.testing.expectEqualStrings("repo-tests", merged[1].command); // overridden
    try std.testing.expectEqual(Route.agent, merged[1].route);
    try std.testing.expectEqualStrings("deploy", merged[2].label);
}

test "parse: empty / no actions key" {
    const alloc = std.testing.allocator;
    const a = try parse(alloc, "{}");
    defer freeActions(alloc, a);
    try std.testing.expectEqual(@as(usize, 0), a.len);
}
