//! Agent-state detection from a terminal screen snapshot.
//!
//! WHY: Roost's agent status has until now come *only* from Claude Code's
//! `Stop`/`Notification` hooks (see `ipc.zig`). That is precise but has two
//! hard limits: it needs the user to wire hooks up by hand, and it only ever
//! works for Claude. Every other agent CLI (codex, opencode, gemini, …) shows
//! a blank badge forever.
//!
//! So we add a *fallback*: read the pane's visible screen and its OSC title,
//! and classify the agent's state from what it drew. Hooks stay authoritative
//! whenever they're reporting — an agent that tells us what it's doing always
//! beats us guessing from pixels. Scraping only fills the silence.
//!
//! ADDITIVE and deliberately **std-only** (no GTK, no Ghostty internals) so it
//! unit-tests standalone like `md.zig` / `ansi.zig` — and, more importantly, so
//! it can be compiled into a shared core for a non-GTK (macOS/AppKit) shell
//! later. Nothing in `core/` may import a toolkit; see `scripts/check-core.sh`.
//!
//! SHAPE: a `Manifest` is an agent's ruleset. Each `Rule` says "if this
//! `Match` holds over this `Region`, the state is X, with priority P". The
//! highest-priority matching rule wins; ties go to the earlier rule. Nothing
//! matches → `.unknown`, which callers treat as "keep whatever we had".
//!
//! `Tracker` sits on top and turns the stateless classification into a
//! lifecycle: it remembers the previous state so a working → idle transition
//! can be reported as `.done` (the moment worth notifying about). A screen
//! scrape can never observe "done" directly — it's a *transition*, not a
//! picture — which is exactly why this lives here and not in the matcher.

const std = @import("std");

/// The agent lifecycle state. Mirrors `tree.AgentStatus` plus an `unknown`
/// for "the screen didn't tell us anything" — deliberately NOT the same enum,
/// because this module must not import anything GTK-shaped.
pub const State = enum {
    /// No rule matched. Callers hold their previous state.
    unknown,
    /// Agent is waiting for input at its prompt.
    idle,
    /// Agent is actively doing something.
    working,
    /// Agent is blocked on the user — a permission prompt, a question.
    blocked,
    /// Agent just finished a run. Only ever produced by `Tracker`.
    done,

    /// Ranking for the cross-pane attention rollup: the state that most wants
    /// the user's eyes sorts highest. Used when several agent panes are live.
    pub fn attention(self: State) u8 {
        return switch (self) {
            .blocked => 4,
            .done => 3,
            .working => 2,
            .idle => 1,
            .unknown => 0,
        };
    }
};

/// Which slice of the terminal a rule looks at.
pub const Region = enum {
    /// The OSC-set window title. Agents that animate a spinner into their
    /// title (Claude does) make this the cheapest, most reliable signal.
    title,
    /// The last N non-empty lines of the visible screen, where N is the rule's
    /// `lines`. This is where CLIs draw their status footer and prompt box.
    bottom,
    /// Every non-empty line of the visible screen.
    screen,
};

/// How a rule tests its region. All string comparison is ASCII-case-insensitive
/// (agents are inconsistent about "Esc"/"esc"), and needles are matched per
/// line — a needle never spans a line break, which is what you want for UI
/// chrome like `esc to interrupt`.
pub const Match = union(enum) {
    /// At least one needle appears on some line of the region.
    any: []const []const u8,
    /// Every needle appears on some line of the region (not necessarily the
    /// same one).
    all: []const []const u8,
    /// Every needle appears on one single line. Precise enough to pin down a
    /// menu row like `❯ 1. Yes` without false-firing on prose.
    same_line_all: []const []const u8,
    /// Some line of the region begins with a Braille-pattern codepoint
    /// (U+2800–U+28FF) — the near-universal spinner glyph for TUI agents.
    spinner,
};

/// One detection rule.
pub const Rule = struct {
    /// Stable identifier, surfaced in logs and by a future `roost agent
    /// explain` so a misfire can be traced to the exact rule.
    id: []const u8,
    /// The state to report when this rule matches.
    state: State,
    /// Higher wins. Leave gaps (100s) so rules can be inserted between.
    priority: u16,
    region: Region,
    match: Match,
    /// For `.bottom`: how many trailing non-empty lines to consider.
    lines: u8 = 6,
    /// When true, a match *suppresses* classification for this frame — the
    /// caller keeps its previous state instead of adopting `state`. For modal
    /// overlays (a transcript pager, a help screen) that hide the real footer
    /// and would otherwise read as a bogus idle.
    hold: bool = false,
};

/// An agent's ruleset.
pub const Manifest = struct {
    /// Canonical agent id, e.g. "claude".
    id: []const u8,
    /// Other command names that select this manifest.
    aliases: []const []const u8 = &.{},
    rules: []const Rule,
};

/// What the caller scraped out of the pane this frame.
pub const Input = struct {
    /// The visible screen as newline-separated text (NOT the scrollback — see
    /// `TerminalPane.captureScreen`). Trailing blank lines are fine; they're
    /// skipped when the bottom region is taken.
    screen: []const u8 = "",
    /// The terminal's current OSC title, or empty if none is set.
    title: []const u8 = "",
};

