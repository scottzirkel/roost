//! ScratchpadPane: a non-terminal pane backed by an editable GtkTextView inside
//! a GtkScrolledWindow, with **Typora-style live markdown styling**.
//!
//! It holds project notes and (when given a path) PERSISTS them: contents are
//! loaded on open and autosaved — debounced — as you type. The default file is
//! per-project (`<project>/.roost/scratchpad.md`, resolved by the caller).
//!
//! Live styling: the SAME editable view is restyled on every edit and cursor
//! move (`md.zig` parses the text into spans; we map each to a GtkTextTag).
//! Markdown markers (`#`, `**`, backticks, `> `) are HIDDEN via an `invisible`
//! tag on every line EXCEPT the one the cursor sits in, which reveals them
//! (dimmed) so they stay editable — Typora's "source on the active block". We
//! only ever apply/remove tags; the buffer text is never mutated, so autosave
//! and `copyTextToSend` always see the raw markdown. Tag colors are derived from
//! the live GTK theme — the foreground (`getColor`) for dim/quote text and the
//! named accent color (`themeAccent`, Catppuccin's accent on Omarchy) for
//! headings and inline code — so they follow the system theme; the base font
//! comes from a `.roost-scratchpad` CSS class (see app.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;

const gtk = @import("gtk");
const glib = @import("glib");
const gobject = @import("gobject");
const gdk = @import("gdk");

const md = @import("md.zig");

const log = std.log.scoped(.roost_scratch);

/// Coalesce a burst of keystrokes into one write this many ms after the first
/// unsaved change.
const autosave_debounce_ms = 1000;

/// PANGO_STYLE_ITALIC. We can't `@import("pango")` (it isn't a wired build
/// module — only adw/gdk/gio/glib/gobject/gtk/xlib are), so for the one enum
/// property we need (`style`) we fetch its GType via Pango's C registration
/// function and build the GValue by hand.
const PANGO_STYLE_ITALIC: c_int = 2;
extern fn pango_style_get_type() usize;

/// Reusable GtkTextTags applied during `restyle`. Created once per buffer
/// (anonymous; we apply them by pointer). The buffer owns them — they die with
/// the text view. The color-bearing ones (`code`/`quote`/`marker_dim`) have
/// their `*-rgba` refreshed each restyle so they track the live theme.
const Tags = struct {
    h1: *gtk.TextTag,
    h2: *gtk.TextTag,
    h3: *gtk.TextTag,
    bold: *gtk.TextTag,
    italic: *gtk.TextTag,
    code: *gtk.TextTag,
    quote: *gtk.TextTag,
    /// invisible=true — hides markers off the cursor line.
    hidden: *gtk.TextTag,
    /// Dim foreground — revealed markers (on the cursor line) and list bullets.
    marker_dim: *gtk.TextTag,
};

