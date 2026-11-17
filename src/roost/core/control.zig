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
//!     scratch-replace {"text":"..."} ->  {"ok":true,"backup":"/home/me/app/.roost/scratchpad-backups/..."}
//!     agent-note                     ->  {"text":"You're running in a pane of a Roost window..."}
//!     output {"target":"shell","lines":50} -> {"text":"...last 50 lines..."}
//!     actions                        ->  {"labels":["Run tests","Lint"]}
//!     run {"label":"Run tests"}      ->  {"ok":true}, once it has started
//!     run {"label":"Run tests","wait":true} -> {"code":1,"text":"..."}, once it ends
//!     open {"path":"/abs/file.zig","line":42,"col":7} -> {"ok":true}
//!     close                          ->  {"ok":true}, then the window quits
//! A request the window can't carry out gets {"error":"..."}. A waited `run`
//! and `open` answer later, when the work is done, on the same connection.
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
    /// Swap the whole scratchpad for this text; empty clears it. For when the
    /// user asks the agent to remove or rewrite something.
    scratch_replace: []const u8,
    /// `agent_note`, as `Reply.text`, so it always matches what this window
    /// supports. An older window doesn't answer, so it advertises nothing.
    agent_note,
    /// The end of a pane's text or of an action's output, as `Reply.text`.
    output: Output,
    /// The labels of the window's wired actions, as `Reply.labels`.
    actions,
    /// Start one of the window's wired actions, by label. Never a command.
    run: Run,
    /// Show a file at a line in the Editor pane.
    open: Open,
    /// Quit the window, saving its layout and sessions, without asking.
    /// `roost close --all` sends it, after asking the user itself.
    close,
    /// A request word whose argument doesn't parse; answered with an error.
    invalid: []const u8,

    /// The longest request line a window reads, to bound a scratchpad append.
    pub const max_line = 512 * 1024;

    pub const Output = struct {
        /// A pane role ("shell", "git", …), a pane's number in tree order
        /// (as Alt+1…9 counts them), or an action's label.
        target: []const u8,
        /// How many lines from the end. Capped at `max_lines`.
        lines: u32 = default_lines,

        pub const default_lines = 50;
        pub const max_lines = 10_000;
    };

    pub const Run = struct {
        label: []const u8,
        /// Answer when the run ends, with its exit code and output, instead of
        /// when it starts. A waited run reports to the caller and skips its
        /// routes, since the caller is usually the agent they would reach.
        wait: bool = false,
    };

    pub const Open = struct {
        /// An absolute path. The client resolves it against its own directory.
        path: []const u8,
        /// 1-based; 0 leaves the cursor where the editor puts it.
        line: u32 = 0,
        /// 1-based; 0 means the start of the line.
        col: u32 = 0,
    };

    /// The request on one line, or null when the line isn't one (it may be a
    /// hook message). Strings live in `arena`.
    pub fn parse(arena: Allocator, line: []const u8) ?Request {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        const sp = std.mem.indexOfScalar(u8, trimmed, ' ');
        const word = if (sp) |i| trimmed[0..i] else trimmed;
        const rest = if (sp) |i| std.mem.trim(u8, trimmed[i + 1 ..], " \t") else "";

        const append = std.mem.eql(u8, word, "scratch-append");
        if (append or std.mem.eql(u8, word, "scratch-replace")) {
            const Args = struct { text: []const u8 };
            const args = std.json.parseFromSliceLeaky(Args, arena, rest, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return .{ .invalid = "this request needs {\"text\": \"...\"}" };
            if (!isText(args.text)) return .{ .invalid = "the text isn't valid UTF-8" };
            return if (append) .{ .scratch_append = args.text } else .{ .scratch_replace = args.text };
        }
        if (std.mem.eql(u8, word, "output")) {
            const o = parseArg(Output, arena, rest) orelse return .{ .invalid = "this request needs {\"target\": \"...\"}" };
            if (o.target.len == 0 or !isText(o.target)) return .{ .invalid = "say which pane or action" };
            return .{ .output = .{ .target = o.target, .lines = @max(1, @min(o.lines, Output.max_lines)) } };
        }
        if (std.mem.eql(u8, word, "run")) {
            const r = parseArg(Run, arena, rest) orelse return .{ .invalid = "this request needs {\"label\": \"...\"}" };
            if (r.label.len == 0 or !isText(r.label)) return .{ .invalid = "say which action to run" };
            return .{ .run = r };
        }
        if (std.mem.eql(u8, word, "open")) {
            const o = parseArg(Open, arena, rest) orelse return .{ .invalid = "this request needs {\"path\": \"...\"}" };
            if (!std.fs.path.isAbsolute(o.path) or !isText(o.path)) return .{ .invalid = "the path must be absolute" };
            return .{ .open = o };
        }
        const bare: ?Request = if (std.mem.eql(u8, word, "status"))
            .status
        else if (std.mem.eql(u8, word, "scratch-read"))
            .scratch_read
        else if (std.mem.eql(u8, word, "agent-note"))
            .agent_note
        else if (std.mem.eql(u8, word, "actions"))
            .actions
        else if (std.mem.eql(u8, word, "close"))
            .close
        else
            null;
        const req = bare orelse return null;
        if (rest.len > 0) return .{ .invalid = "this request takes no argument" };
        return req;
    }

    /// An argument object, or null when it doesn't parse. Strings live in
    /// `arena`.
    fn parseArg(comptime T: type, arena: Allocator, rest: []const u8) ?T {
        return std.json.parseFromSliceLeaky(T, arena, rest, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch null;
    }

    /// Write the request line, newline included.
    pub fn write(self: Request, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .status => try w.writeAll("status"),
            .scratch_read => try w.writeAll("scratch-read"),
            .agent_note => try w.writeAll("agent-note"),
            .actions => try w.writeAll("actions"),
            .close => try w.writeAll("close"),
            .scratch_append, .scratch_replace => |text| {
                try w.writeAll(if (self == .scratch_append) "scratch-append " else "scratch-replace ");
                try std.json.Stringify.value(.{ .text = text }, .{}, w);
            },
            .output => |o| {
                try w.writeAll("output ");
                try std.json.Stringify.value(o, .{}, w);
            },
            .run => |r| {
                try w.writeAll("run ");
                try std.json.Stringify.value(r, .{}, w);
            },
            .open => |o| {
                try w.writeAll("open ");
                try std.json.Stringify.value(o, .{}, w);
            },
            .invalid => unreachable, // only parse makes these
        }
        try w.writeByte('\n');
    }
};

