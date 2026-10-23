//! The control socket: what a client asks a Roost window, and the reply.
//!
//! WHY: every window already listens on `ROOST_SOCK` for hook messages, so the
//! same socket answers questions too. `roost status` asks one window and
//! `roost status --all` asks every window, for a desktop bar. The format lives
//! in the portable core (std-only, unit-tested standalone) so a Mac Roost can
//! speak it too.
//!
//! FORMAT: the client sends one line, a request word. The window answers with
//! one line of JSON and closes the connection.
//!     status  ->  {"pid":1234,"project":"/home/me/app","name":"app","branch":"main","state":"needs-input"}
//!
//! Request words never collide with hook events (`core/hook_msg.zig`), so the
//! server tries this parser first. An older Roost reads a request as an
//! unknown event and closes without a reply; clients report that window with
//! state `unknown` and no project.
//!
//! Sockets are named `roost-<pid>.sock` in `$XDG_RUNTIME_DIR` (else `/tmp`),
//! which is how a client finds every window.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What a client can ask.
pub const Request = enum {
    /// The window's project, branch and agent state, as one `Status`.
    status,

    /// The request on one line, or null when the line isn't one.
    pub fn parse(line: []const u8) ?Request {
        const word = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.eql(u8, word, "status")) return .status;
        return null;
    }
};

/// A window's agent state: the most urgent across its Agent panes.
pub const State = enum {
    needs_input,
    done,
    working,
    idle,
    /// No Agent pane, nothing detected yet, or a window that didn't answer.
    unknown,

    /// The wire name, spelled like the hook events.
    pub fn name(self: State) []const u8 {
        return switch (self) {
            .needs_input => "needs-input",
            .done => "done",
            .working => "working",
            .idle => "idle",
            .unknown => "unknown",
        };
    }

    pub fn fromName(s: []const u8) ?State {
        inline for (std.meta.fields(State)) |f| {
            const state: State = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, state.name())) return state;
        }
        return null;
    }

    pub fn jsonStringify(self: State, jw: anytype) !void {
        try jw.write(self.name());
    }

    /// A state this build doesn't know reads as `unknown`, so a newer window
    /// never breaks an older client.
    pub fn jsonParse(alloc: Allocator, source: anytype, options: std.json.ParseOptions) !State {
        const s = try std.json.innerParse([]const u8, alloc, source, options);
        return fromName(s) orelse .unknown;
    }
};

/// One window's answer to `status`. Strings borrow from whoever built it.
pub const Status = struct {
    pid: i32,
    /// The project directory, or "" for none (or no answer).
    project: []const u8 = "",
    /// The project's display name, its directory's basename.
    name: []const u8 = "",
    /// The checked-out branch, a short commit id when detached, or "".
    branch: []const u8 = "",
    state: State = .unknown,

    /// Write the reply line, newline included.
    pub fn write(self: Status, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.json.Stringify.value(self, .{}, w);
        try w.writeByte('\n');
    }

    /// Read a reply line. Unknown fields are skipped, so newer windows can add
    /// some. Allocations live in `arena`.
    pub fn parse(arena: Allocator, line: []const u8) !Status {
        return std.json.parseFromSliceLeaky(Status, arena, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

/// The pid in a socket's file name, `roost-<pid>.sock`, or null for any other
/// name.
pub fn socketPid(file_name: []const u8) ?i32 {
    const prefix = "roost-";
    const suffix = ".sock";
    if (!std.mem.startsWith(u8, file_name, prefix) or !std.mem.endsWith(u8, file_name, suffix)) return null;
    const digits = file_name[prefix.len .. file_name.len - suffix.len];
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    const pid = std.fmt.parseInt(i32, digits, 10) catch return null;
    return if (pid > 0) pid else null;
}

// ---------------------------------------------------------------------------
// Tests (run with `zig test src/roost/core/control.zig`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "request: one word, and nothing a hook would send" {
    try testing.expectEqual(Request.status, Request.parse("status").?);
    try testing.expectEqual(Request.status, Request.parse(" status\n").?);
    try testing.expectEqual(@as(?Request, null), Request.parse("done"));
    try testing.expectEqual(@as(?Request, null), Request.parse("pane=1 status"));
    try testing.expectEqual(@as(?Request, null), Request.parse("status now"));
    try testing.expectEqual(@as(?Request, null), Request.parse(""));
}

test "status: a reply round-trips" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const sent: Status = .{ .pid = 9691, .project = "/home/me/my \"app\"", .name = "my \"app\"", .branch = "feature/x", .state = .needs_input };
    try sent.write(&w);
    try testing.expectEqualStrings(
        \\{"pid":9691,"project":"/home/me/my \"app\"","name":"my \"app\"","branch":"feature/x","state":"needs-input"}
        \\
    , w.buffered());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try Status.parse(arena.allocator(), w.buffered());
    try testing.expectEqual(sent.pid, got.pid);
    try testing.expectEqualStrings(sent.project, got.project);
    try testing.expectEqualStrings(sent.name, got.name);
    try testing.expectEqualStrings(sent.branch, got.branch);
    try testing.expectEqual(sent.state, got.state);
}

test "status: a newer window's fields and states don't break parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try Status.parse(a,
        \\{"pid":7,"project":"/p","name":"p","branch":"","state":"compacting","panes":4}
    );
    try testing.expectEqual(@as(i32, 7), got.pid);
    try testing.expectEqual(State.unknown, got.state);
    // Only the pid is required.
    const bare = try Status.parse(a, "{\"pid\":8}");
    try testing.expectEqual(State.unknown, bare.state);
    try testing.expectEqualStrings("", bare.project);
    try testing.expectError(error.MissingField, Status.parse(a, "{}"));
}

test "state: every state has a name that reads back" {
    inline for (std.meta.fields(State)) |f| {
        const state: State = @enumFromInt(f.value);
        try testing.expectEqual(state, State.fromName(state.name()).?);
    }
    try testing.expectEqual(@as(?State, null), State.fromName("needs_input"));
}

test "socketPid: only roost-<pid>.sock" {
    try testing.expectEqual(@as(?i32, 9691), socketPid("roost-9691.sock"));
    try testing.expectEqual(@as(?i32, null), socketPid("roost-.sock"));
    try testing.expectEqual(@as(?i32, null), socketPid("roost-0.sock"));
    try testing.expectEqual(@as(?i32, null), socketPid("roost-12a.sock"));
    try testing.expectEqual(@as(?i32, null), socketPid("roost-+12.sock"));
    try testing.expectEqual(@as(?i32, null), socketPid("roost-99999999999.sock"));
    try testing.expectEqual(@as(?i32, null), socketPid("claude-notify-test.sock"));
    try testing.expectEqual(@as(?i32, null), socketPid("roost-12.sock.lock"));
}
