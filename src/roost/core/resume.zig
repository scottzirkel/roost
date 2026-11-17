//! Picking an Agent pane's conversation back up, and the windows `roost close
//! --all` closed, for `roost reopen`.
//!
//! An Agent pane's Claude session is saved in the project's layout file as
//! soon as its hooks report it, so it survives a quit or a crash. How the
//! pane comes back depends on why it's starting:
//!   - a reload, or `roost reopen`: resume straight away, as the user just
//!     asked for the windows back;
//!   - opening the project: ask in the pane first, since an old conversation
//!     isn't always wanted;
//!   - no saved session: start fresh.
//! Either way `claude --resume <id> || claude` starts fresh when Claude can't
//! find the session.
//!
//! Plain std, so a Mac Roost can use it too.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How an Agent pane with a saved session starts.
pub const Mode = enum { fresh, resume_now, ask };

/// The shell command for an Agent pane running `cmd` with saved `session`.
/// `session` must be a valid session id (letters, digits, dashes), which is
/// safe in the shell as is.
pub fn command(buf: []u8, cmd: []const u8, session: []const u8, mode: Mode) ?[:0]const u8 {
    return switch (mode) {
        .fresh => std.fmt.bufPrintZ(buf, "{s}", .{cmd}) catch null,
        .resume_now => std.fmt.bufPrintZ(buf, "{s} --resume {s} || {s}", .{ cmd, session, cmd }) catch null,
        // Enter resumes; "n" starts fresh. `exec` so the agent is the pane's
        // process either way, as it is without the question.
        .ask => std.fmt.bufPrintZ(
            buf,
            "printf '\\nResume your last conversation in this pane? [Y/n] '; read -r roost_answer; " ++
                "case \"$roost_answer\" in [nN]*) exec {s} ;; esac; {s} --resume {s} || exec {s}",
            .{ cmd, cmd, session, cmd },
        ) catch null,
    };
}

/// The windows `roost close --all` closed, in the order `roost status --all`
/// listed them.
pub const Closed = struct {
    windows: []const Window = &.{},

    pub const Window = struct {
        project: []const u8,
        /// Where the window was, for the desktop to put it back: a Hyprland
        /// workspace spec ("3", "name:notes"), or "" when unknown.
        workspace: []const u8 = "",
    };

    pub fn write(self: Closed, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.json.Stringify.value(self, .{}, w);
        try w.writeByte('\n');
    }

    /// Parse the file's text. Allocations live in `arena`. Also reads the
    /// first format, a bare `projects` list.
    pub fn parse(arena: Allocator, text: []const u8) !Closed {
        const File = struct {
            windows: []const Window = &.{},
            projects: []const []const u8 = &.{},
        };
        const f = try std.json.parseFromSliceLeaky(File, arena, text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        if (f.windows.len > 0 or f.projects.len == 0) return .{ .windows = f.windows };
        const list = try arena.alloc(Window, f.projects.len);
        for (f.projects, list) |p, *w| w.* = .{ .project = p };
        return .{ .windows = list };
    }
};

/// The saved list at `path`, or an empty one when there's none or it can't
/// be read. Allocations live in `arena`.
pub fn loadClosed(arena: Allocator, path: []const u8) Closed {
    const text = std.fs.cwd().readFileAlloc(arena, path, 1024 * 1024) catch return .{};
    return Closed.parse(arena, text) catch .{};
}

/// Where `Closed` is kept: `$XDG_STATE_HOME/roost/closed-windows.json`, else
/// under `~/.local/state`. In state, not runtime, so it survives a reboot.
pub fn closedPath(arena: Allocator, state_home: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    if (state_home) |s| if (s.len > 0) return std.fs.path.join(arena, &.{ s, "roost", "closed-windows.json" }) catch null;
    const h = home orelse return null;
    if (h.len == 0) return null;
    return std.fs.path.join(arena, &.{ h, ".local", "state", "roost", "closed-windows.json" }) catch null;
}

// ---------------------------------------------------------------------------
// Tests (run with `zig test src/roost/core/resume.zig`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "command: fresh, resume, or ask first" {
    var buf: [512]u8 = undefined;
    const id = "0b5c2f8e-1234-4abc-9def-000000000001";
    try testing.expectEqualStrings("claude", command(&buf, "claude", id, .fresh).?);
    try testing.expectEqualStrings("claude --resume " ++ id ++ " || claude", command(&buf, "claude", id, .resume_now).?);
    const ask = command(&buf, "claude --model x", id, .ask).?;
    try testing.expect(std.mem.indexOf(u8, ask, "[Y/n]") != null);
    try testing.expect(std.mem.indexOf(u8, ask, "[nN]*) exec claude --model x ;;") != null);
    try testing.expect(std.mem.endsWith(u8, ask, "claude --model x --resume " ++ id ++ " || exec claude --model x"));
    var tiny: [8]u8 = undefined;
    try testing.expectEqual(@as(?[:0]const u8, null), command(&tiny, "claude", id, .ask));
}