/// The outcome of classifying one frame.
pub const Verdict = struct {
    state: State,
    /// The `Rule.id` that decided it, or null when nothing matched.
    rule: ?[]const u8 = null,
};

/// The most trailing non-empty lines any `.bottom` rule may inspect. Rules ask
/// for ~4–8; this cap just bounds the scan so a huge screen can't cost more
/// than a fixed amount of work per poll.
pub const max_bottom_lines = 16;

// -- Region extraction -------------------------------------------------------

/// A small fixed-capacity window of line slices borrowed from the input. No
/// allocation: detection runs on a timer against every live agent pane, so it
/// must stay allocation-free on the hot path.
const Lines = struct {
    items: [max_bottom_lines][]const u8 = undefined,
    len: usize = 0,

    fn push(self: *Lines, line: []const u8) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = line;
        self.len += 1;
    }

    fn slice(self: *const Lines) []const []const u8 {
        return self.items[0..self.len];
    }
};

/// Trim trailing `\r` (CRLF screens) and surrounding spaces/tabs.
fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

/// The last `n` non-empty lines of `text`, in top-to-bottom order.
///
/// Walking backwards and skipping blanks is what makes this robust: a TUI
/// leaves a ragged tail of empty rows below its footer, and a naive "last n
/// lines" would capture nothing but whitespace.
fn bottomLines(text: []const u8, n: u8) Lines {
    const want = @min(@as(usize, n), max_bottom_lines);
    var found: Lines = .{};
    if (want == 0) return found;

    // Collect backwards into a scratch buffer, then reverse into `found` so
    // callers see natural top-to-bottom order.
    var back: [max_bottom_lines][]const u8 = undefined;
    var back_len: usize = 0;

    var end: usize = text.len;
    while (end > 0 and back_len < want) {
        const nl = std.mem.lastIndexOfScalar(u8, text[0..end], '\n');
        const start = if (nl) |i| i + 1 else 0;
        const line = trim(text[start..end]);
        if (line.len > 0) {
            back[back_len] = line;
            back_len += 1;
        }
        if (nl == null) break;
        end = nl.?;
    }

    var i = back_len;
    while (i > 0) {
        i -= 1;
        found.push(back[i]);
    }
    return found;
}

/// Every non-empty line of `text`, capped at `max_bottom_lines` from the
/// bottom. The cap keeps a `.screen` rule from degenerating into an unbounded
/// scan on a very tall pane; agents put their state in the last rows anyway.
fn screenLines(text: []const u8) Lines {
    return bottomLines(text, max_bottom_lines);
}

/// Resolve a rule's region into borrowed line slices.
fn regionLines(region: Region, rule_lines: u8, in: Input) Lines {
    return switch (region) {
        .title => blk: {
            var l: Lines = .{};
            const t = trim(in.title);
            if (t.len > 0) l.push(t);
            break :blk l;
        },
        .bottom => bottomLines(in.screen, rule_lines),
        .screen => screenLines(in.screen),
    };
}

// -- Matching ----------------------------------------------------------------

/// Case-insensitive substring test.
fn lineHas(line: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(line, needle) != null;
}

/// Whether `line` starts with a Braille-pattern codepoint (U+2800–U+28FF).
///
/// UTF-8 encodes that block as `E2 A0..A3 80..BF`, so this is a 3-byte check
/// with no decoder. Spinners are the single most reliable "this agent is
/// thinking" signal across CLIs, and they're always the first glyph on the
/// line (or in the title).
fn startsWithSpinner(line: []const u8) bool {
    if (line.len < 3) return false;
    return line[0] == 0xE2 and
        line[1] >= 0xA0 and line[1] <= 0xA3 and
        line[2] >= 0x80 and line[2] <= 0xBF;
}