/// The last `n` lines of `text`, leaving out blank lines at the end (a
/// terminal's screen has empty rows below its prompt). Borrows from `text`.
pub fn tailLines(text: []const u8, n: u32) []const u8 {
    const body = std.mem.trimRight(u8, text, " \t\r\n");
    if (n == 0) return body[body.len..];
    var start = body.len;
    var seen: u32 = 0;
    while (start > 0) : (start -= 1) {
        if (body[start - 1] == '\n') {
            seen += 1;
            if (seen == n) break;
        }
    }
    return body[start..];
}

/// Where `roost open` should go: `path`, `path:line` or `path:line:col`. A
/// trailing `:` with no number (as some tools print) is dropped.
pub const Location = struct {
    path: []const u8,
    line: u32 = 0,
    col: u32 = 0,

    pub fn parse(arg: []const u8) Location {
        var rest = std.mem.trimRight(u8, arg, ":");
        var nums: [2]u32 = .{ 0, 0 };
        var count: usize = 0;
        while (count < 2) {
            const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse break;
            const n = std.fmt.parseInt(u32, rest[colon + 1 ..], 10) catch break;
            if (colon == 0) break;
            nums[count] = n;
            count += 1;
            rest = rest[0..colon];
        }
        return switch (count) {
            0 => .{ .path = rest },
            1 => .{ .path = rest, .line = nums[0] },
            else => .{ .path = rest, .line = nums[1], .col = nums[0] },
        };
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
    /// Where a replace saved the old notes (`core/backups.zig`).
    backup: ?[]const u8 = null,
    /// A finished action's exit code (`run` with wait, and `output`).
    code: ?u8 = null,
    /// The action is still running, so `text` is its output so far.
    running: ?bool = null,
    /// Someone pressed Stop on the action before it finished.
    stopped: ?bool = null,
    /// The window's action labels (`actions`).
    labels: ?[]const []const u8 = null,
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
    \\- `roost scratch replace` swaps the whole scratchpad for the Markdown on its stdin, and `roost scratch clear` empties it. Use them only when the user asks you to remove, change or tidy something in their notes: read first, change only what they asked for, and keep everything else exactly as it was. Both save the old notes to a backup file first and print its path; `roost scratch replace < <that file>` restores them.
    \\- `roost output <pane>` prints the end of another pane's screen: `roost output shell`, `roost output git`, or `roost output 3` for the third pane. `roost output "<action>"` prints a wired action's latest output. Use it when the user points at something in another pane, such as a dev server's error.
    \\- `roost run` lists the user's wired actions, commands they set up such as running the tests. `roost run "<action>" --wait` runs one, prints its output and exits with its exit code. Run one only when the user asks, since an action can do anything they set up.
    \\- `roost open <file>:<line>` shows that line in the Editor pane. Use it when the user asks to see code you mention.
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
    try testing.expectEqualStrings("new", Request.parse(a, "scratch-replace {\"text\":\"new\"}").?.scratch_replace);
    // An empty replace is how the Scratchpad gets cleared.
    try testing.expectEqualStrings("", Request.parse(a, "scratch-replace {\"text\":\"\"}").?.scratch_replace);
    try testing.expect(Request.parse(a, "scratch-replace").? == .invalid);
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

test "request: output, run, actions and open, with their arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = Request.parse(a, "output {\"target\":\"shell\"}").?.output;
    try testing.expectEqualStrings("shell", out.target);
    try testing.expectEqual(Request.Output.default_lines, out.lines);
    // Lines are kept between 1 and the cap.
    try testing.expectEqual(@as(u32, 1), Request.parse(a, "output {\"target\":\"git\",\"lines\":0}").?.output.lines);
    try testing.expectEqual(Request.Output.max_lines, Request.parse(a, "output {\"target\":\"git\",\"lines\":99999999}").?.output.lines);
    try testing.expect(Request.parse(a, "output {\"target\":\"\"}").? == .invalid);
    try testing.expect(Request.parse(a, "output").? == .invalid);

    const run = Request.parse(a, "run {\"label\":\"Run tests\",\"wait\":true}").?.run;
    try testing.expectEqualStrings("Run tests", run.label);
    try testing.expect(run.wait);
    try testing.expect(!Request.parse(a, "run {\"label\":\"Lint\"}").?.run.wait);
    try testing.expect(Request.parse(a, "run {\"command\":\"rm -rf /\"}").? == .invalid);
    try testing.expect(Request.parse(a, "actions").? == .actions);
    try testing.expect(Request.parse(a, "close").? == .close);
    try testing.expect(Request.parse(a, "close now").? == .invalid);
    try testing.expect(Request.parse(a, "actions please").? == .invalid);

    const open = Request.parse(a, "open {\"path\":\"/p/a.zig\",\"line\":42,\"col\":7}").?.open;
    try testing.expectEqualStrings("/p/a.zig", open.path);
    try testing.expectEqual(@as(u32, 42), open.line);
    try testing.expectEqual(@as(u32, 7), open.col);
    try testing.expectEqual(@as(u32, 0), Request.parse(a, "open {\"path\":\"/p\"}").?.open.line);
    try testing.expect(Request.parse(a, "open {\"path\":\"a.zig\"}").? == .invalid);
}

test "request: the new requests round-trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const reqs = [_]Request{
        .{ .output = .{ .target = "Run \"tests\"", .lines = 12 } },
        .{ .run = .{ .label = "Lint", .wait = true } },
        .{ .open = .{ .path = "/p/my file.zig", .line = 3 } },
        .actions,
    };
    for (reqs) |req| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try req.write(&w);
        try testing.expectEqual(1, std.mem.count(u8, w.buffered(), "\n"));
        const back = Request.parse(arena.allocator(), w.buffered()).?;
        try testing.expectEqual(std.meta.activeTag(req), std.meta.activeTag(back));
        switch (req) {
            .output => |o| {
                try testing.expectEqualStrings(o.target, back.output.target);
                try testing.expectEqual(o.lines, back.output.lines);
            },
            .run => |r| {
                try testing.expectEqualStrings(r.label, back.run.label);
                try testing.expectEqual(r.wait, back.run.wait);
            },
            .open => |o| {
                try testing.expectEqualStrings(o.path, back.open.path);
                try testing.expectEqual(o.line, back.open.line);
            },
            else => {},
        }
    }
}

