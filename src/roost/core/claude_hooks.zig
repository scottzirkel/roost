//! Claude Code hooks: are Roost's installed, are they running, and adding
//! missing ones.
//!
//! WHY: Roost learns what the agent is doing from Claude Code hooks that run
//! `scripts/roost-notify`. When a hook is missing, nothing errors. The badge
//! just quietly falls back to reading the screen, which is how the `working`
//! hooks went missing for months in 2026. Settings uses this module to show the
//! state of each hook and, after asking, to add the missing ones.
//!
//! Installed isn't the same as running: a Claude Code update can rename or
//! drop an event, and the file still looks right. `Liveness` checks the other
//! half, from the hooks that actually reach the socket.
//!
//! Everything here works on plain JSON text and std file IO, so it lives in the
//! portable core (std-only, unit-tested standalone).
//!
//! Claude Code's `settings.json` keeps hooks as
//!     "hooks": { "<Event>": [ { "matcher"?: …, "hooks": [ { "type": "command", "command": "…" } ] } ] }
//! A required hook counts as installed when any command for its event runs
//! `roost-notify` with the right argument. Adding a hook appends one entry and
//! leaves everything else alone: the file is re-written in the same two-space
//! format Claude Code uses, and numbers are copied as written, so an unchanged
//! file round-trips byte for byte.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One hook Roost needs.
pub const Hook = struct {
    /// Claude Code's name for the event.
    event: []const u8,
    /// The argument `roost-notify` sends for it.
    arg: []const u8,
    /// What it tells Roost, for the Settings row.
    purpose: []const u8,
    /// Run without making the agent wait. Set for the frequent `working`
    /// events; `done` and `needs-input` are rare enough to run in line.
    is_async: bool,
};

/// Every hook Roost needs. Keep in sync with `scripts/claude-hooks.json`.
pub const required = [_]Hook{
    .{ .event = "Stop", .arg = "done", .purpose = "Agent finished: ✓ done", .is_async = false },
    .{ .event = "Notification", .arg = "needs-input", .purpose = "Agent needs you: 🔔", .is_async = false },
    .{ .event = "UserPromptSubmit", .arg = "working", .purpose = "You sent a prompt: ● working", .is_async = true },
    .{ .event = "PostToolBatch", .arg = "working", .purpose = "Tools finished: ● working", .is_async = true },
};

/// The index of `event` in `required`.
pub fn indexOf(comptime event: []const u8) usize {
    inline for (required, 0..) |hook, i| {
        if (comptime std.mem.eql(u8, hook.event, event)) return i;
    }
    @compileError("not a required hook: " ++ event);
}

/// Which required hooks have run in this window, and whether that adds up.
/// The hooks that do run are the evidence for the ones that don't: turns that
/// finish without ever starting, or start without ever finishing, mean one of
/// the pair has gone quiet. Fed from `roost-notify`'s `hook=<event>` field.
pub const Liveness = struct {
    /// How many times each `required` hook has run, by index.
    runs: [required.len]u32 = @splat(0),

    /// Count one run of the hook Claude Code calls `event`. Others are ignored.
    pub fn record(self: *Liveness, event: []const u8) void {
        for (required, &self.runs) |hook, *n| {
            if (std.mem.eql(u8, hook.event, event)) n.* +|= 1;
        }
    }

    /// The index of a required hook that should have run by now but never
    /// has, or null while the runs add up. PostToolBatch and Notification get
    /// no rule: a turn can finish without either, so their silence proves
    /// nothing.
    pub fn silent(self: Liveness) ?usize {
        const stop = self.runs[indexOf("Stop")];
        const prompt = self.runs[indexOf("UserPromptSubmit")];
        // Every turn starts with a prompt.
        if (stop >= 3 and prompt == 0) return indexOf("UserPromptSubmit");
        // Interrupting a turn skips Stop, but not five times without one finishing.
        if (prompt >= 5 and stop == 0) return indexOf("Stop");
        return null;
    }
};

