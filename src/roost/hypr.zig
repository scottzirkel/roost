//! Hyprland, for putting reopened windows back on their workspaces.
//!
//! `roost close --all` notes each window's workspace from `hyprctl clients
//! -j`. `roost reopen` adds a named window rule per window before starting
//! it, matched on the window's first title ("Roost — <project>", plus
//! " · <branch>" in a repo), so it opens on its workspace without taking
//! focus. Once the windows are up, it moves any the rule missed, then turns
//! the rules off. Rules and moves use Hyprland's Lua API (`hyprctl eval` and
//! `hyprctl dispatch`), as Omarchy's own scripts do (Hyprland 0.56).
//!
//! Optional: without Hyprland, `available` is false and nothing here runs.
//! Not in `core/`: it's this desktop, not Roost's portable logic. Std-only,
//! so it's unit-tested like `cli.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The window class every Roost window has.
const class = "dev.scottzirkel.Roost";

pub fn available() bool {
    const sig = std.posix.getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse return false;
    return sig.len > 0;
}

/// Each Roost window's workspace, by pid, as a workspace spec (`workspaceSpec`).
pub const Workspaces = std.AutoHashMapUnmanaged(i32, []const u8);

/// Ask Hyprland where every Roost window is. Empty when it can't say.
pub fn roostWorkspaces(arena: Allocator) Workspaces {
    const json = run(arena, &.{ "hyprctl", "clients", "-j" }) orelse return .empty;
    return parseClients(arena, json);
}

/// The Roost windows in `hyprctl clients -j` output, by pid.
pub fn parseClients(arena: Allocator, json: []const u8) Workspaces {
    var map: Workspaces = .empty;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return map;
    const clients = switch (value) {
        .array => |a| a.items,
        else => return map,
    };
    for (clients) |c| {
        const obj = switch (c) {
            .object => |o| o,
            else => continue,
        };
        const cls = str(obj.get("class")) orelse continue;
        if (!std.mem.eql(u8, cls, class)) continue;
        const pid = int(obj.get("pid")) orelse continue;
        const ws = switch (obj.get("workspace") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const spec = workspaceSpec(arena, int(ws.get("id")) orelse 0, str(ws.get("name")) orelse "") orelse continue;
        map.put(arena, @intCast(pid), spec) catch {};
    }
    return map;
}

fn str(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn int(v: ?std.json.Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

/// How to name a workspace to Hyprland: its number when it has one, else
/// `special:<name>` as is, else `name:<name>`. Null when there's nothing.
pub fn workspaceSpec(arena: Allocator, id: i64, name: []const u8) ?[]const u8 {
    if (id > 0) return std.fmt.allocPrint(arena, "{d}", .{id}) catch null;
    if (name.len == 0) return null;
    if (std.mem.startsWith(u8, name, "special:")) return arena.dupe(u8, name) catch null;
    return std.fmt.allocPrint(arena, "name:{s}", .{name}) catch null;
}

/// `s` as a Lua string literal.
fn luaString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"', '\\' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// A regex matching the first title of a window on project `name`.
fn titlePattern(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("^Roost — ");
    for (name) |c| {
        if (c < 0x80 and !std.ascii.isAlphanumeric(c) and c != ' ' and c != '_') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeAll("( · .*)?$");
}

/// Lua for `hyprctl eval`: turn on rule `rule` sending project `name`'s new
/// window to workspace `spec`, quietly.
pub fn ruleExpr(arena: Allocator, rule: []const u8, name: []const u8, spec: []const u8) ?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var pattern: std.Io.Writer.Allocating = .init(arena);
    titlePattern(&pattern.writer, name) catch return null;
    var ws: std.Io.Writer.Allocating = .init(arena);
    ws.writer.print("{s} silent", .{spec}) catch return null;
    w.writeAll("hl.window_rule({ name = ") catch return null;
    luaString(w, rule) catch return null;
    w.print(", enabled = true, match = {{ class = \"{s}\", initial_title = ", .{class}) catch return null;
    luaString(w, pattern.written()) catch return null;
    w.writeAll(" }, workspace = ") catch return null;
    luaString(w, ws.written()) catch return null;
    w.writeAll(", no_initial_focus = true })") catch return null;
    return out.written();
}

/// Lua for `hyprctl eval`: turn rule `rule` off.
pub fn disableExpr(arena: Allocator, rule: []const u8) ?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("hl.window_rule({ name = ") catch return null;
    luaString(&out.writer, rule) catch return null;
    out.writer.writeAll(", enabled = false })") catch return null;
    return out.written();
}

/// Lua for `hyprctl dispatch`: move window `pid` to workspace `spec`, without
/// following it there.
pub fn moveExpr(arena: Allocator, pid: i32, spec: []const u8) ?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("hl.dsp.window.move({ workspace = ") catch return null;
    luaString(&out.writer, spec) catch return null;
    out.writer.print(", follow = false, window = \"pid:{d}\" }})", .{pid}) catch return null;
    return out.written();
}

pub fn eval(arena: Allocator, lua: []const u8) bool {
    return ok(run(arena, &.{ "hyprctl", "eval", lua }));
}

pub fn dispatch(arena: Allocator, lua: []const u8) bool {
    return ok(run(arena, &.{ "hyprctl", "dispatch", lua }));
}

fn ok(reply: ?[]const u8) bool {
    const r = reply orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, r, " \t\r\n"), "ok");
}