fn matches(m: Match, lines: []const []const u8) bool {
    switch (m) {
        .any => |needles| {
            for (needles) |n| {
                for (lines) |line| if (lineHas(line, n)) return true;
            }
            return false;
        },
        .all => |needles| {
            for (needles) |n| {
                var seen = false;
                for (lines) |line| {
                    if (lineHas(line, n)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) return false;
            }
            return needles.len > 0;
        },
        .same_line_all => |needles| {
            if (needles.len == 0) return false;
            for (lines) |line| {
                var all_here = true;
                for (needles) |n| {
                    if (!lineHas(line, n)) {
                        all_here = false;
                        break;
                    }
                }
                if (all_here) return true;
            }
            return false;
        },
        .spinner => {
            for (lines) |line| if (startsWithSpinner(line)) return true;
            return false;
        },
    }
}

/// Classify one frame against `manifest`. Highest-priority matching rule wins;
/// ties resolve to the earlier rule in the list. Returns `.unknown` when
/// nothing matched, or when the winning rule is a `hold` rule (a modal overlay
/// is covering the real signal) — in both cases the caller keeps its previous
/// state.
pub fn classify(manifest: *const Manifest, in: Input) Verdict {
    var best: ?*const Rule = null;
    for (manifest.rules) |*rule| {
        if (best) |b| if (rule.priority <= b.priority) continue;
        const lines = regionLines(rule.region, rule.lines, in);
        if (matches(rule.match, lines.slice())) best = rule;
    }

    const rule = best orelse return .{ .state = .unknown };
    if (rule.hold) return .{ .state = .unknown, .rule = rule.id };
    return .{ .state = rule.state, .rule = rule.id };
}

// -- Lifecycle tracking ------------------------------------------------------

/// Turns per-frame classifications into a lifecycle, per pane.
///
/// Two jobs the stateless matcher can't do:
///
///  1. **`done` is a transition.** No screen ever *looks* "done" — it looks
///     idle. A run that was working and is now idle is what the user wants a
///     notification for, so the tracker synthesizes `.done` on that edge and
///     holds it until something else happens.
///  2. **Hooks outrank scraping.** `report()` records an authoritative event
///     from the agent itself (via `ipc.zig`). While hooks are live, scraped
///     frames are ignored entirely — an agent that tells us it's blocked is
///     never overruled by a guess about its footer.
pub const Tracker = struct {
    /// The state we're currently showing.
    state: State = .idle,
    /// Set once a hook has ever reported for this pane. Scraping then defers
    /// permanently: a hooked agent is a solved problem and mixing the two
    /// sources only produces flicker.
    hooked: bool = false,
    /// Id of the rule behind the current scraped state, for diagnostics.
    rule: ?[]const u8 = null,

    /// Feed an authoritative event from the agent's own hooks. Always wins.
    pub fn report(self: *Tracker, state: State) void {
        self.hooked = true;
        self.rule = null;
        self.state = state;
    }

    /// Feed one scraped frame. No-op once hooks have taken over. Returns true
    /// when the visible state changed, so callers can skip redundant redraws.
    pub fn observe(self: *Tracker, manifest: *const Manifest, in: Input) bool {
        if (self.hooked) return false;

        const verdict = classify(manifest, in);
        const next: State = switch (verdict.state) {
            // Nothing conclusive this frame — hold.
            .unknown => return false,
            // Returning to the prompt from an *active* state ends a run, and
            // that's what `done` means. Both edges count: an agent that
            // finished its work and one whose permission prompt was declined
            // have equally stopped and are equally waiting for you.
            .idle => switch (self.state) {
                .working, .blocked => .done,
                else => self.state_for_idle(),
            },
            else => verdict.state,
        };

        if (next == self.state) {
            self.rule = verdict.rule;
            return false;
        }
        self.state = next;
        self.rule = verdict.rule;
        return true;
    }

    /// An idle frame that didn't just end a run. `done` is sticky until the
    /// agent actually starts working again, so the "✓ done" badge doesn't
    /// vanish the instant the user glances away.
    fn state_for_idle(self: *const Tracker) State {
        return if (self.state == .done) .done else .idle;
    }
};

// -- Built-in manifests ------------------------------------------------------
//
// These are written from *observed* chrome. Each ruleset was checked against
// the real CLI driven inside a fixed-size tmux pane, reading back exactly the
// two things Roost gives the detector: the visible screen and the OSC title.
// Rules carry a VERIFIED / UNVERIFIED note so a later reader knows which ones
// rest on evidence and which are reasoned-but-untested.
//
// Three things that probing changed, worth stating because they're the traps:
//
//  1. **The OSC title is the best signal, and the footer is the worst.** Claude
//     Code 2.x does not print "esc to interrupt" while working at all — the
//     footer reads "✽ Whirlpooling… (8s · ↓ 6 tokens)". What reliably changes
//     is the title: a Braille spinner while working, "✳ " at rest.
//  2. **Spinner glyphs are not universally Braille.** claude and codex animate
//     Braille into the *title*, but claude's footer spinner is ✢/✶/✻/✽ and
//     opencode's is ⬝. A Braille-only footer rule silently never fires.
//  3. **A blocked agent can still look idle in its title.** Claude's plan
//     approval menu appears while the title still reads "✳ ". This is exactly
//     what the priority ordering is for: screen-based blocked rules must
//     outrank title-based idle rules, and they do.
//
// The shared shape: strong positive signals for working/blocked at high
// priority, and a low-priority idle rule matching a piece of persistent
// composer chrome. That idle rule is *deliberately* also true while the agent
// is working — priority resolves it, and it means "idle" is reached by the
// absence of anything more urgent rather than by a fragile positive match.

/// Claude Code (`claude`). Probed against 2.x on 2026-07-29.
pub const claude: Manifest = .{
    .id = "claude",
    .aliases = &.{ "claude-code", "claude.exe" },
    .rules = &.{
        // A transcript pager / help overlay covers the real footer. Hold
        // rather than misread the absence of a prompt as idle. UNVERIFIED.
        .{
            .id = "overlay_hold",
            .state = .unknown,
            .hold = true,
            .priority = 1000,
            .region = .bottom,
            .lines = 4,
            .match = .{ .any = &.{ "showing detailed transcript", "esc to close" } },
        },
        // VERIFIED: the plan-approval menu renders as
        //   "❯ 1. Yes, and use auto mode" / "  2. Yes, manually approve edits"
        // while the title still shows the idle glyph — so this must outrank
        // every title-based rule below.
        .{
            .id = "blocked_menu",
            .state = .blocked,
            .priority = 950,
            .region = .bottom,
            .lines = 12,
            .match = .{ .same_line_all = &.{ "1.", "yes" } },
        },
        // VERIFIED: "…is ready to execute. Would you like to proceed?".
        // "Do you want to…" is the wording on tool-permission prompts.
        .{
            .id = "blocked_question",
            .state = .blocked,
            .priority = 940,
            .region = .bottom,
            .lines = 12,
            .match = .{ .any = &.{ "would you like to proceed", "do you want to proceed" } },
        },
        // VERIFIED: the title animates Braille while a turn is running
        // ("⠂ Calculate basic arithmetic expression"). This is the single most
        // reliable claude signal.
        .{
            .id = "working_title_spinner",
            .state = .working,
            .priority = 900,
            .region = .title,
            .match = .spinner,
        },
        // UNVERIFIED for 2.x — the footer no longer carries this hint, but it
        // costs nothing and covers older builds / narrower layouts.
        .{
            .id = "working_interrupt_hint",
            .state = .working,
            .priority = 890,
            .region = .bottom,
            .lines = 6,
            .match = .{ .any = &.{"esc to interrupt"} },
        },
        // VERIFIED: at rest the title is "✳ Claude Code", and after a turn it
        // becomes "✳ <conversation summary>" — the ✳ prefix persists either way.
        .{
            .id = "idle_title_glyph",
            .state = .idle,
            .priority = 100,
            .region = .title,
            .match = .{ .any = &.{"✳"} },
        },
        // VERIFIED: the composer marker is present at rest. Kept as a second,
        // lower idle signal for when the title is unavailable.
        .{
            .id = "idle_composer",
            .state = .idle,
            .priority = 90,
            .region = .bottom,
            .lines = 6,
            .match = .{ .any = &.{ "shift+tab to cycle", "? for shortcuts" } },
        },
    },
};

/// OpenAI Codex CLI (`codex`). Probed against 0.139.0 on 2026-07-29.
pub const codex: Manifest = .{
    .id = "codex",
    .aliases = &.{"codex-cli"},
    .rules = &.{
        // UNVERIFIED (this install auto-approves shell commands, so no approval
        // prompt could be provoked). Same numbered-menu family as claude.
        .{
            .id = "blocked_menu",
            .state = .blocked,
            .priority = 950,
            .region = .bottom,
            .lines = 12,
            .match = .{ .same_line_all = &.{ "1.", "yes" } },
        },
        // VERIFIED: the update prompt ends with "Press enter to continue".
        .{
            .id = "blocked_prompt",
            .state = .blocked,
            .priority = 940,
            .region = .bottom,
            .lines = 12,
            .match = .{ .any = &.{ "press enter to continue", "allow command?", "(y/n)" } },
        },
        // VERIFIED: footer reads "• Working (2s • esc to interrupt)".
        .{
            .id = "working_interrupt_hint",
            .state = .working,
            .priority = 900,
            .region = .bottom,
            .lines = 6,
            .match = .{ .any = &.{ "esc to interrupt", "ctrl+c to stop" } },
        },
        // VERIFIED: title becomes "⠦ <dirname>" while working, plain "<dirname>"
        // at rest.
        .{
            .id = "working_title_spinner",
            .state = .working,
            .priority = 890,
            .region = .title,
            .match = .spinner,
        },
        // VERIFIED: the composer marker "›" is always drawn. Low priority, so
        // the working/blocked rules above win whenever they apply.
        .{
            .id = "idle_composer",
            .state = .idle,
            .priority = 100,
            .region = .bottom,
            .lines = 6,
            .match = .{ .any = &.{"›"} },
        },
    },
};

/// opencode (`opencode`). Probed against 1.18.9 on 2026-07-29.
pub const opencode: Manifest = .{
    .id = "opencode",
    .rules = &.{
        // UNVERIFIED — no permission prompt could be provoked in the probe.
        .{
            .id = "blocked_confirm",
            .state = .blocked,
            .priority = 950,
            .region = .bottom,
            .lines = 12,
            .match = .{ .any = &.{ "(y/n)", "[y/n]", "confirm?" } },
        },
        .{
            .id = "blocked_menu",
            .state = .blocked,
            .priority = 940,
            .region = .bottom,
            .lines = 12,
            .match = .{ .same_line_all = &.{ "1.", "yes" } },
        },
        // VERIFIED: the working footer reads "⬝⬝⬝⬝⬝⬝⬝⬝  esc interrupt" — note
        // there is no "to", which an "esc to interrupt" rule would miss. The
        // spinner here is ⬝ (U+2B1D), not Braille, so there is no spinner rule.
        .{
            .id = "working_interrupt_hint",
            .state = .working,
            .priority = 900,
            .region = .bottom,
            .lines = 6,
            .match = .{ .any = &.{ "esc interrupt", "esc to interrupt" } },
        },
        // VERIFIED: the status bar always carries "ctrl+p commands".
        .{
            .id = "idle_statusbar",
            .state = .idle,
            .priority = 100,
            .region = .bottom,
            .lines = 6,
            .match = .{ .any = &.{"ctrl+p commands"} },
        },
    },
};

/// Gemini CLI (`gemini`). Probed against 0.53.0 on 2026-07-29 — but the probe
/// machine has no API key, so only the startup/idle chrome could be observed.
/// The working rules here are UNVERIFIED.
pub const gemini: Manifest = .{
    .id = "gemini",
    .rules = &.{
        // VERIFIED: the trust-folder dialog renders "● 1. Trust folder (…)",
        // "2. Trust parent folder", "3. Don't trust"; the API-key dialog ends
        // "(Press Enter to submit, Esc to cancel, …)". Both are blocking.
        .{
            .id = "blocked_menu",
            .state = .blocked,
            .priority = 950,
            .region = .bottom,
            .lines = 14,
            .match = .{ .same_line_all = &.{ "1.", "trust" } },
        },
        .{
            .id = "blocked_prompt",
            .state = .blocked,
            .priority = 940,
            .region = .bottom,
            .lines = 14,
            .match = .{ .any = &.{
                "press enter to submit",
                "apply this change?",
                "(y/n)",
                "[y/n]",
            } },
        },
        // UNVERIFIED.
        .{
            .id = "working_interrupt_hint",
            .state = .working,
            .priority = 900,
            .region = .bottom,
            .lines = 6,
            .match = .{ .any = &.{ "esc to cancel", "esc to interrupt" } },
        },
        .{
            .id = "working_title_spinner",
            .state = .working,
            .priority = 890,
            .region = .title,
            .match = .spinner,
        },
        // VERIFIED: the title carries a status word — "◇  Ready (agentprobe)".
        // Note it reads "Ready" even while a modal dialog is blocking, which is
        // why this sits at the bottom of the priority list.
        .{
            .id = "idle_title_ready",
            .state = .idle,
            .priority = 100,
            .region = .title,
            .match = .{ .any = &.{"ready"} },
        },
    },
};

/// Fallback for any agent command we don't recognise. Only signals that held
/// across every CLI probed, so an unknown agent still gets a live badge instead
/// of a dead one. No idle rule: without knowing the CLI's chrome there is
/// nothing safe to match, and a wrong idle would fabricate "done" transitions.
pub const generic: Manifest = .{
    .id = "generic",
    .rules = &.{
        .{
            .id = "blocked_yn",
            .state = .blocked,
            .priority = 950,
            .region = .bottom,
            .lines = 10,
            .match = .{ .any = &.{ "(y/n)", "[y/n]", "press enter to continue" } },
        },
        .{
            .id = "blocked_menu",
            .state = .blocked,
            .priority = 940,
            .region = .bottom,
            .lines = 12,
            .match = .{ .same_line_all = &.{ "1.", "yes" } },
        },
        // Both claude and codex animate Braille into the title while working.
        .{
            .id = "working_title_spinner",
            .state = .working,
            .priority = 900,
            .region = .title,
            .match = .spinner,
        },
        // "esc interrupt" (opencode) / "esc to interrupt" (codex) — the closest
        // thing to a universal running hint.
        .{
            .id = "working_interrupt_hint",
            .state = .working,
            .priority = 890,
            .region = .bottom,
            .lines = 6,
            .match = .{ .any = &.{ "esc interrupt", "esc to interrupt", "ctrl+c to stop" } },
        },
    },
};

/// Every built-in manifest, in match order.
pub const builtins = [_]*const Manifest{ &claude, &codex, &opencode, &gemini };

/// The executable portion of a launch command: the first whitespace-delimited
/// token, with a quoted first token kept whole so a path containing spaces
/// survives.
///
///   `claude --resume`            → `claude`
///   `"/opt/my agent/claude" -x`  → `/opt/my agent/claude`
///
/// Used both to pick a manifest (via `commandName`) and by the shell to decide
/// whether the agent actually exists on PATH — the full string is still what
/// gets spawned, so arguments are preserved.
pub fn firstToken(cmd: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, cmd, " \t");
    if (trimmed.len == 0) return trimmed;
    // A quoted first token may legitimately contain spaces.
    if (trimmed[0] == '"' or trimmed[0] == '\'') {
        if (std.mem.indexOfScalarPos(u8, trimmed, 1, trimmed[0])) |end| return trimmed[1..end];
    }
    return if (std.mem.indexOfAny(u8, trimmed, " \t")) |i| trimmed[0..i] else trimmed;
}