/// What a settings file says about each `required` hook, by index.
pub const Status = struct {
    /// The `roost-notify` path each hook's command runs, as written (it may
    /// start with `~` or `$HOME`), or null when the hook is missing.
    scripts: [required.len]?[]const u8 = @splat(null),

    /// Fill in hooks this status lacks from `other`, e.g. a project's settings.
    pub fn merge(self: *Status, other: Status) void {
        for (&self.scripts, other.scripts) |*mine, theirs| {
            if (mine.* == null) mine.* = theirs;
        }
    }

    pub fn missingCount(self: Status) usize {
        var n: usize = 0;
        for (self.scripts) |s| n += @intFromBool(s == null);
        return n;
    }
};

pub const Error = error{
    /// The file isn't JSON.
    InvalidJson,
    /// It's JSON, but not shaped like Claude Code settings (say, `hooks` is a
    /// list), so Roost won't guess where to add anything.
    UnexpectedShape,
} || Allocator.Error;

/// Report which required hooks `json` (a settings file's contents) installs.
/// Allocations, including the returned paths, live in `arena`. Entries shaped
/// unlike Claude Code's are skipped, not errors: this only reads.
pub fn check(arena: Allocator, json: []const u8) Error!Status {
    const root = try parse(arena, json);
    var status: Status = .{};
    const hooks = switch (root) {
        .object => |o| o.get("hooks") orelse return status,
        else => return status,
    };
    if (hooks != .object) return status;

    for (required, &status.scripts) |hook, *script| {
        const groups = hooks.object.get(hook.event) orelse continue;
        if (groups != .array) continue;
        for (groups.array.items) |group| {
            if (group != .object) continue;
            const entries = group.object.get("hooks") orelse continue;
            if (entries != .array) continue;
            for (entries.array.items) |entry| {
                if (entry != .object) continue;
                if (entry.object.get("type")) |t| {
                    if (t != .string or !std.mem.eql(u8, t.string, "command")) continue;
                }
                const command = entry.object.get("command") orelse continue;
                if (command != .string) continue;
                if (try notifyScript(arena, command.string, hook.arg)) |path| {
                    script.* = path;
                    break;
                }
            }
            if (script.* != null) break;
        }
    }
    return status;
}

/// Return the settings file `json` with an entry added for each of `hooks`,
/// each running `notify_path`. `json` null means there's no file yet.
/// Allocations live in `arena`.
pub fn add(arena: Allocator, json: ?[]const u8, hooks: []const Hook, notify_path: []const u8) Error![]u8 {
    var root: std.json.Value = if (json) |j| try parse(arena, j) else .{ .object = .init(arena) };
    if (root != .object) return error.UnexpectedShape;
    if (hooks.len > 0) try addTo(arena, &root.object, hooks, notify_path);

    const body = try std.json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });
    // Keep the file's trailing newline, or lack of one; a new file gets one.
    const newline = json == null or std.mem.endsWith(u8, json.?, "\n");
    return if (newline) try std.mem.concat(arena, u8, &.{ body, "\n" }) else body;
}

fn addTo(arena: Allocator, root: *std.json.ObjectMap, hooks: []const Hook, notify_path: []const u8) Error!void {
    const by_event = try root.getOrPut("hooks");
    if (!by_event.found_existing) by_event.value_ptr.* = .{ .object = .init(arena) };
    if (by_event.value_ptr.* != .object) return error.UnexpectedShape;

    const quoted = try shellQuote(arena, notify_path);
    for (hooks) |hook| {
        const groups = try by_event.value_ptr.object.getOrPut(hook.event);
        if (!groups.found_existing) groups.value_ptr.* = .{ .array = .init(arena) };
        if (groups.value_ptr.* != .array) return error.UnexpectedShape;

        var entry: std.json.ObjectMap = .init(arena);
        try entry.put("type", .{ .string = "command" });
        try entry.put("command", .{ .string = try std.fmt.allocPrint(arena, "{s} {s}", .{ quoted, hook.arg }) });
        if (hook.is_async) try entry.put("async", .{ .bool = true });

        var entries: std.json.Array = .init(arena);
        try entries.append(.{ .object = entry });
        var group: std.json.ObjectMap = .init(arena);
        try group.put("hooks", .{ .array = entries });
        try groups.value_ptr.array.append(.{ .object = group });
    }
}