test "command: the question runs in a real shell" {
    // Answer "n", then "" (Enter), against a fake agent that prints its args.
    var buf: [512]u8 = undefined;
    const cmd = command(&buf, "echo agent", "abc-123", .ask).?;
    inline for (.{ .{ "n\n", "agent\n" }, .{ "\n", "agent --resume abc-123\n" } }) |c| {
        var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd }, testing.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        try child.spawn();
        try child.stdin.?.writeAll(c[0]);
        child.stdin.?.close();
        child.stdin = null;
        const out = try child.stdout.?.readToEndAlloc(testing.allocator, 4096);
        defer testing.allocator.free(out);
        _ = try child.wait();
        try testing.expect(std.mem.endsWith(u8, out, c[1]));
    }
}

test "closed: round-trips, reads the first format, and tolerates newer fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try (Closed{ .windows = &.{ .{ .project = "/home/me/app", .workspace = "3" }, .{ .project = "/home/me/my \"site\"" } } }).write(&w);
    const back = try Closed.parse(a, w.buffered());
    try testing.expectEqual(@as(usize, 2), back.windows.len);
    try testing.expectEqualStrings("3", back.windows[0].workspace);
    try testing.expectEqualStrings("/home/me/my \"site\"", back.windows[1].project);
    try testing.expectEqualStrings("", back.windows[1].workspace);
    const first = try Closed.parse(a, "{\"projects\":[\"/p\",\"/q\"]}");
    try testing.expectEqualStrings("/q", first.windows[1].project);
    const newer = try Closed.parse(a, "{\"windows\":[{\"project\":\"/p\",\"monitor\":\"DP-1\"}],\"version\":2}");
    try testing.expectEqualStrings("/p", newer.windows[0].project);
    try testing.expectEqual(@as(usize, 0), (try Closed.parse(a, "{}")).windows.len);
}

test "loadClosed: the file's windows, or none" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(.{ .sub_path = "c.json", .data = "{\"windows\":[{\"project\":\"/p\"}]}" });
    try tmp.dir.writeFile(.{ .sub_path = "bad.json", .data = "nope" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buf);
    try testing.expectEqual(@as(usize, 1), loadClosed(a, try std.fs.path.join(a, &.{ dir, "c.json" })).windows.len);
    try testing.expectEqual(@as(usize, 0), loadClosed(a, try std.fs.path.join(a, &.{ dir, "bad.json" })).windows.len);
    try testing.expectEqual(@as(usize, 0), loadClosed(a, try std.fs.path.join(a, &.{ dir, "none.json" })).windows.len);
}

test "closedPath: XDG_STATE_HOME, else ~/.local/state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/s/roost/closed-windows.json", closedPath(a, "/s", "/h").?);
    try testing.expectEqualStrings("/h/.local/state/roost/closed-windows.json", closedPath(a, "", "/h").?);
    try testing.expectEqual(@as(?[]const u8, null), closedPath(a, null, null));
}