/// The basename of the executable in a launch command, ignoring any arguments
/// and any leading path. `"/usr/bin/claude --resume"` → `"claude"`.
pub fn commandName(cmd: []const u8) []const u8 {
    const first = firstToken(cmd);
    if (std.mem.lastIndexOfScalar(u8, first, '/')) |i| return first[i + 1 ..];
    return first;
}

/// Pick the manifest for a pane launch command, falling back to `generic` so
/// callers never have to handle a null.
pub fn manifestFor(cmd: []const u8) *const Manifest {
    const name = commandName(cmd);
    if (name.len == 0) return &generic;
    for (builtins) |m| {
        if (std.ascii.eqlIgnoreCase(name, m.id)) return m;
        for (m.aliases) |a| {
            if (std.ascii.eqlIgnoreCase(name, a)) return m;
        }
    }
    return &generic;
}

// -- Tests -------------------------------------------------------------------

test "bottomLines skips blank tail and keeps order" {
    const screen = "alpha\nbravo\ncharlie\n\n   \n\n";
    const l = bottomLines(screen, 2);
    try std.testing.expectEqual(@as(usize, 2), l.len);
    try std.testing.expectEqualStrings("bravo", l.items[0]);
    try std.testing.expectEqualStrings("charlie", l.items[1]);
}