pub const ScratchpadPane = struct {
    alloc: Allocator,
    scrolled: *gtk.ScrolledWindow,
    text_view: *gtk.TextView,
    tags: Tags,
    /// Owned persistence path; null disables load/save (e.g. no project).
    path: ?[]u8,
    autosave: bool,
    /// Pending debounced-save GLib source id (0 = none scheduled).
    save_source: c_uint = 0,
    /// Cursor line last styled for; lets `mark-set` skip restyles that don't
    /// change which line reveals its markers. -1 = not yet styled.
    styled_line: c_int = -1,

    /// Build the pane. If `path` is non-null and the file exists, its contents
    /// seed the buffer. Signals (autosave + live styling) are wired separately by
    /// `wire` (after the pane reaches its final address), so loading here never
    /// triggers a save or a stale-pointer callback.
    pub fn init(alloc: Allocator, path: ?[]const u8, autosave: bool) ScratchpadPane {
        const text_view = gtk.TextView.new();
        text_view.setEditable(1);
        text_view.setWrapMode(.word_char);
        // Generous internal padding so the notes editor feels like a document,
        // not a cramped terminal.
        text_view.setLeftMargin(18);
        text_view.setRightMargin(18);
        text_view.setTopMargin(16);
        text_view.setBottomMargin(16);
        // Breathing room between lines (and between wrapped rows of one line).
        text_view.setPixelsAboveLines(3);
        text_view.setPixelsBelowLines(3);
        text_view.setPixelsInsideWrap(2);
        // Base font comes from CSS (`.roost-scratchpad`, built from config in
        // app.zig); the default there is monospace, so we drop setMonospace.
        text_view.as(gtk.Widget).addCssClass("roost-scratchpad");

        const buffer = text_view.getBuffer();
        const tags = buildTags(buffer);

        const owned_path: ?[]u8 = if (path) |p| (alloc.dupe(u8, p) catch null) else null;

        // Load existing contents (if any) before anything is connected.
        if (owned_path) |p| loadInto(alloc, buffer, p);

        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setPolicy(.automatic, .automatic);
        scrolled.setChild(text_view.as(gtk.Widget));
        scrolled.as(gtk.Widget).setVexpand(1);
        scrolled.as(gtk.Widget).setHexpand(1);

        // Hold our own ref on the view so `destroy`'s final `saveNow` can still
        // read the buffer: teardown (closeNode/rebuild/window-close) finalizes
        // the widget tree BEFORE Pane.destroy runs, which would otherwise free
        // the buffer out from under that flush. Released in `destroy`.
        _ = text_view.as(gobject.Object).ref();

        return .{
            .alloc = alloc,
            .scrolled = scrolled,
            .text_view = text_view,
            .tags = tags,
            .path = owned_path,
            .autosave = autosave,
        };
    }

    /// Connect signals. MUST be called only once the pane sits at its final
    /// address (it is moved into its Node), so callback user-data points at the
    /// stable ScratchpadPane. Wires live styling (always) + debounced autosave
    /// (only with a path and autosave on), then does an initial styling pass.
    pub fn wire(self: *ScratchpadPane) void {
        const buffer = self.text_view.getBuffer();
        // Live styling: re-render on edits and on cursor movement.
        _ = gtk.TextBuffer.signals.changed.connect(buffer, *ScratchpadPane, onChangedRestyle, self, .{});
        _ = gtk.TextBuffer.signals.mark_set.connect(buffer, *ScratchpadPane, onMarkSet, self, .{});
        // Re-style once realized: `getColor` only yields the real theme color
        // after the widget is in a display, so the loaded text gets correct
        // marker/code colors then.
        _ = gtk.Widget.signals.realize.connect(self.text_view.as(gtk.Widget), *ScratchpadPane, onRealize, self, .{});
        // Debounced autosave, only when persisting.
        if (self.path != null and self.autosave) {
            _ = gtk.TextBuffer.signals.changed.connect(buffer, *ScratchpadPane, onChanged, self, .{});
        }
        // Initial pass so the loaded content shows styled immediately (colors are
        // refined on realize).
        self.restyle();
    }

    /// Flush any pending change and release resources. Called from `Pane.destroy`
    /// (pane close, layout reset, project switch, clean exit) so the last edits
    /// in the debounce window are never lost.
    pub fn destroy(self: *ScratchpadPane) void {
        if (self.save_source != 0) {
            _ = glib.Source.remove(self.save_source);
            self.save_source = 0;
            self.saveNow();
        }
        // Release the keepalive ref taken in `init` (after the final saveNow has
        // read the buffer), letting the view + buffer finalize.
        self.text_view.as(gobject.Object).unref();
        if (self.path) |p| self.alloc.free(p);
        self.* = undefined;
    }

    /// Append `bytes` to the end of the buffer (the wired-actions "→ scratchpad"
    /// route). A separator newline goes first when the buffer is non-empty so
    /// routed output starts on its own line. Inserting emits `changed`, so live
    /// styling + debounced autosave run automatically (no manual call needed).
    pub fn appendText(self: *ScratchpadPane, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const buffer = self.text_view.getBuffer();

        var end: gtk.TextIter = undefined;
        buffer.getEndIter(&end);
        if (buffer.getCharCount() > 0) {
            buffer.insert(&end, "\n", 1);
            buffer.getEndIter(&end); // the prior insert invalidated `end`
        }

        const z = self.alloc.dupeZ(u8, bytes) catch return;
        defer self.alloc.free(z);
        buffer.insert(&end, z.ptr, @intCast(bytes.len));

        // Keep the freshly-appended text in view.
        buffer.getEndIter(&end);
        _ = self.text_view.scrollToIter(&end, 0.0, 0, 0.0, 0.0);
    }

    // --- live styling -----------------------------------------------------

    /// Re-derive and re-apply all markdown styling over the whole buffer. Cheap
    /// for a notes-sized document; runs on every edit and on cursor-line change.
    /// Applying/removing tags does not emit `changed`/`mark-set`, so this never
    /// re-enters.
    fn restyle(self: *ScratchpadPane) void {
        const buffer = self.text_view.getBuffer();

        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        buffer.getBounds(&start, &end);
        buffer.removeAllTags(&start, &end);

        // include_hidden_chars=1 is REQUIRED: markers currently under the
        // `invisible` tag are otherwise omitted, which would corrupt the parse.
        const c_text = buffer.getText(&start, &end, 1);
        defer glib.free(c_text);
        const text = std.mem.span(c_text);

        // The cursor's line reveals its markers; everything else hides them.
        var cur: gtk.TextIter = undefined;
        buffer.getIterAtMark(&cur, buffer.getInsert());
        const cursor_line = cur.getLine();
        self.styled_line = cursor_line;

        // Refresh theme-derived colors so a light/dark switch is picked up.
        var fg: gdk.RGBA = undefined;
        self.text_view.as(gtk.Widget).getColor(&fg);
        // The active GTK/libadwaita theme's accent color (Catppuccin's accent on
        // Omarchy) — used to tint headings and inline code so the scratchpad
        // tracks the system theme. Falls back to the plain foreground when the
        // theme exposes no named accent (so headings still render, just uncolored).
        var accent = themeAccent(self.text_view.as(gtk.Widget), fg);
        var dim = fg;
        dim.f_alpha = 0.40;
        var quote_fg = fg;
        quote_fg.f_alpha = 0.65;
        // Inline code gets a faint accent-tinted background (vs. a flat grey).
        var code_bg = accent;
        code_bg.f_alpha = 0.13;
        setRgba(self.tags.h1, "foreground-rgba", &accent);
        setRgba(self.tags.h2, "foreground-rgba", &accent);
        setRgba(self.tags.h3, "foreground-rgba", &accent);
        setRgba(self.tags.marker_dim, "foreground-rgba", &dim);
        setRgba(self.tags.quote, "foreground-rgba", &quote_fg);
        setRgba(self.tags.code, "background-rgba", &code_bg);

        const spans = md.parse(self.alloc, text) catch return;
        defer self.alloc.free(spans);

        for (spans) |sp| {
            var a: gtk.TextIter = undefined;
            var b: gtk.TextIter = undefined;
            buffer.getIterAtOffset(&a, @intCast(sp.start));
            buffer.getIterAtOffset(&b, @intCast(sp.end));
            const tag: *gtk.TextTag = switch (sp.kind) {
                .h1 => self.tags.h1,
                .h2 => self.tags.h2,
                .h3 => self.tags.h3,
                .bold => self.tags.bold,
                .italic => self.tags.italic,
                .code => self.tags.code,
                .quote => self.tags.quote,
                // List bullets stay visible but dimmed (never hidden).
                .list_marker => self.tags.marker_dim,
                // Syntax markers: revealed (dim) on the cursor line, hidden off it.
                .marker => if (a.getLine() == cursor_line) self.tags.marker_dim else self.tags.hidden,
            };
            buffer.applyTag(tag, &a, &b);
        }
    }

    fn onChangedRestyle(_: *gtk.TextBuffer, self: *ScratchpadPane) callconv(.c) void {
        self.restyle();
    }

    fn onMarkSet(_: *gtk.TextBuffer, _: *gtk.TextIter, mark: *gtk.TextMark, self: *ScratchpadPane) callconv(.c) void {
        const buffer = self.text_view.getBuffer();
        if (mark != buffer.getInsert()) return; // ignore selection-bound moves
        var cur: gtk.TextIter = undefined;
        buffer.getIterAtMark(&cur, mark);
        if (cur.getLine() == self.styled_line) return; // same line: nothing reveals/hides
        self.restyle();
    }

    fn onRealize(_: *gtk.Widget, self: *ScratchpadPane) callconv(.c) void {
        self.restyle();
    }

    // --- autosave ---------------------------------------------------------

    fn onChanged(_: *gtk.TextBuffer, self: *ScratchpadPane) callconv(.c) void {
        // Debounce: schedule one save per burst; ignore changes while pending.
        if (self.save_source != 0) return;
        self.save_source = glib.timeoutAdd(autosave_debounce_ms, onSaveTimer, self);
    }

    fn onSaveTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *ScratchpadPane = @ptrCast(@alignCast(data.?));
        self.save_source = 0;
        self.saveNow();
        return 0; // G_SOURCE_REMOVE — one-shot.
    }

    fn saveNow(self: *ScratchpadPane) void {
        const path = self.path orelse return;
        const buffer = self.text_view.getBuffer();
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        buffer.getBounds(&start, &end);
        const c_text = buffer.getText(&start, &end, 1);
        defer glib.free(c_text);
        writeScratch(self.alloc, path, std.mem.span(c_text)) catch |err|
            log.warn("scratchpad save failed '{s}' err={}", .{ path, err });
    }

    /// The GtkWidget to parent into a container.
    pub fn widget(self: *ScratchpadPane) *gtk.Widget {
        return self.scrolled.as(gtk.Widget);
    }

    /// Move keyboard focus into the text view.
    pub fn focus(self: *ScratchpadPane) void {
        _ = self.text_view.as(gtk.Widget).grabFocus();
    }

    /// Extract the text the user wants to "send": the current SELECTION if the
    /// buffer has one, otherwise the CURRENT LINE (the line the cursor sits on,
    /// from line start to line end, NOT including the trailing newline).
    ///
    /// Returns a glib-allocated, NUL-terminated C string suitable for
    /// `TerminalPane.sendText` ([:0]const u8). The caller OWNS it and must free
    /// it with `glib.free`. Returns null if there's nothing to send (empty
    /// selection collapses to the current-line path, so null only happens if the
    /// current line is itself empty). Always the RAW markdown — styling never
    /// changes the underlying characters.
    pub fn copyTextToSend(self: *ScratchpadPane) ?[:0]u8 {
        const buffer = self.text_view.getBuffer();

        // GtkTextIter is a by-value struct used as an out-param: we hand the
        // buffer pointers to undefined locals for it to fill in.
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;

        if (buffer.getSelectionBounds(&start, &end) != 0) {
            // There's a real (non-empty) selection: send exactly that.
            return spanOrNull(buffer.getText(&start, &end, 1));
        }

        // No selection: send the current line. Find the cursor (the "insert"
        // mark), then build [line-start, line-end] around it.
        const insert = buffer.getInsert();
        var cursor: gtk.TextIter = undefined;
        buffer.getIterAtMark(&cursor, insert);

        // Line start: copy the cursor iter (extern struct -> value copy) and
        // snap to the first char of its line.
        start = cursor;
        start.setLineOffset(0);

        // Line end: copy the cursor iter and walk to the end of the line. If the
        // cursor is already at line end, forwardToLineEnd leaves it put.
        end = cursor;
        _ = end.forwardToLineEnd();

        return spanOrNull(buffer.getText(&start, &end, 1));
    }
};

