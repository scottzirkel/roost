//! md.zig — a tiny, pure (no GTK) subset-markdown scanner for the scratchpad's
//! Typora-style live styling. It does NOT render: it returns a flat list of
//! `Span`s (character ranges + a `Kind`) that `scratchpad_pane.zig` turns into
//! GtkTextTags. Keeping it free of any GTK dependency makes it unit-testable.
//!
//! Offsets are in CHARACTERS (Unicode codepoints), counted from the start of the
//! buffer — exactly what `gtk.TextBuffer.getIterAtOffset` consumes. Lines are
//! split on '\n'; each line contributes `codepoints + 1` characters to the
//! running offset (the +1 is the newline).
//!
//! Supported (v1): ATX headings `#`/`##`/`###`, `**bold**`, `*italic*`/`_italic_`,
//! `` `inline code` ``, `> blockquote`, and `- `/`* `/`+ ` list markers. Marker
//! characters (the `#`, `**`, backticks, `> `) are emitted as `.marker` spans so
//! the pane can hide them everywhere except the cursor's line. Deferred: fenced
//! ``` code blocks (lines starting with ``` are left unstyled), links, tables.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    h1,
    h2,
    h3,
    bold,
    italic,
    code,
    quote,
    /// A leading list bullet (`- `, `* `, `+ `): styled dim, never hidden.
    list_marker,
    /// Syntax punctuation (`#`, `**`, `*`, `` ` ``, `> `): hidden off the cursor
    /// line, shown dim on it.
    marker,
};

/// A styled range, `[start, end)` in character offsets from the buffer start.
pub const Span = struct {
    start: u32,
    end: u32,
    kind: Kind,
};

/// Scan `text` into styled spans. Caller owns the returned slice (free with the
/// same allocator). Allocates only transient per-line scratch otherwise.
pub fn parse(alloc: Allocator, text: []const u8) ![]Span {
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    errdefer spans.deinit(alloc);

    // Reused per line: the line's codepoints. Working in codepoints (not bytes)
    // keeps every offset correct in the presence of multibyte UTF-8.
    var cols: std.ArrayListUnmanaged(u21) = .empty;
    defer cols.deinit(alloc);

    var base: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try decodeCols(alloc, line, &cols);
        try parseLine(alloc, &spans, cols.items, base);
        base += @intCast(cols.items.len + 1); // +1 for the '\n' between lines
    }
    return spans.toOwnedSlice(alloc);
}