test "bottomLines handles a single unterminated line" {
    const l = bottomLines("only", 4);
    try std.testing.expectEqual(@as(usize, 1), l.len);
    try std.testing.expectEqualStrings("only", l.items[0]);
}

test "bottomLines on empty input" {
    try std.testing.expectEqual(@as(usize, 0), bottomLines("", 4).len);
    try std.testing.expectEqual(@as(usize, 0), bottomLines("\n\n  \n", 4).len);
}

test "bottomLines respects the cap" {
    var buf: [1024]u8 = undefined;
    var w: usize = 0;
    for (0..40) |i| {
        w += (std.fmt.bufPrint(buf[w..], "line{d}\n", .{i}) catch unreachable).len;
    }
    const l = bottomLines(buf[0..w], 255);
    try std.testing.expectEqual(@as(usize, max_bottom_lines), l.len);
}

test "spinner detection covers the braille block" {
    try std.testing.expect(startsWithSpinner("\u{2809} Thinking…"));
    try std.testing.expect(startsWithSpinner("\u{28FF} Working"));
    try std.testing.expect(startsWithSpinner("\u{2800}"));
    try std.testing.expect(!startsWithSpinner("* Thinking"));
    try std.testing.expect(!startsWithSpinner("\u{2500} rule"));
    try std.testing.expect(!startsWithSpinner(""));
    try std.testing.expect(!startsWithSpinner("ab"));
}

