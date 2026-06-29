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

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Stripper = struct {
    state: State = .text,

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
        for (input) |b| switch (self.state) {
            .text => {
                if (b == 0x1b) self.state = .esc else try out.append(alloc, b);
            },
            .esc => switch (b) {
                '[' => self.state = .csi,
                ']' => self.state = .osc,
                // Any other Fe/Fs escape (e.g. ESC =, ESC >) is two bytes total;
                // we've now consumed the second, so we're done. (Charset
                // designators like ESC ( B would leak the trailing 'B' — rare in
                // command output, accepted.)
                else => self.state = .text,
            },
            .csi => {
                // Parameter/intermediate bytes are 0x20–0x3f; a 0x40–0x7e byte is
                // the final byte that ends the sequence.
                if (b >= 0x40 and b <= 0x7e) self.state = .text;
            },
            .osc => switch (b) {
                0x07 => self.state = .text, // BEL terminates
                0x1b => self.state = .osc_esc, // maybe ST (ESC \)
                else => {},
            },
            .osc_esc => self.state = .text, // consume the '\' (or whatever) and end
        };
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