/// Add `hooks` to the settings file at `path`, running `notify_path`. The old
/// file is copied to `<file>.roost-backup` first, and the new one replaces it
/// in a single rename, so a crash never leaves half a file. A symlinked file
/// (a dotfiles setup) is written through to its target, keeping the link.
pub fn install(alloc: Allocator, path: []const u8, hooks: []const Hook, notify_path: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = std.fs.cwd();
    const target = cwd.realpathAlloc(arena, path) catch |err| switch (err) {
        error.FileNotFound => path,
        else => return err,
    };

    var old: ?[]const u8 = null;
    var mode: std.fs.File.Mode = std.fs.File.default_mode;
    if (cwd.readFileAlloc(arena, target, max_settings_bytes)) |bytes| {
        old = bytes;
        mode = (try cwd.statFile(target)).mode & 0o7777;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const new = try add(arena, old, hooks, notify_path);
    if (old) |bytes| {
        const backup = try std.mem.concat(arena, u8, &.{ target, ".roost-backup" });
        // Same mode as the original: settings can hold API keys in `env`.
        try writeAtomic(backup, bytes, mode);
    }
    try writeAtomic(target, new, mode);
}

/// Settings files bigger than this aren't Claude Code settings.
pub const max_settings_bytes = 4 * 1024 * 1024;

/// The user's Claude Code settings file: `$CLAUDE_CONFIG_DIR/settings.json`,
/// else `~/.claude/settings.json`. Null without either variable.
pub fn userSettingsPath(alloc: Allocator) Allocator.Error!?[]u8 {
    if (std.posix.getenv("CLAUDE_CONFIG_DIR")) |dir| {
        if (dir.len > 0) return try std.fs.path.join(alloc, &.{ dir, "settings.json" });
    }
    const home = std.posix.getenv("HOME") orelse return null;
    return try std.fs.path.join(alloc, &.{ home, ".claude", "settings.json" });
}

/// The project's own settings files, which Claude Code merges with the user's.
pub fn projectSettingsPaths(alloc: Allocator, project: []const u8) Allocator.Error![2][]u8 {
    return .{
        try std.fs.path.join(alloc, &.{ project, ".claude", "settings.json" }),
        try std.fs.path.join(alloc, &.{ project, ".claude", "settings.local.json" }),
    };
}

fn parse(arena: Allocator, json: []const u8) Error!std.json.Value {
    // parse_numbers = false keeps every number exactly as written.
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

fn writeAtomic(path: []const u8, bytes: []const u8, mode: std.fs.File.Mode) !void {
    var buf: [4096]u8 = undefined;
    var af = try std.fs.cwd().atomicFile(path, .{ .mode = mode, .make_path = true, .write_buffer = &buf });
    defer af.deinit();
    try af.file_writer.interface.writeAll(bytes);
    try af.finish();
}

/// If `command` runs `roost-notify` with `arg`, return the script path as
/// written. A bare `roost-notify` sends `working`, so it counts for that.
fn notifyScript(arena: Allocator, command: []const u8, arg: []const u8) Allocator.Error!?[]const u8 {
    var words: Words = .{ .rest = command };
    // The `roost-notify` word just seen, waiting for its argument.
    var script: ?[]const u8 = null;
    while (try words.next(arena)) |token| {
        if (script) |s| {
            const sent = switch (token) {
                .word => |w| w,
                .end_of_command => "working",
            };
            if (std.mem.eql(u8, sent, arg)) return s;
            script = null;
        }
        if (token == .word and std.mem.eql(u8, std.fs.path.basename(token.word), "roost-notify")) {
            script = token.word;
        }
    }
    if (script) |s| {
        if (std.mem.eql(u8, arg, "working")) return s;
    }
    return null;
}

/// Splits a shell command into words, enough to find `roost-notify` and its
/// argument: quotes and backslashes are undone, and `;`, `&`, `|`, `(`, `)`,
/// `<` and `>` end a command. Not a full shell parser; it doesn't need to be.
const Words = struct {
    rest: []const u8,

    const Token = union(enum) {
        word: []const u8,
        end_of_command,
    };

    /// The next token, or null when the input is used up.
    fn next(self: *Words, arena: Allocator) Allocator.Error!?Token {
        self.rest = std.mem.trimStart(u8, self.rest, " \t\r\n");
        if (self.rest.len == 0) return null;
        if (std.mem.indexOfScalar(u8, separators, self.rest[0]) != null) {
            self.rest = std.mem.trimStart(u8, self.rest, separators);
            return .end_of_command;
        }

        var word: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        var quote: ?u8 = null;
        while (i < self.rest.len) : (i += 1) {
            const c = self.rest[i];
            if (quote) |q| {
                if (c == q) {
                    quote = null;
                } else if (q == '"' and c == '\\' and i + 1 < self.rest.len) {
                    i += 1;
                    try word.append(arena, self.rest[i]);
                } else {
                    try word.append(arena, c);
                }
            } else if (c == '\'' or c == '"') {
                quote = c;
            } else if (c == '\\' and i + 1 < self.rest.len) {
                i += 1;
                try word.append(arena, self.rest[i]);
            } else if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or
                std.mem.indexOfScalar(u8, separators, c) != null)
            {
                break;
            } else {
                try word.append(arena, c);
            }
        }
        self.rest = self.rest[i..];
        return .{ .word = word.items };
    }

    const separators = ";&|()<>";
};

/// `path` as one shell word: unchanged when that's safe, else single-quoted.
fn shellQuote(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    for (path) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/._-+=,:@%", c) != null)) break;
    } else return path;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(arena, '\'');
    for (path) |c| {
        if (c == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, c);
    }
    try out.append(arena, '\'');
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests (run with `zig test src/roost/core/claude_hooks.zig`)
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The hooks block from `scripts/claude-hooks.json`, as installed.
const full =
    \\{
    \\  "model": "opus",
    \\  "hooks": {
    \\    "Stop": [
    \\      { "hooks": [ { "type": "command", "command": "/opt/roost/scripts/roost-notify done" } ] }
    \\    ],
    \\    "Notification": [
    \\      { "hooks": [ { "type": "command", "command": "/opt/roost/scripts/roost-notify needs-input" } ] }
    \\    ],
    \\    "UserPromptSubmit": [
    \\      { "hooks": [ { "type": "command", "command": "/opt/roost/scripts/roost-notify working", "async": true } ] }
    \\    ],
    \\    "PostToolBatch": [
    \\      { "hooks": [ { "type": "command", "command": "/opt/roost/scripts/roost-notify working", "async": true } ] }
    \\    ]
    \\  }
    \\}
;

test "check: a full install has every hook" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try check(arena.allocator(), full);
    try testing.expectEqual(@as(usize, 0), s.missingCount());
    try testing.expectEqualStrings("/opt/roost/scripts/roost-notify", s.scripts[0].?);
}