test "claude: interrupt hint reads as working" {
    const screen =
        \\  Reading file src/main.zig
        \\
        \\  * Cogitating… (12s · 1.2k tokens · esc to interrupt)
    ;
    const v = classify(&claude, .{ .screen = screen });
    try std.testing.expectEqual(State.working, v.state);
    try std.testing.expectEqualStrings("working_interrupt_hint", v.rule.?);
}

test "claude: permission menu reads as blocked and outranks working" {
    const screen =
        \\  Do you want to run this command?
        \\
        \\  > 1. Yes
        \\    2. Yes, and don't ask again
        \\    3. No, and tell Claude what to do differently (esc to interrupt)
    ;
    const v = classify(&claude, .{ .screen = screen });
    try std.testing.expectEqual(State.blocked, v.state);
    try std.testing.expectEqualStrings("blocked_menu", v.rule.?);
}

test "claude: prompt footer reads as idle" {
    const screen =
        \\ > |
        \\
        \\  ? for shortcuts
    ;
    try std.testing.expectEqual(State.idle, classify(&claude, .{ .screen = screen }).state);
}

test "claude: title spinner reads as working with a quiet screen" {
    const v = classify(&claude, .{ .screen = "just some output\n", .title = "\u{2809} claude" });
    try std.testing.expectEqual(State.working, v.state);
    try std.testing.expectEqualStrings("working_title_spinner", v.rule.?);
}

test "claude: overlay holds instead of reporting a state" {
    const screen =
        \\  showing detailed transcript
        \\  ctrl+o to toggle
    ;
    const v = classify(&claude, .{ .screen = screen });
    try std.testing.expectEqual(State.unknown, v.state);
    try std.testing.expectEqualStrings("overlay_hold", v.rule.?);
}

test "nothing matches yields unknown" {
    const v = classify(&claude, .{ .screen = "$ ls\nREADME.md\n" });
    try std.testing.expectEqual(State.unknown, v.state);
    try std.testing.expect(v.rule == null);
}

test "same_line_all does not match needles split across lines" {
    const lines = [_][]const u8{ "1.", "yes" };
    try std.testing.expect(!matches(.{ .same_line_all = &.{ "1.", "yes" } }, &lines));
    const one = [_][]const u8{"> 1. Yes"};
    try std.testing.expect(matches(.{ .same_line_all = &.{ "1.", "yes" } }, &one));
}

test "all matches needles spread across lines" {
    const lines = [_][]const u8{ "do you want to proceed?", "3. No, and tell Claude something" };
    try std.testing.expect(matches(.{ .all = &.{ "do you want", "no, and tell claude" } }, &lines));
    try std.testing.expect(!matches(.{ .all = &.{ "do you want", "absent" } }, &lines));
}

test "empty needle lists never match" {
    const lines = [_][]const u8{"anything"};
    try std.testing.expect(!matches(.{ .all = &.{} }, &lines));
    try std.testing.expect(!matches(.{ .any = &.{} }, &lines));
    try std.testing.expect(!matches(.{ .same_line_all = &.{} }, &lines));
}

test "tracker synthesizes done on working -> idle" {
    var t: Tracker = .{};
    const busy = "  * Working… (esc to interrupt)";
    const done = "  ? for shortcuts";

    try std.testing.expect(t.observe(&claude, .{ .screen = busy }));
    try std.testing.expectEqual(State.working, t.state);

    try std.testing.expect(t.observe(&claude, .{ .screen = done }));
    try std.testing.expectEqual(State.done, t.state);
}

test "tracker synthesizes done on blocked -> idle" {
    var t: Tracker = .{};
    const prompt =
        \\  Do you want to run this command?
        \\  > 1. Yes
    ;
    try std.testing.expect(t.observe(&claude, .{ .screen = prompt }));
    try std.testing.expectEqual(State.blocked, t.state);

    try std.testing.expect(t.observe(&claude, .{ .screen = "  ? for shortcuts" }));
    try std.testing.expectEqual(State.done, t.state);
}

test "tracker stays idle when it never started" {
    var t: Tracker = .{};
    try std.testing.expect(!t.observe(&claude, .{ .screen = "  ? for shortcuts" }));
    try std.testing.expectEqual(State.idle, t.state);
}

