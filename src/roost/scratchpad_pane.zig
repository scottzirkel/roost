//! ScratchpadPane: a "dumb", non-terminal pane backed by a plain editable
//! GtkTextView inside a GtkScrolledWindow.
//!
//! Its purpose in Phase 2 is to prove the role-typed layout can hold a
//! non-terminal widget alongside real Ghostty surfaces. Markdown live-preview
//! and friends are a later phase; for now it's just a working text area.

const std = @import("std");

const gtk = @import("gtk");
const glib = @import("glib");

pub const ScratchpadPane = struct {
    scrolled: *gtk.ScrolledWindow,
    text_view: *gtk.TextView,

    pub fn init() ScratchpadPane {
        const text_view = gtk.TextView.new();
        text_view.setEditable(1);
        text_view.setMonospace(1);
        text_view.setWrapMode(.word_char);
        // A little breathing room around the text.
        text_view.setLeftMargin(8);
        text_view.setRightMargin(8);
        text_view.setTopMargin(8);
        text_view.setBottomMargin(8);

        // Seed with a hint so the empty pane isn't a blank void in the demo.
        const buffer = text_view.getBuffer();
        const hint = "Scratchpad\n\nA plain editable notes area. Type anything here.\n";
        buffer.setText(hint, @intCast(hint.len));

        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setPolicy(.automatic, .automatic);
        scrolled.setChild(text_view.as(gtk.Widget));
        scrolled.as(gtk.Widget).setVexpand(1);
        scrolled.as(gtk.Widget).setHexpand(1);

        return .{ .scrolled = scrolled, .text_view = text_view };
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
    /// current line is itself empty).
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
