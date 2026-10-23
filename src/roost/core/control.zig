//! The control socket: what a client asks a Roost window, and the reply.
//!
//! WHY: every window already listens on `ROOST_SOCK` for hook messages, so the
//! same socket answers questions too. `roost status` asks one window and
//! `roost status --all` asks every window, for a desktop bar. The format lives
//! in the portable core (std-only, unit-tested standalone) so a Mac Roost can
//! speak it too.
//!
//! FORMAT: the client sends one line: a request word, then for some requests
//! a JSON object with the argument, so text with newlines still fits on one
//! line. The window answers with one line of JSON and closes the connection.
//!     status                         ->  {"pid":1234,"project":"/home/me/app","name":"app","branch":"main","state":"needs-input"}
//!     scratch-read                   ->  {"text":"# Notes\n..."}
//!     scratch-append {"text":"..."}  ->  {"ok":true}
//!     agent-note                     ->  {"text":"You're running in a pane of a Roost window..."}
//! A request the window can't carry out gets {"error":"..."}.
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

/// What a client can ask, with its argument.
pub const Request = union(enum) {
    /// The window's project, branch and agent state, as one `Status`.
    status,
    /// The first Scratchpad pane's text, as `Reply.text`.
    scratch_read,
    /// Add Markdown to the end of the scratchpad, as its own paragraph.
    scratch_append: []const u8,
    /// `agent_note`, as `Reply.text`, so it always matches what this window
    /// supports. An older window doesn't answer, so it advertises nothing.
    agent_note,
    /// A request word whose argument doesn't parse; answered with an error.
    invalid: []const u8,

    /// The longest request line a window reads, to bound a scratchpad append.
    pub const max_line = 512 * 1024;

    /// The request on one line, or null when the line isn't one (it may be a
    /// hook message). Strings live in `arena`.
    pub fn parse(arena: Allocator, line: []const u8) ?Request {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        const sp = std.mem.indexOfScalar(u8, trimmed, ' ');
        const word = if (sp) |i| trimmed[0..i] else trimmed;
        const rest = if (sp) |i| std.mem.trim(u8, trimmed[i + 1 ..], " \t") else "";

        if (std.mem.eql(u8, word, "scratch-append")) {
            const Args = struct { text: []const u8 };
            const args = std.json.parseFromSliceLeaky(Args, arena, rest, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return .{ .invalid = "scratch-append needs {\"text\": \"...\"}" };
            if (!isText(args.text)) return .{ .invalid = "the text isn't valid UTF-8" };
            return .{ .scratch_append = args.text };
        }
        const bare: ?Request = if (std.mem.eql(u8, word, "status"))
            .status
        else if (std.mem.eql(u8, word, "scratch-read"))
            .scratch_read
        else if (std.mem.eql(u8, word, "agent-note"))
            .agent_note
        else
            null;
        const req = bare orelse return null;
        if (rest.len > 0) return .{ .invalid = "this request takes no argument" };
        return req;
    }

    /// Write the request line, newline included.
    pub fn write(self: Request, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .status => try w.writeAll("status"),
            .scratch_read => try w.writeAll("scratch-read"),
            .agent_note => try w.writeAll("agent-note"),
            .scratch_append => |text| {
                try w.writeAll("scratch-append ");
                try std.json.Stringify.value(.{ .text = text }, .{}, w);
            },
            .invalid => unreachable, // only parse makes these
        }
        try w.writeByte('\n');
    }
};

/// True when `bytes` can go in the Scratchpad: UTF-8 without NUL bytes, which
/// is what a GTK text buffer accepts.
pub fn isText(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes) and std.mem.indexOfScalar(u8, bytes, 0) == null;
}

/// The answer to every request but `status`: one of its fields is set.
pub const Reply = struct {
    text: ?[]const u8 = null,
    ok: ?bool = null,
    @"error": ?[]const u8 = null,

    /// Write the reply line, newline included.
    pub fn write(self: Reply, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.json.Stringify.value(self, .{ .emit_null_optional_fields = false }, w);
        try w.writeByte('\n');
    }

    /// Read a reply line. Allocations live in `arena`.
    pub fn parse(arena: Allocator, line: []const u8) !Reply {
        return std.json.parseFromSliceLeaky(Reply, arena, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

/// What the agent learns about these commands when its conversation starts:
/// Claude Code's SessionStart hook runs `roost-notify session`, which asks the
/// window for this and prints it, and Claude Code adds a SessionStart hook's
/// output to the conversation. It's in every conversation in Roost, so short.
pub const agent_note =
    \\You're running in a pane of a Roost window. The `roost` command works with the rest of the window:
    \\- `roost scratch read` prints the user's scratchpad: their Markdown notes for this project. Read it when they mention their notes or the scratchpad.
    \\- `roost scratch append` adds the Markdown on its stdin to the end of the scratchpad, as a new paragraph, and never changes what's already there. Use it when the user asks you to put a plan, summary or checklist in their notes, for example `roost scratch append <<'EOF'` … `EOF`.
    \\- `roost status` prints this window's project, branch and agent state.
;

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

test "request: words, arguments, and nothing a hook would send" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(Request.parse(a, "status").? == .status);
    try testing.expect(Request.parse(a, " status\n").? == .status);
    try testing.expect(Request.parse(a, "scratch-read").? == .scratch_read);
    try testing.expect(Request.parse(a, "agent-note").? == .agent_note);
    try testing.expect(Request.parse(a, "status now").? == .invalid);
    try testing.expect(Request.parse(a, "scratch-append").? == .invalid);
    try testing.expect(Request.parse(a, "scratch-append {\"txt\":\"x\"}").? == .invalid);
    try testing.expect(Request.parse(a, "scratch-append not json").? == .invalid);
    try testing.expect(Request.parse(a, "scratch-append {\"text\":\"a\\u0000b\"}").? == .invalid);
    // Hook messages, and anything else, aren't requests.
    inline for (.{ "done", "working", "needs-input", "session", "pane=1 status", "" }) |line| {
        try testing.expectEqual(@as(?Request, null), Request.parse(a, line));
    }
}

test "request: an append round-trips text with newlines and quotes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const text = "## Plan\n\n- fix \"it\"\n- ship\n";
    try (Request{ .scratch_append = text }).write(&w);
    try testing.expectEqualStrings(
        \\scratch-append {"text":"## Plan\n\n- fix \"it\"\n- ship\n"}
        \\
    , w.buffered());
    try testing.expectEqual(1, std.mem.count(u8, w.buffered(), "\n"));
    const back = Request.parse(arena.allocator(), w.buffered()).?;
    try testing.expectEqualStrings(text, back.scratch_append);
}

test "reply: only the field that's set goes on the wire" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try (Reply{ .@"error" = "no scratchpad" }).write(&w);
    try testing.expectEqualStrings("{\"error\":\"no scratchpad\"}\n", w.buffered());
    const back = try Reply.parse(arena.allocator(), w.buffered());
    try testing.expectEqualStrings("no scratchpad", back.@"error".?);
    try testing.expectEqual(@as(?[]const u8, null), back.text);
}

test "agent note: names every command it promises" {
    inline for (.{ "roost scratch read", "roost scratch append", "roost status" }) |cmd| {
        try testing.expect(std.mem.indexOf(u8, agent_note, cmd) != null);
    }
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
