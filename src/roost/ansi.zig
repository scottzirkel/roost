//! Strip ANSI / VT escape sequences from streamed bytes.
//!
//! Wired-action output is captured raw and shown in a plain `gtk.TextView` (and
//! routed into the scratchpad / a terminal). Tools that draw progress — a test
//! runner spitting dim dots, a spinner — emit SGR colour codes like
//! `ESC[90;1m.ESC[39;22m`. A real terminal renders those as styled text; a plain
//! TextView prints the codes literally (and the bare `ESC` shows as a tofu box).
//! This strips them so every non-terminal sink sees just the text.
//!
//! ADDITIVE and deliberately **std-only** (no GTK / no Ghostty internals) so it
//! unit-tests standalone like `md.zig` / `actions.zig`.
//!
//! `Stripper` is a tiny state machine that survives arbitrary chunk boundaries:
//! an escape sequence split across two `feed` calls is recognized because the
//! parse state persists on the struct. CSI (`ESC [ … <final 0x40–0x7e>`) and OSC
//! (`ESC ] … BEL` / `ESC ] … ESC \`) are dropped whole; any other `ESC <byte>`
//! two-char escape drops both bytes; everything else (printable, `\n`, `\t`,
//! `\r`) passes through untouched.
//!
//! It also re-syncs on malformed input so a stray byte can't corrupt the rest of
//! the stream: a doubled/leading `ESC` re-arms the parser (instead of being eaten
//! as a two-char escape's payload), an `ESC` inside a CSI starts a fresh escape,
//! and an unterminated CSI/OSC (no final byte / BEL / ST) is abandoned after a
//! bounded run so it can never swallow output indefinitely.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Stripper = struct {
    state: State = .text,
    /// Bytes consumed so far inside the current CSI/OSC drop run. Reset on entry
    /// to `.csi`/`.osc`; once it exceeds `max_run` the (malformed/unterminated)
    /// sequence is abandoned and we re-sync to `.text` so output keeps flowing.
    run: u16 = 0,

    /// Cap on a single CSI/OSC drop run. Generous — real CSI runs are a handful
    /// of bytes and even an OSC title/hyperlink is well under this — so it only
    /// ever trips on a genuinely runaway, never-terminated sequence.
    const max_run: u16 = 4096;

    const State = enum {
        text, // normal bytes
        esc, // just saw ESC (0x1b)
        csi, // inside ESC [ … (until a 0x40–0x7e final byte)
        osc, // inside ESC ] … (until BEL or ESC \)
        osc_esc, // inside OSC, just saw ESC (expecting '\' to finish ST)
    };

    /// Feed `input`; append the escape-free bytes to `out`. The parse state
    /// carries over between calls, so callers can feed stream chunks of any size.
    pub fn feed(self: *Stripper, alloc: Allocator, out: *std.ArrayListUnmanaged(u8), input: []const u8) Allocator.Error!void {
        for (input) |b| {
            // Re-sync guard: an unterminated CSI/OSC must not drop output forever.
            // After `max_run` consumed bytes, abandon the run and fall through to
            // process `b` as ordinary text below.
            switch (self.state) {
                .csi, .osc, .osc_esc => {
                    self.run += 1;
                    if (self.run > max_run) self.state = .text;
                },
                else => {},
            }
            switch (self.state) {
                .text => {
                    if (b == 0x1b) self.state = .esc else try out.append(alloc, b);
                },
                .esc => switch (b) {
                    '[' => {
                        self.state = .csi;
                        self.run = 0;
                    },
                    ']' => {
                        self.state = .osc;
                        self.run = 0;
                    },
                    // A second ESC re-arms the parser instead of being swallowed
                    // as this escape's second byte, so `ESC ESC [31m` still strips.
                    0x1b => {},
                    // Any other Fe/Fs escape (e.g. ESC =, ESC >) is two bytes total;
                    // we've now consumed the second, so we're done. (Charset
                    // designators like ESC ( B would leak the trailing 'B' — rare in
                    // command output, accepted.)
                    else => self.state = .text,
                },
                .csi => {
                    // Parameter/intermediate bytes are 0x20–0x3f; a 0x40–0x7e byte
                    // is the final byte that ends the sequence. A stray ESC means
                    // the CSI was never terminated — re-sync to a fresh escape.
                    if (b == 0x1b) {
                        self.state = .esc;
                    } else if (b >= 0x40 and b <= 0x7e) {
                        self.state = .text;
                    }
                },
                .osc => switch (b) {
                    0x07 => self.state = .text, // BEL terminates
                    0x1b => self.state = .osc_esc, // maybe ST (ESC \)
                    else => {},
                },
                // Expecting '\' to finish ST. A further ESC keeps us armed (the
                // run guard still bounds it); anything else ends the OSC.
                .osc_esc => switch (b) {
                    0x1b => {},
                    else => self.state = .text,
                },
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests (pure: run with `zig test src/roost/ansi.zig`)
// ---------------------------------------------------------------------------

/// Strip `input` in one shot via a fresh Stripper; caller frees the result.
fn stripAll(alloc: Allocator, input: []const u8) ![]u8 {
    var s: Stripper = .{};
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try s.feed(alloc, &out, input);
    return out.toOwnedSlice(alloc);
}

test "strips SGR colour codes, keeps the text" {
    const alloc = std.testing.allocator;
    // Dim-dot progress: ESC[90;1m . ESC[39;22m, three times.
    const in = "\x1b[90;1m.\x1b[39;22m\x1b[90;1m.\x1b[39;22m\x1b[90;1m.\x1b[39;22m";
    const out = try stripAll(alloc, in);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("...", out);
}

test "keeps newlines, tabs, and plain text" {
    const alloc = std.testing.allocator;
    const in = "\x1b[31mError:\x1b[0m\tfile\n\x1b[32mok\x1b[0m\n";
    const out = try stripAll(alloc, in);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Error:\tfile\nok\n", out);
}

test "strips OSC (window title) sequences, both BEL and ST terminated" {
    const alloc = std.testing.allocator;
    const bel = try stripAll(alloc, "\x1b]0;my title\x07hi");
    defer alloc.free(bel);
    try std.testing.expectEqualStrings("hi", bel);

    const st = try stripAll(alloc, "\x1b]0;my title\x1b\\hi");
    defer alloc.free(st);
    try std.testing.expectEqualStrings("hi", st);
}

test "handles a sequence split across feed() calls" {
    const alloc = std.testing.allocator;
    var s: Stripper = .{};
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    // "a" + start of CSI, then the rest of the CSI + "b".
    try s.feed(alloc, &out, "a\x1b[3");
    try s.feed(alloc, &out, "1mb");
    try std.testing.expectEqualStrings("ab", out.items);
}

test "two-char escapes drop both bytes" {
    const alloc = std.testing.allocator;
    const out = try stripAll(alloc, "x\x1b=y\x1b>z");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("xyz", out);
}

test "no escapes: passthrough unchanged" {
    const alloc = std.testing.allocator;
    const out = try stripAll(alloc, "plain text 123\n");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("plain text 123\n", out);
}

test "doubled/stray ESC re-arms the parser (no leaked SGR)" {
    const alloc = std.testing.allocator;
    // A stray ESC immediately before a real CSI must still strip the SGR code
    // rather than eating the ESC as a two-char escape and leaking "[31m".
    const out = try stripAll(alloc, "\x1b\x1b[31mX");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("X", out);
}

test "ESC inside an unterminated CSI re-syncs to a fresh escape" {
    const alloc = std.testing.allocator;
    // First CSI has no final byte; the ESC starts a fresh, complete one.
    const out = try stripAll(alloc, "\x1b[31\x1b[0mX");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("X", out);
}

test "an unterminated CSI does not swallow output forever" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "\x1b["); // open CSI, never emit a final byte
    try buf.appendNTimes(alloc, '3', Stripper.max_run + 10); // runaway params
    try buf.append(alloc, 'X');
    const out = try stripAll(alloc, buf.items);
    defer alloc.free(out);
    // The drop run is bounded, so the trailing text survives and only the
    // overflow past the cap leaks — not the whole runaway run.
    try std.testing.expect(std.mem.endsWith(u8, out, "X"));
    try std.testing.expect(out.len <= 11);
}

test "an unterminated OSC does not swallow output forever" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "\x1b]0;"); // open OSC, never terminate
    try buf.appendNTimes(alloc, 'a', Stripper.max_run + 5);
    try buf.append(alloc, 'Z');
    const out = try stripAll(alloc, buf.items);
    defer alloc.free(out);
    try std.testing.expect(std.mem.endsWith(u8, out, "Z"));
    try std.testing.expect(out.len <= 11);
}