/// Resolve the active theme's accent color from `widget`'s style context,
/// returning `fallback` (the plain foreground) when the theme defines none. Tries
/// the libadwaita standalone accent first (meant for text on the window
/// background — ideal for headings), then the bg/legacy names. `getStyleContext`
/// is deprecated in GTK4 but is still the only way to resolve a named theme color
/// for an arbitrary widget.
fn themeAccent(widget: *gtk.Widget, fallback: gdk.RGBA) gdk.RGBA {
    const ctx = widget.getStyleContext();
    const names = [_][*:0]const u8{ "accent_color", "accent_bg_color", "theme_selected_bg_color" };
    for (names) |name| {
        var rgba: gdk.RGBA = undefined;
        if (ctx.lookupColor(name, &rgba) != 0) return rgba;
    }
    return fallback;
}

/// Create the reusable styling tags on `buffer`'s tag table. Anonymous (we apply
/// by pointer). Color-bearing tags get their `*-rgba` set per restyle.
fn buildTags(buffer: *gtk.TextBuffer) Tags {
    const h1 = anonTag(buffer);
    setF64(h1, "scale", 1.6);
    setI32(h1, "weight", 700);
    const h2 = anonTag(buffer);
    setF64(h2, "scale", 1.4);
    setI32(h2, "weight", 700);
    const h3 = anonTag(buffer);
    setF64(h3, "scale", 1.2);
    setI32(h3, "weight", 700);

    const bold = anonTag(buffer);
    setI32(bold, "weight", 700);

    const italic = anonTag(buffer);
    setItalic(italic);

    const code = anonTag(buffer);
    setStr(code, "family", "monospace");

    const quote = anonTag(buffer);
    setI32(quote, "left-margin", 18);

    const hidden = anonTag(buffer);
    setBool(hidden, "invisible", true);

    const marker_dim = anonTag(buffer);

    return .{
        .h1 = h1,
        .h2 = h2,
        .h3 = h3,
        .bold = bold,
        .italic = italic,
        .code = code,
        .quote = quote,
        .hidden = hidden,
        .marker_dim = marker_dim,
    };
}