/// Decode `line` into codepoints. On invalid UTF-8 we fall back to treating each
/// byte as its own codepoint, which keeps offsets self-consistent with `parse`'s
/// `cols.items.len` advance (we never desync bytes vs codepoints).
fn decodeCols(alloc: Allocator, line: []const u8, out: *std.ArrayListUnmanaged(u21)) !void {
    out.clearRetainingCapacity();
    const view = std.unicode.Utf8View.init(line) catch {
        for (line) |b| try out.append(alloc, b);
        return;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| try out.append(alloc, cp);
}

fn parseLine(alloc: Allocator, spans: *std.ArrayListUnmanaged(Span), cols: []const u21, base: u32) !void {
    const n: u32 = @intCast(cols.len);
    if (n == 0) return;

    // Fenced code blocks are deferred: leave a ``` line entirely unstyled so its
    // backticks don't get mis-paired as inline code.
    if (n >= 3 and cols[0] == '`' and cols[1] == '`' and cols[2] == '`') return;

    // The column where inline scanning begins (past any block prefix).
    var content_start: u32 = 0;

    // --- block prefixes ---
    // ATX heading: 1–3 leading '#' then a space.
    var hashes: u32 = 0;
    while (hashes < n and cols[hashes] == '#') hashes += 1;
    if (hashes >= 1 and hashes <= 3 and hashes < n and cols[hashes] == ' ') {
        const kind: Kind = switch (hashes) {
            1 => .h1,
            2 => .h2,
            else => .h3,
        };
        // Hide the "### " prefix; style the remainder as the heading.
        try spans.append(alloc, .{ .start = base, .end = base + hashes + 1, .kind = .marker });
        if (hashes + 1 < n) try spans.append(alloc, .{ .start = base + hashes + 1, .end = base + n, .kind = kind });
        content_start = hashes + 1;
    } else if (cols[0] == '>') {
        // Blockquote: "> " (or a bare ">").
        const mlen: u32 = if (n >= 2 and cols[1] == ' ') 2 else 1;
        try spans.append(alloc, .{ .start = base, .end = base + mlen, .kind = .marker });
        if (mlen < n) try spans.append(alloc, .{ .start = base + mlen, .end = base + n, .kind = .quote });
        content_start = mlen;
    } else {
        // List item: optional indent, then one of -,*,+ , then a space.
        var sp: u32 = 0;
        while (sp < n and cols[sp] == ' ') sp += 1;
        if (sp < n and (cols[sp] == '-' or cols[sp] == '*' or cols[sp] == '+') and
            sp + 1 < n and cols[sp + 1] == ' ')
        {
            try spans.append(alloc, .{ .start = base + sp, .end = base + sp + 2, .kind = .list_marker });
            content_start = sp + 2;
        }
    }

    try scanInline(alloc, spans, cols, base, content_start, n);
}

/// Left-to-right inline scan for `code`, `**bold**`, and `*`/`_` italic. Each
/// recognized run emits a content span plus `.marker` spans over its delimiters.
/// An unmatched delimiter is treated as a literal character. Code is matched
/// first so `*`/`_` inside `` `code` `` are left alone.
///
/// Emphasis (`*`/`_`) obeys a practical subset of CommonMark "flanking" so prose
/// like `5 * 6 * 7` and identifiers like `my_var_name` don't get mangled into
/// italics: an opening run must be immediately followed by a non-space char and a
/// closing run immediately preceded by one, and `_` may not sit inside a word.
fn scanInline(
    alloc: Allocator,
    spans: *std.ArrayListUnmanaged(Span),
    cols: []const u21,
    base: u32,
    start: u32,
    n: u32,
) !void {
    var i = start;
    while (i < n) {
        const c = cols[i];
        if (c == '`') {
            if (findChar(cols, i + 1, n, '`')) |j| {
                try emitDelimited(alloc, spans, base, i, i + 1, j, j + 1, .code);
                i = j + 1;
                continue;
            }
        } else if (c == '*' and i + 1 < n and cols[i + 1] == '*') {
            if (canOpen(cols, i, 2, n)) {
                if (findEmphClose(cols, i + 2, n, '*', 2)) |j| {
                    try emitDelimited(alloc, spans, base, i, i + 2, j, j + 2, .bold);
                    i = j + 2;
                    continue;
                }
            }
        } else if (c == '*' or c == '_') {
            if (canOpen(cols, i, 1, n)) {
                if (findEmphClose(cols, i + 1, n, c, 1)) |j| {
                    try emitDelimited(alloc, spans, base, i, i + 1, j, j + 1, .italic);
                    i = j + 1;
                    continue;
                }
            }
        }
        i += 1;
    }
}

/// Emit the content span `[open_end, close_start)` with `kind`, plus a `.marker`
/// span over the opening delimiter `[open_start, open_end)` and the closing one
/// `[close_start, close_end)`. The content span is skipped if empty.
fn emitDelimited(
    alloc: Allocator,
    spans: *std.ArrayListUnmanaged(Span),
    base: u32,
    open_start: u32,
    open_end: u32,
    close_start: u32,
    close_end: u32,
    kind: Kind,
) !void {
    try spans.append(alloc, .{ .start = base + open_start, .end = base + open_end, .kind = .marker });
    if (close_start > open_end) try spans.append(alloc, .{ .start = base + open_end, .end = base + close_start, .kind = kind });
    try spans.append(alloc, .{ .start = base + close_start, .end = base + close_end, .kind = .marker });
}

fn findChar(cols: []const u21, from: u32, n: u32, ch: u21) ?u32 {
    var i = from;
    while (i < n) : (i += 1) {
        if (cols[i] == ch) return i;
    }
    return null;
}

fn isSpaceCp(cp: u21) bool {
    return cp == ' ' or cp == '\t';
}

/// A "word" character for the intraword-`_` rule: ASCII alphanumerics plus any
/// non-ASCII codepoint (assumed to be a letter). Keeps `a_b` / `my_var_name`
/// literal while letting `_x_` and `(_x_)` still emphasize.
fn isWordCp(cp: u21) bool {
    return (cp >= '0' and cp <= '9') or
        (cp >= 'a' and cp <= 'z') or
        (cp >= 'A' and cp <= 'Z') or
        cp >= 0x80;
}

/// Can a `run`-long delimiter run starting at `i` OPEN emphasis? It must be
/// left-flanking (immediately followed by a non-space char), and `_` may not
/// open inside a word (preceded by a word char).
fn canOpen(cols: []const u21, i: u32, run: u32, n: u32) bool {
    const after = i + run;
    if (after >= n or isSpaceCp(cols[after])) return false;
    if (cols[i] == '_' and i > 0 and isWordCp(cols[i - 1])) return false;
    return true;
}

/// Can a `run`-long delimiter run starting at `j` CLOSE emphasis? It must be
/// right-flanking (immediately preceded by a non-space char), and `_` may not
/// close inside a word (followed by a word char).
fn canClose(cols: []const u21, j: u32, run: u32, n: u32) bool {
    if (j == 0 or isSpaceCp(cols[j - 1])) return false;
    const after = j + run;
    if (cols[j] == '_' and after < n and isWordCp(cols[after])) return false;
    return true;
}

/// Find the next `run`-long run of `ch` at or after `from` that is a valid
/// closing delimiter, returning the index of its first character.
fn findEmphClose(cols: []const u21, from: u32, n: u32, ch: u21, run: u32) ?u32 {
    var i = from;
    while (i + run <= n) : (i += 1) {
        if (cols[i] != ch) continue;
        if (run == 2 and cols[i + 1] != ch) continue;
        if (canClose(cols, i, run, n)) return i;
    }
    return null;
}

// --- tests ----------------------------------------------------------------

const testing = std.testing;

fn expectSpan(spans: []const Span, idx: usize, start: u32, end: u32, kind: Kind) !void {
    try testing.expect(idx < spans.len);
    try testing.expectEqual(start, spans[idx].start);
    try testing.expectEqual(end, spans[idx].end);
    try testing.expectEqual(kind, spans[idx].kind);
}

test "heading: marker + content" {
    const spans = try parse(testing.allocator, "# Title");
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 2), spans.len);
    try expectSpan(spans, 0, 0, 2, .marker); // "# "
    try expectSpan(spans, 1, 2, 7, .h1); // "Title"
}

