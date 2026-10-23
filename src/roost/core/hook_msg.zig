//! The `ROOST_SOCK` hook message: what an agent's hook tells the window.
//!
//! WHY: one connection delivers one short line, written by `scripts/roost-notify`
//! from a Claude Code hook. Parsing it is pure string work, so it lives here in
//! the portable core (std-only, unit-tested standalone) rather than in the GTK
//! socket server (`ipc.zig`), which only moves bytes and acts on the result.
//!
//! FORMAT:
//!     [pane=<id>] [hook=<Event>] [session=<id>] <event> [message...]
//! `event` is `working`, `needs-input`, `done` or `session`; anything else is
//! ignored. `session` only records the conversation (from Claude Code's
//! SessionStart hook) and changes no badge.
//!
//! The optional leading `pane=<id>` says WHICH pane the agent runs in. Roost
//! exports a per-pane `ROOST_PANE` into every terminal pane, and roost-notify
//! echoes it back here. Without it, every agent in a window reported to the
//! first Agent pane, so a second agent's `working` could wipe the first one's
//! 🔔. A line without the prefix still parses (pane = null): that's what a pane
//! spawned by an older Roost build sends, and callers fall back to the first
//! Agent pane for it, exactly as before.
//!
//! The optional `hook=<Event>` names the Claude Code hook that sent the line
//! (`Stop`, `UserPromptSubmit`, ...), so Roost can tell which hooks actually
//! run (`claude_hooks.Liveness`). An older Roost would drop a line with a
//! token it doesn't know, so roost-notify only adds it when the pane's
//! `ROOST_PROTOCOL` is 2 or more.
//!
//! The optional `session=<id>` is the Claude Code session the hook ran in, so
//! a reload can resume it in the same pane. Letters, digits and `-` only: it
//! ends up in a shell command. Sent from `ROOST_PROTOCOL` 3.

const std = @import("std");

/// What the agent reported.
pub const Event = enum {
    working,
    needs_input,
    done,
    /// A conversation started or resumed: only `Message.session` matters.
    session,

    fn fromToken(tok: []const u8) ?Event {
        if (std.mem.eql(u8, tok, "working")) return .working;
        if (std.mem.eql(u8, tok, "needs-input")) return .needs_input;
        if (std.mem.eql(u8, tok, "done")) return .done;
        if (std.mem.eql(u8, tok, "session")) return .session;
        return null;
    }
};

/// One parsed line. `text` borrows from the input line.
pub const Message = struct {
    /// The sender's `ROOST_PANE`, or null when the line didn't carry one.
    pane: ?u32 = null,
    /// The Claude Code hook that sent it; empty when the line didn't say.
    hook: []const u8 = "",
    /// The Claude Code session it came from; empty when the line didn't say.
    session: []const u8 = "",
    event: Event,
    /// The optional human-readable message; empty when there was none.
    text: []const u8 = "",
};

const pane_prefix = "pane=";
const hook_prefix = "hook=";
const session_prefix = "session=";
/// Longer than any Claude Code session id (a 36-character UUID).
pub const max_session_len = 64;

/// Parse one message line. Null for an empty line, an unknown event, or a
/// malformed `pane=` prefix. A bad prefix drops the whole line rather than
/// guessing: misrouting a badge is worse than missing one update, and the next
/// hook will report again.
pub fn parse(line: []const u8) ?Message {
    var rest = std.mem.trim(u8, line, " \t\r\n");
    var msg: Message = .{ .event = .working };

    if (std.mem.startsWith(u8, rest, pane_prefix)) {
        const tok = nextToken(&rest);
        msg.pane = std.fmt.parseInt(u32, tok[pane_prefix.len..], 10) catch return null;
    }
    if (std.mem.startsWith(u8, rest, hook_prefix)) {
        const tok = nextToken(&rest);
        msg.hook = tok[hook_prefix.len..];
        if (msg.hook.len == 0) return null;
    }
    if (std.mem.startsWith(u8, rest, session_prefix)) {
        const tok = nextToken(&rest);
        msg.session = tok[session_prefix.len..];
        if (!validSession(msg.session)) return null;
    }

    const tok = nextToken(&rest);
    if (tok.len == 0) return null;
    msg.event = Event.fromToken(tok) orelse return null;
    msg.text = rest;
    return msg;
}