fn anonTag(buffer: *gtk.TextBuffer) *gtk.TextTag {
    return buffer.createTag(null, null);
}

fn setBool(tag: *gtk.TextTag, name: [*:0]const u8, v: bool) void {
    var val = gobject.ext.Value.newFrom(v);
    defer val.unset();
    tag.as(gobject.Object).setProperty(name, &val);
}

fn setI32(tag: *gtk.TextTag, name: [*:0]const u8, v: c_int) void {
    var val = gobject.ext.Value.newFrom(v);
    defer val.unset();
    tag.as(gobject.Object).setProperty(name, &val);
}

fn setF64(tag: *gtk.TextTag, name: [*:0]const u8, v: f64) void {
    var val = gobject.ext.Value.newFrom(v);
    defer val.unset();
    tag.as(gobject.Object).setProperty(name, &val);
}

fn setStr(tag: *gtk.TextTag, name: [*:0]const u8, v: [*:0]const u8) void {
    var val = gobject.ext.Value.newFrom(v);
    defer val.unset();
    tag.as(gobject.Object).setProperty(name, &val);
}

fn setRgba(tag: *gtk.TextTag, name: [*:0]const u8, v: *gdk.RGBA) void {
    var val = gobject.ext.Value.newFrom(v);
    defer val.unset();
    tag.as(gobject.Object).setProperty(name, &val);
}