test "h2/h3 levels" {
    const s2 = try parse(testing.allocator, "## Two");
    defer testing.allocator.free(s2);
    try expectSpan(s2, 1, 3, 6, .h2);
    const s3 = try parse(testing.allocator, "### Three");
    defer testing.allocator.free(s3);
    try expectSpan(s3, 1, 4, 9, .h3);
    // Four hashes is not a heading we style.
    const s4 = try parse(testing.allocator, "#### Nope");
    defer testing.allocator.free(s4);
    try testing.expectEqual(@as(usize, 0), s4.len);
}

test "bold inline" {
    const spans = try parse(testing.allocator, "a **b** c");
    defer testing.allocator.free(spans);
    // markers around, bold content between
    try expectSpan(spans, 0, 2, 4, .marker); // "**"
    try expectSpan(spans, 1, 4, 5, .bold); // "b"
    try expectSpan(spans, 2, 5, 7, .marker); // "**"
}

test "italic underscore and star" {
    const a = try parse(testing.allocator, "_x_");
    defer testing.allocator.free(a);
    try expectSpan(a, 1, 1, 2, .italic);
    const b = try parse(testing.allocator, "*y*");
    defer testing.allocator.free(b);
    try expectSpan(b, 1, 1, 2, .italic);
}

test "inline code suppresses star inside" {
    const spans = try parse(testing.allocator, "`a*b*c`");
    defer testing.allocator.free(spans);
    // Only the code run; the inner '*'s are literal (no italic spans).
    try expectSpan(spans, 0, 0, 1, .marker);
    try expectSpan(spans, 1, 1, 6, .code);
    try expectSpan(spans, 2, 6, 7, .marker);
    try testing.expectEqual(@as(usize, 3), spans.len);
}

test "blockquote and list marker" {
    const q = try parse(testing.allocator, "> quote");
    defer testing.allocator.free(q);
    try expectSpan(q, 0, 0, 2, .marker); // "> "
    try expectSpan(q, 1, 2, 7, .quote);
    const l = try parse(testing.allocator, "- item");
    defer testing.allocator.free(l);
    try expectSpan(l, 0, 0, 2, .list_marker); // "- "
}

test "unmatched delimiter is literal" {
    const spans = try parse(testing.allocator, "a*b");
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 0), spans.len);
}

test "space-flanked stars are not italic (multiplication)" {
    const spans = try parse(testing.allocator, "5 * 6 * 7");
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 0), spans.len);
}

test "space-flanked stars are not bold" {
    const spans = try parse(testing.allocator, "5 ** 6 ** 7");
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 0), spans.len);
}

test "intraword underscores are not italic (identifier)" {
    const spans = try parse(testing.allocator, "my_var_name");
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 0), spans.len);
}

test "italic spans an internal space-flanked star" {
    // Opener flanks `a`, the inner `*` is space-flanked (not a closer), so the
    // run closes at the final `*` — content is "a * b" (CommonMark behavior).
    const spans = try parse(testing.allocator, "*a * b*");
    defer testing.allocator.free(spans);
    try expectSpan(spans, 0, 0, 1, .marker); // opening "*"
    try expectSpan(spans, 1, 1, 6, .italic); // "a * b"
    try expectSpan(spans, 2, 6, 7, .marker); // closing "*"
    try testing.expectEqual(@as(usize, 3), spans.len);
}

test "fenced code line left unstyled" {
    const spans = try parse(testing.allocator, "```zig");
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 0), spans.len);
}

test "multibyte offsets count codepoints" {
    // 'é' is one codepoint (2 bytes). The bold run must be offset in chars.
    const spans = try parse(testing.allocator, "é **x**");
    defer testing.allocator.free(spans);
    // "é" = col 0, " " = col 1, "**" = cols 2..4
    try expectSpan(spans, 0, 2, 4, .marker);
    try expectSpan(spans, 1, 4, 5, .bold);
    try expectSpan(spans, 2, 5, 7, .marker);
}

test "second line offset includes newline" {
    const spans = try parse(testing.allocator, "ab\n# H");
    defer testing.allocator.free(spans);
    // line 0 "ab" = 2 chars + newline => line 1 starts at char 3.
    try expectSpan(spans, 0, 3, 5, .marker); // "# "
    try expectSpan(spans, 1, 5, 6, .h1); // "H"
}