/// Run `argv` and return its stdout, or null when it fails.
fn run(arena: Allocator, argv: []const []const u8) ?[]const u8 {
    const result = std.process.Child.run(.{ .allocator = arena, .argv = argv, .max_output_bytes = 4 * 1024 * 1024 }) catch return null;
    if (result.term != .Exited or result.term.Exited != 0) return null;
    return result.stdout;
}

// ---------------------------------------------------------------------------
// Tests (run with `zig test src/roost/hypr.zig`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseClients: Roost windows only, with their workspace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const map = parseClients(a,
        \\[{"pid":10,"class":"dev.scottzirkel.Roost","workspace":{"id":3,"name":"3"}},
        \\ {"pid":11,"class":"firefox","workspace":{"id":1,"name":"1"}},
        \\ {"pid":12,"class":"dev.scottzirkel.Roost","workspace":{"id":-98,"name":"special:scratch"}},
        \\ {"pid":13,"class":"dev.scottzirkel.Roost","workspace":{"id":-1337,"name":"notes"}}]
    );
    try testing.expectEqual(@as(u32, 3), map.count());
    try testing.expectEqualStrings("3", map.get(10).?);
    try testing.expectEqualStrings("special:scratch", map.get(12).?);
    try testing.expectEqualStrings("name:notes", map.get(13).?);
    try testing.expectEqual(@as(u32, 0), parseClients(a, "not json").count());
}

test "ruleExpr: a quiet, named rule matching the project's first title" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const expr = ruleExpr(arena.allocator(), "roost-reopen-0", "my.app", "3").?;
    try testing.expectEqualStrings(
        \\hl.window_rule({ name = "roost-reopen-0", enabled = true, match = { class = "dev.scottzirkel.Roost", initial_title = "^Roost — my\\.app( · .*)?$" }, workspace = "3 silent", no_initial_focus = true })
    , expr);
}

test "titlePattern: matches the title with and without a branch, and nothing else" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try titlePattern(&w, "a+b (1)");
    try testing.expectEqualStrings("^Roost — a\\+b \\(1\\)( · .*)?$", w.buffered());
}

test "disableExpr and moveExpr" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("hl.window_rule({ name = \"roost-reopen-2\", enabled = false })", disableExpr(a, "roost-reopen-2").?);
    try testing.expectEqualStrings("hl.dsp.window.move({ workspace = \"name:my \\\"ws\\\"\", follow = false, window = \"pid:42\" })", moveExpr(a, 42, "name:my \"ws\"").?);
}