/// Set the `style` property to PANGO_STYLE_ITALIC via a hand-built GValue (the
/// enum's GType comes from `pango_style_get_type` since pango isn't importable).
fn setItalic(tag: *gtk.TextTag) void {
    var val: gobject.Value = std.mem.zeroes(gobject.Value);
    _ = val.init(pango_style_get_type());
    val.setEnum(PANGO_STYLE_ITALIC);
    defer val.unset();
    tag.as(gobject.Object).setProperty("style", &val);
}

/// Read `path` into `buffer` if it exists. Missing file => leave the buffer
/// empty. Best-effort: logs and returns on any other error.
fn loadInto(alloc: Allocator, buffer: *gtk.TextBuffer, path: []const u8) void {
    const bytes = std.fs.cwd().readFileAllocOptions(alloc, path, 8 * 1024 * 1024, null, .of(u8), 0) catch |err| {
        if (err != error.FileNotFound) log.warn("could not read scratchpad '{s}' err={}", .{ path, err });
        return;
    };
    defer alloc.free(bytes);
    buffer.setText(bytes.ptr, @intCast(bytes.len));
}

/// Write `text` to `path`, creating the parent dir. When that dir is named
/// `.roost`, drop a self-ignoring `.gitignore` (`*`) so the scratchpad (and
/// anything else Roost stows there) never shows up in the project's git status.
fn writeScratch(alloc: Allocator, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        if (std.mem.eql(u8, std.fs.path.basename(dir), ".roost")) ensureSelfIgnore(alloc, dir);
    }
    // Write atomically: a torn write (crash / power loss / ENOSPC) must not
    // destroy the user's prior notes. Write a sibling temp, then rename(2) over
    // the target so readers only ever see a complete file.
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp);
    errdefer std.fs.cwd().deleteFile(tmp) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = text });
    try std.fs.cwd().rename(tmp, path);
}

/// Ensure `<dir>/.gitignore` exists containing `*` (so the dir ignores its own
/// contents). Only writes when absent — never clobbers a user's edits.
fn ensureSelfIgnore(alloc: Allocator, dir: []const u8) void {
    const gi = std.fs.path.join(alloc, &.{ dir, ".gitignore" }) catch return;
    defer alloc.free(gi);
    std.fs.cwd().access(gi, .{}) catch {
        std.fs.cwd().writeFile(.{ .sub_path = gi, .data = "*\n" }) catch {};
    };
}

/// Turn the glib C string returned by `getText` into an owned `[:0]u8`, or null
/// if it's empty (nothing meaningful to send). Empty strings are still freed.
fn spanOrNull(c_str: [*:0]u8) ?[:0]u8 {
    const slice = std.mem.span(c_str);
    if (slice.len == 0) {
        glib.free(c_str);
        return null;
    }
    return slice;
}