/// A session id Roost will put in a shell command: 1 to `max_session_len`
/// letters, digits and dashes.
pub fn validSession(id: []const u8) bool {
    if (id.len == 0 or id.len > max_session_len) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

/// Split the first space-delimited token off `rest`, leaving `rest` trimmed.
fn nextToken(rest: *[]const u8) []const u8 {
    const sp = std.mem.indexOfAny(u8, rest.*, " \t");
    const tok = if (sp) |i| rest.*[0..i] else rest.*;
    rest.* = if (sp) |i| std.mem.trim(u8, rest.*[i + 1 ..], " \t") else "";
    return tok;
}

// ---------------------------------------------------------------------------
// Tests (pure: run with `zig test src/roost/core/hook_msg.zig`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse: bare events, with and without a message" {
    const done = parse("done").?;
    try testing.expectEqual(Event.done, done.event);
    try testing.expectEqual(@as(?u32, null), done.pane);
    try testing.expectEqualStrings("", done.text);

    const ask = parse("needs-input  Approve this edit?\n").?;
    try testing.expectEqual(Event.needs_input, ask.event);
    try testing.expectEqualStrings("Approve this edit?", ask.text);
}

test "parse: pane prefix names the sender's pane" {
    const m = parse("pane=7 needs-input Claude needs your permission").?;
    try testing.expectEqual(@as(?u32, 7), m.pane);
    try testing.expectEqual(Event.needs_input, m.event);
    try testing.expectEqualStrings("Claude needs your permission", m.text);

    const w = parse("pane=12 working").?;
    try testing.expectEqual(@as(?u32, 12), w.pane);
    try testing.expectEqual(Event.working, w.event);
}

test "parse: rejects empty, unknown and malformed lines" {
    try testing.expectEqual(@as(?Message, null), parse(""));
    try testing.expectEqual(@as(?Message, null), parse("  \n"));
    try testing.expectEqual(@as(?Message, null), parse("finished"));
    // A prefix with no event, or a pane id that isn't a number.
    try testing.expectEqual(@as(?Message, null), parse("pane=3"));
    try testing.expectEqual(@as(?Message, null), parse("pane= done"));
    try testing.expectEqual(@as(?Message, null), parse("pane=x done"));
    try testing.expectEqual(@as(?Message, null), parse("pane=-1 done"));
}

test "parse: hook name, after the pane or alone" {
    const m = parse("pane=4 hook=UserPromptSubmit working").?;
    try testing.expectEqual(@as(?u32, 4), m.pane);
    try testing.expectEqualStrings("UserPromptSubmit", m.hook);
    try testing.expectEqual(Event.working, m.event);

    const n = parse("hook=Notification needs-input Claude needs your permission").?;
    try testing.expectEqual(@as(?u32, null), n.pane);
    try testing.expectEqualStrings("Notification", n.hook);
    try testing.expectEqualStrings("Claude needs your permission", n.text);

    // No name is a broken line; a name with no event is too.
    try testing.expectEqual(@as(?Message, null), parse("pane=1 hook= done"));
    try testing.expectEqual(@as(?Message, null), parse("hook=Stop"));
    // Order is fixed: pane first.
    try testing.expectEqual(@as(?Message, null), parse("hook=Stop pane=1 done"));
}

test "parse: session id, and ones unsafe for a shell" {
    const m = parse("pane=2 hook=Stop session=710c01ad-878d-4d96-a33a-4911a1356ea4 done").?;
    try testing.expectEqual(@as(?u32, 2), m.pane);
    try testing.expectEqualStrings("Stop", m.hook);
    try testing.expectEqualStrings("710c01ad-878d-4d96-a33a-4911a1356ea4", m.session);
    try testing.expectEqual(Event.done, m.event);

    try testing.expectEqual(@as(?Message, null), parse("session= done"));
    try testing.expectEqual(@as(?Message, null), parse("session=a;rm done"));
    try testing.expectEqual(@as(?Message, null), parse("session=$(x) done"));
    try testing.expectEqual(@as(?Message, null), parse("session=" ++ "a" ** 65 ++ " done"));
    try testing.expect(parse("session=" ++ "a" ** 64 ++ " done") != null);

    // SessionStart's line: just the session, no badge change.
    const start = parse("pane=1 hook=SessionStart session=abc-123 session").?;
    try testing.expectEqual(Event.session, start.event);
    try testing.expectEqualStrings("abc-123", start.session);
}

test "parse: the prefix only counts as the first token" {
    // "pane=" later in the line is just message text.
    const m = parse("done see pane=3 for details").?;
    try testing.expectEqual(@as(?u32, null), m.pane);
    try testing.expectEqualStrings("see pane=3 for details", m.text);
}