test "check: the 2026 install had no working hooks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try check(arena.allocator(),
        \\{"hooks": {
        \\  "Stop": [{"hooks": [{"type": "command", "command": "~/roost/scripts/roost-notify done"}]}],
        \\  "Notification": [{"hooks": [{"type": "command", "command": "~/roost/scripts/roost-notify needs-input"}]}]
        \\}}
    );
    try testing.expectEqual(@as(usize, 2), s.missingCount());
    try testing.expectEqualStrings("~/roost/scripts/roost-notify", s.scripts[0].?);
    try testing.expectEqual(@as(?[]const u8, null), s.scripts[2]);
    try testing.expectEqual(@as(?[]const u8, null), s.scripts[3]);
}

test "check: no file content worth reading" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(required.len, (try check(a, "{}")).missingCount());
    try testing.expectEqual(required.len, (try check(a, "[]")).missingCount());
    try testing.expectEqual(required.len, (try check(a, "{\"hooks\": []}")).missingCount());
    try testing.expectError(error.InvalidJson, check(a, "{\"hooks\": "));
    try testing.expectError(error.InvalidJson, check(a, ""));
}

test "check: the wrong argument, another tool, or a non-command doesn't count" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try check(arena.allocator(),
        \\{"hooks": {
        \\  "Stop": [{"hooks": [{"type": "command", "command": "/x/roost-notify working"}]}],
        \\  "Notification": [{"hooks": [{"type": "command", "command": "notify-send needs-input"}]}],
        \\  "UserPromptSubmit": [{"hooks": [{"type": "prompt", "command": "/x/roost-notify working"}]}],
        \\  "PostToolBatch": [{"hooks": [{"type": "command", "command": "/x/roost-notifyx working"}]}]
        \\}}
    );
    try testing.expectEqual(required.len, s.missingCount());
}