test "tracker holds done until work resumes" {
    var t: Tracker = .{ .state = .done };
    const idle_screen = "  ? for shortcuts";
    try std.testing.expect(!t.observe(&claude, .{ .screen = idle_screen }));
    try std.testing.expectEqual(State.done, t.state);

    try std.testing.expect(t.observe(&claude, .{ .screen = "  * Go… (esc to interrupt)" }));
    try std.testing.expectEqual(State.working, t.state);
}

test "tracker holds state on an unknown frame" {
    var t: Tracker = .{};
    _ = t.observe(&claude, .{ .screen = "  * Working… (esc to interrupt)" });
    try std.testing.expectEqual(State.working, t.state);
    try std.testing.expect(!t.observe(&claude, .{ .screen = "unrelated output" }));
    try std.testing.expectEqual(State.working, t.state);
}

test "hooks outrank scraping permanently" {
    var t: Tracker = .{};
    t.report(.blocked);
    try std.testing.expectEqual(State.blocked, t.state);
    // A screen that would otherwise scream "working" must not override it.
    try std.testing.expect(!t.observe(&claude, .{ .screen = "  * Go… (esc to interrupt)" }));
    try std.testing.expectEqual(State.blocked, t.state);
}

test "commandName strips path and arguments" {
    try std.testing.expectEqualStrings("claude", commandName("claude"));
    try std.testing.expectEqualStrings("claude", commandName("/usr/bin/claude --resume"));
    try std.testing.expectEqualStrings("codex", commandName("  codex   exec  "));
    try std.testing.expectEqualStrings("", commandName("   "));
}

test "firstToken keeps the executable and drops arguments" {
    try std.testing.expectEqualStrings("claude", firstToken("claude"));
    try std.testing.expectEqualStrings("claude", firstToken("claude --resume"));
    try std.testing.expectEqualStrings("/usr/bin/claude", firstToken("/usr/bin/claude --resume"));
    try std.testing.expectEqualStrings("codex", firstToken("  codex   exec  "));
    try std.testing.expectEqualStrings("", firstToken("   "));
    try std.testing.expectEqualStrings("", firstToken(""));
}

test "firstToken keeps a quoted path containing spaces whole" {
    try std.testing.expectEqualStrings("/opt/my agent/claude", firstToken("\"/opt/my agent/claude\" --resume"));
    try std.testing.expectEqualStrings("/opt/my agent/claude", firstToken("'/opt/my agent/claude'"));
    // Unterminated quote: fall back to whitespace splitting rather than
    // swallowing the whole string.
    try std.testing.expectEqualStrings("\"/opt/my", firstToken("\"/opt/my agent/claude"));
    try std.testing.expectEqualStrings("claude", commandName("\"/opt/my agent/claude\" --resume"));
}

test "manifestFor resolves ids, aliases, and falls back" {
    try std.testing.expectEqualStrings("claude", manifestFor("/usr/local/bin/claude --continue").id);
    try std.testing.expectEqualStrings("claude", manifestFor("claude-code").id);
    try std.testing.expectEqualStrings("codex", manifestFor("codex").id);
    try std.testing.expectEqualStrings("generic", manifestFor("fish").id);
    try std.testing.expectEqualStrings("generic", manifestFor("").id);
}

test "generic manifest still catches spinner and y/n" {
    try std.testing.expectEqual(
        State.working,
        classify(&generic, .{ .screen = "out", .title = "\u{2809} busy" }).state,
    );
    try std.testing.expectEqual(
        State.blocked,
        classify(&generic, .{ .screen = "Overwrite file? (y/n)" }).state,
    );
}

// -- Captured-screen regression tests ---------------------------------------
//
// The screens below are verbatim captures from the real CLIs (fixed 120x32
// tmux pane, 2026-07-29), trimmed to the trailing rows the detector actually
// looks at. They exist so that a rule tweak which happens to satisfy a
// hand-written fixture but breaks against real chrome fails here instead of in
// the user's window.

test "captured claude 2.x: idle" {
    const screen =
        \\────────────────────────────────────────────
        \\❯ Try "create a util logging.py that..."
        \\────────────────────────────────────────────
        \\  …/scratchpad/agentprobe 0dd14d9  Opus 5 (1M context)
        \\  ⏵⏵ accept edits on (shift+tab to cycle) · ← 1 agent
    ;
    const v = classify(&claude, .{ .screen = screen, .title = "✳ Claude Code" });
    try std.testing.expectEqual(State.idle, v.state);
}

test "captured claude 2.x: working has no interrupt hint, only a title spinner" {
    const screen =
        \\✽ Whirlpooling… (8s · ↓ 6 tokens)
        \\  ⎿  Tip: Connect Claude to your IDE · /ide
        \\────────────────────────────────────────────
        \\❯
        \\────────────────────────────────────────────
        \\  …/scratchpad/agentprobe 0dd14d9  Opus 5 (1M context) ctx:97%
        \\  ⏵⏵ accept edits on (shift+tab to cycle) · ← 1 agent
    ;
    // The screen alone is ambiguous — the composer chrome is still on it — so
    // this is the case that proves the title carries the signal.
    const v = classify(&claude, .{ .screen = screen, .title = "⠐ Calculate basic arithmetic expression" });
    try std.testing.expectEqual(State.working, v.state);
    try std.testing.expectEqualStrings("working_title_spinner", v.rule.?);
}

