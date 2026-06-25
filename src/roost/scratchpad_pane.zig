//! ScratchpadPane: a "dumb", non-terminal pane backed by a plain editable
//! GtkTextView inside a GtkScrolledWindow.
//!
//! It holds project notes and (when given a path) PERSISTS them: the contents
//! are loaded on open and autosaved — debounced — as you type. The default file
//! is per-project (`<project>/.roost/scratchpad.md`, resolved by the caller);
//! the `.roost` dir gets a self-ignoring `.gitignore` so it never pollutes git.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gtk = @import("gtk");
const glib = @import("glib");

const log = std.log.scoped(.roost_scratch);

/// Coalesce a burst of keystrokes into one write this many ms after the first
/// unsaved change.
const autosave_debounce_ms = 1000;

pub const ScratchpadPane = struct {
    alloc: Allocator,
    scrolled: *gtk.ScrolledWindow,
    text_view: *gtk.TextView,
    /// Owned persistence path; null disables load/save (e.g. no project).
    path: ?[]u8,
    autosave: bool,
    /// Pending debounced-save GLib source id (0 = none scheduled).
    save_source: c_uint = 0,

    /// Build the pane. If `path` is non-null and the file exists, its contents
    /// seed the buffer. Autosave is wired separately by `wire` (after the pane
    /// reaches its final address), so loading here never triggers a save.
    pub fn init(alloc: Allocator, path: ?[]const u8, autosave: bool) ScratchpadPane {
        const text_view = gtk.TextView.new();
        text_view.setEditable(1);
        text_view.setMonospace(1);
        text_view.setWrapMode(.word_char);
        text_view.setLeftMargin(8);
        text_view.setRightMargin(8);
        text_view.setTopMargin(8);
        text_view.setBottomMargin(8);

        const owned_path: ?[]u8 = if (path) |p| (alloc.dupe(u8, p) catch null) else null;

        // Load existing contents (if any) before anything is connected.
        if (owned_path) |p| loadInto(alloc, text_view.getBuffer(), p);

        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setPolicy(.automatic, .automatic);
        scrolled.setChild(text_view.as(gtk.Widget));
        scrolled.as(gtk.Widget).setVexpand(1);
        scrolled.as(gtk.Widget).setHexpand(1);

        return .{
            .alloc = alloc,
            .scrolled = scrolled,
            .text_view = text_view,
            .path = owned_path,
            .autosave = autosave,
        };
    }

    /// Connect the autosave handler. MUST be called only once the pane sits at
    /// its final address (it is moved into its Node), so the buffer's `changed`
    /// user-data points at the stable ScratchpadPane. No-op without a path or
    /// when autosave is off.
    pub fn wire(self: *ScratchpadPane) void {
        if (self.path == null or !self.autosave) return;
        _ = gtk.TextBuffer.signals.changed.connect(
            self.text_view.getBuffer(),
            *ScratchpadPane,
            onChanged,
            self,
            .{},
        );
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
        if (self.path) |p| self.alloc.free(p);
        self.* = undefined;
    }

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
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = text });
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