test "check: quoting, wrappers, chains and a bare roost-notify" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try check(arena.allocator(),
        \\{"hooks": {
        \\  "Stop": [{"matcher": "", "hooks": [
        \\    {"type": "command", "command": "echo hi"},
        \\    {"type": "command", "command": "'/my dir/roost-notify' \"done\""}
        \\  ]}],
        \\  "Notification": [{"hooks": [{"type": "command", "command": "python3 $HOME/r/roost-notify needs-input"}]}],
        \\  "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/r/roost-notify; true"}]}],
        \\  "PostToolBatch": [{"hooks": [{"type": "command", "command": "/a/roost-notify done&&/b/roost-notify working"}]}]
        \\}}
    );
    try testing.expectEqual(@as(usize, 0), s.missingCount());
    try testing.expectEqualStrings("/my dir/roost-notify", s.scripts[0].?);
    try testing.expectEqualStrings("$HOME/r/roost-notify", s.scripts[1].?);
    try testing.expectEqualStrings("/r/roost-notify", s.scripts[2].?);
    try testing.expectEqualStrings("/b/roost-notify", s.scripts[3].?);
}

test "merge: a project's settings fill the user's gaps" {
    var user: Status = .{};
    user.scripts[0] = "/u/roost-notify";
    var proj: Status = .{};
    proj.scripts[0] = "/p/roost-notify";
    proj.scripts[2] = "/p/roost-notify";
    user.merge(proj);
    try testing.expectEqualStrings("/u/roost-notify", user.scripts[0].?);
    try testing.expectEqualStrings("/p/roost-notify", user.scripts[2].?);
    try testing.expectEqual(@as(usize, 2), user.missingCount());
}

test "liveness: runs that add up, and the two that don't" {
    var l: Liveness = .{};
    try testing.expectEqual(@as(?usize, null), l.silent());

    // A normal session: prompts, tool batches, finished turns.
    for (0..4) |_| {
        l.record("UserPromptSubmit");
        l.record("PostToolBatch");
        l.record("Stop");
    }
    l.record("SessionStart"); // not ours: ignored
    try testing.expectEqual(@as(?usize, null), l.silent());
    try testing.expectEqual(@as(u32, 4), l.runs[indexOf("Stop")]);

    // Turns finish, but no prompt ever arrived (the 2026 failure).
    var no_prompt: Liveness = .{};
    for (0..2) |_| no_prompt.record("Stop");
    try testing.expectEqual(@as(?usize, null), no_prompt.silent());
    no_prompt.record("Stop");
    try testing.expectEqual(@as(?usize, indexOf("UserPromptSubmit")), no_prompt.silent());

    // Prompts arrive, but no turn ever finishes. A few interrupts are normal.
    var no_stop: Liveness = .{};
    for (0..4) |_| no_stop.record("UserPromptSubmit");
    try testing.expectEqual(@as(?usize, null), no_stop.silent());
    no_stop.record("UserPromptSubmit");
    try testing.expectEqual(@as(?usize, indexOf("Stop")), no_stop.silent());
}