test "captured claude 2.x: plan approval blocks even though the title reads idle" {
    const screen =
        \\ Claude has written up a plan and is ready to execute. Would you like to proceed?
        \\ ❯ 1. Yes, and use auto mode
        \\   2. Yes, manually approve edits
        \\   3. No, refine with Ultraplan on Claude Code on the web
        \\   4. Tell Claude what to change
        \\      shift+tab to approve with this feedback
    ;
    // Title is the *idle* glyph here — this is the real trap, and the reason
    // screen-based blocked rules outrank title-based idle ones.
    const v = classify(&claude, .{ .screen = screen, .title = "✳ Calculate basic arithmetic expression" });
    try std.testing.expectEqual(State.blocked, v.state);
    try std.testing.expectEqualStrings("blocked_menu", v.rule.?);
}

test "captured codex 0.139: working" {
    const screen =
        \\• Working (2s • esc to interrupt)
        \\› Find and fix a bug in @filename
        \\  gpt-5.5 xhigh · /tmp/scratchpad/agentprobe
    ;
    const v = classify(&codex, .{ .screen = screen, .title = "⠦ agentprobe" });
    try std.testing.expectEqual(State.working, v.state);
}

test "captured codex 0.139: idle" {
    const screen =
        \\  Tip: You can run any shell command from Codex using ! (e.g. !ls)
        \\› Find and fix a bug in @filename
        \\  gpt-5.5 xhigh · /tmp/scratchpad/agentprobe
    ;
    const v = classify(&codex, .{ .screen = screen, .title = "agentprobe" });
    try std.testing.expectEqual(State.idle, v.state);
}

test "captured codex 0.139: update prompt blocks" {
    const screen =
        \\  ✨ Update available! 0.139.0 -> 0.142.4
        \\› 1. Update now (runs `npm install -g @openai/codex`)
        \\  2. Skip
        \\  3. Skip until next version
        \\  Press enter to continue
    ;
    try std.testing.expectEqual(
        State.blocked,
        classify(&codex, .{ .screen = screen, .title = "omarchy" }).state,
    );
}

test "captured opencode 1.18: working says 'esc interrupt' with no 'to'" {
    const screen =
        \\  ┃  Build · GPT-5.5 OpenAI · high
        \\  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
        \\   ⬝⬝⬝⬝⬝⬝⬝⬝  esc interrupt                    tab agents  ctrl+p commands
    ;
    const v = classify(&opencode, .{ .screen = screen, .title = "OpenCode" });
    try std.testing.expectEqual(State.working, v.state);
    try std.testing.expectEqualStrings("working_interrupt_hint", v.rule.?);
}

test "captured opencode 1.18: idle" {
    const screen =
        \\                       ┃  Ask anything... "Fix a TODO in the codebase"
        \\                       ┃  Build · GPT-5.5 OpenAI · high
        \\                       tab agents  ctrl+p commands
        \\  /tmp/scratchpad/agentprobe:       1.18.9
        \\  main
    ;
    try std.testing.expectEqual(
        State.idle,
        classify(&opencode, .{ .screen = screen, .title = "OpenCode" }).state,
    );
}

test "captured gemini 0.53: trust dialog blocks despite a 'Ready' title" {
    const screen =
        \\ │ Do you trust the files in this folder?
        \\ │ ● 1. Trust folder (agentprobe)
        \\ │   2. Trust parent folder (scratchpad)
        \\ │   3. Don't trust
    ;
    const v = classify(&gemini, .{ .screen = screen, .title = "◇  Ready (agentprobe)" });
    try std.testing.expectEqual(State.blocked, v.state);
    try std.testing.expectEqualStrings("blocked_menu", v.rule.?);
}

test "captured gemini 0.53: api-key dialog blocks" {
    const screen =
        \\ │ Enter Gemini API Key
        \\ │ (Press Enter to submit, Esc to cancel, Ctrl+C to clear stored key)
    ;
    try std.testing.expectEqual(
        State.blocked,
        classify(&gemini, .{ .screen = screen, .title = "◇  Ready (agentprobe)" }).state,
    );
}

test "generic fallback never fabricates idle" {
    // No idle rule on `generic`: an unknown agent sitting at its prompt must
    // stay `.unknown` (caller holds state) rather than produce a bogus
    // working -> idle edge and a phantom "done" notification.
    const v = classify(&generic, .{ .screen = "some quiet prompt here", .title = "whatever" });
    try std.testing.expectEqual(State.unknown, v.state);

    var t: Tracker = .{};
    _ = t.observe(&generic, .{ .screen = "x", .title = "⠹ busy" });
    try std.testing.expectEqual(State.working, t.state);
    try std.testing.expect(!t.observe(&generic, .{ .screen = "quiet", .title = "quiet" }));
    try std.testing.expectEqual(State.working, t.state); // held, not "done"
}

test "attention ranking orders the rollup" {
    try std.testing.expect(State.blocked.attention() > State.done.attention());
    try std.testing.expect(State.done.attention() > State.working.attention());
    try std.testing.expect(State.working.attention() > State.idle.attention());
    try std.testing.expect(State.idle.attention() > State.unknown.attention());
}