test "tailLines: the last lines, without the blank rows below" {
    try testing.expectEqualStrings("b\nc", tailLines("a\nb\nc\n\n   \n", 2));
    try testing.expectEqualStrings("a\nb\nc", tailLines("a\nb\nc", 10));
    try testing.expectEqualStrings("c", tailLines("a\nb\nc", 1));
    try testing.expectEqualStrings("", tailLines("\n\n", 5));
    try testing.expectEqualStrings("", tailLines("a\nb", 0));
}

test "location: path, line and column" {
    const cases = .{
        .{ "src/a.zig", "src/a.zig", 0, 0 },
        .{ "src/a.zig:42", "src/a.zig", 42, 0 },
        .{ "src/a.zig:42:7", "src/a.zig", 42, 7 },
        .{ "src/a.zig:42:", "src/a.zig", 42, 0 },
        .{ "/p/2026:notes.md", "/p/2026:notes.md", 0, 0 },
        .{ "/p/x:1:2:3", "/p/x:1", 2, 3 },
        .{ ":42", ":42", 0, 0 },
    };
    inline for (cases) |c| {
        const loc = Location.parse(c[0]);
        try testing.expectEqualStrings(c[1], loc.path);
        try testing.expectEqual(@as(u32, c[2]), loc.line);
        try testing.expectEqual(@as(u32, c[3]), loc.col);
    }
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
    inline for (.{ "roost scratch read", "roost scratch append", "roost scratch replace", "roost scratch clear", "roost status", "roost output", "roost run", "roost open" }) |cmd| {
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