test "add: appends the missing hooks and keeps everything else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before =
        \\{
        \\  "model": "opus",
        \\  "effort": 0.50,
        \\  "hooks": {
        \\    "Stop": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "/r/roost-notify done"
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        \\
    ;
    const after = try add(a, before, &.{ required[2], required[3] }, "/r/roost-notify");
    try testing.expectEqualStrings(
        \\{
        \\  "model": "opus",
        \\  "effort": 0.50,
        \\  "hooks": {
        \\    "Stop": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "/r/roost-notify done"
        \\          }
        \\        ]
        \\      }
        \\    ],
        \\    "UserPromptSubmit": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "/r/roost-notify working",
        \\            "async": true
        \\          }
        \\        ]
        \\      }
        \\    ],
        \\    "PostToolBatch": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "/r/roost-notify working",
        \\            "async": true
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        \\
    , after);
    // Notification was never there and wasn't asked for.
    const s = try check(a, after);
    try testing.expectEqual(@as(usize, 1), s.missingCount());
    try testing.expectEqual(@as(?[]const u8, null), s.scripts[1]);
}

test "add: an empty list round-trips Claude Code's own format unchanged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const file = "{\n  \"env\": {\n    \"A\": \"ü→\"\n  },\n  \"n\": 1e3,\n  \"list\": []\n}";
    try testing.expectEqualStrings(file, try add(arena.allocator(), file, &.{}, "/r/roost-notify"));
}

test "add: a new file, an odd path, and shapes it won't guess at" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fresh = try add(a, null, &required, "/my dir/it's/roost-notify");
    const s = try check(a, fresh);
    try testing.expectEqual(@as(usize, 0), s.missingCount());
    try testing.expectEqualStrings("/my dir/it's/roost-notify", s.scripts[0].?);
    try testing.expect(std.mem.indexOf(u8, fresh, "'/my dir/it'\\\\''s/roost-notify' done") != null);
    try testing.expect(std.mem.endsWith(u8, fresh, "}\n"));

    try testing.expectError(error.UnexpectedShape, add(a, "[]", &required, "/r"));
    try testing.expectError(error.UnexpectedShape, add(a, "{\"hooks\": []}", &required, "/r"));
    try testing.expectError(error.UnexpectedShape, add(a, "{\"hooks\": {\"Stop\": {}}}", &required, "/r"));
    try testing.expectError(error.InvalidJson, add(a, "{", &required, "/r"));
}

test "install: backs up, keeps the mode, and writes through a symlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);

    const real = try std.fs.path.join(testing.allocator, &.{ dir, "real.json" });
    defer testing.allocator.free(real);
    const link = try std.fs.path.join(testing.allocator, &.{ dir, "settings.json" });
    defer testing.allocator.free(link);

    const original = "{\n  \"model\": \"opus\"\n}\n";
    try tmp.dir.writeFile(.{ .sub_path = "real.json", .data = original });
    {
        const f = try tmp.dir.openFile("real.json", .{});
        defer f.close();
        try f.chmod(0o600);
    }
    try tmp.dir.symLink("real.json", "settings.json", .{});

    try install(testing.allocator, link, &required, "/r/roost-notify");

    // The link still points at real.json, which now has every hook.
    var lbuf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("real.json", try tmp.dir.readLink("settings.json", &lbuf));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = try tmp.dir.readFileAlloc(a, "real.json", max_settings_bytes);
    try testing.expectEqual(@as(usize, 0), (try check(a, now)).missingCount());
    try testing.expectEqual(@as(std.fs.File.Mode, 0o600), (try tmp.dir.statFile("real.json")).mode & 0o777);

    const backup = try tmp.dir.readFileAlloc(a, "real.json.roost-backup", max_settings_bytes);
    try testing.expectEqualStrings(original, backup);
    try testing.expectEqual(@as(std.fs.File.Mode, 0o600), (try tmp.dir.statFile("real.json.roost-backup")).mode & 0o777);
}

test "install: creates a missing file and its directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, ".claude", "settings.json" });
    defer testing.allocator.free(path);

    try install(testing.allocator, path, &required, "/r/roost-notify");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = try tmp.dir.readFileAlloc(a, ".claude/settings.json", max_settings_bytes);
    try testing.expectEqual(@as(usize, 0), (try check(a, now)).missingCount());
    try testing.expectError(error.FileNotFound, tmp.dir.access(".claude/settings.json.roost-backup", .{}));
}
