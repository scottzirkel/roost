//! TerminalPane: the abstraction the rest of roost talks to instead of
//! reaching into Ghostty's `Surface` directly.
//!
//! WHY: We want to be able to swap the terminal backend later (e.g. a VTE
//! backend, or a mock for tests) without touching layout/app code. So the app
//! only ever depends on this interface, never on `Surface`. The concrete
//! `GhosttyTerminalPane` is the only place that knows about Ghostty internals.
//!
//! SHAPE: A tagged union (`union(enum)`). With exactly one backend today this
//! is the most idiomatic and lowest-overhead Zig choice: no manual vtable
//! plumbing, exhaustive `switch` keeps us honest when a second backend is
//! added, and the union value can live by-value inside the layout structs.

const std = @import("std");

const configpkg = @import("../config.zig");
const Surface = @import("../apprt/gtk/class/surface.zig").Surface;
const Application = @import("../apprt/gtk/class/application.zig").Application;
const CoreSurface = @import("../Surface.zig");
const apprt = @import("../apprt.zig");

const gtk = @import("gtk");
const gobject = @import("gobject");

const log = std.log.scoped(.roost_pane);

/// Options used to start a pane's process. Mirrors the subset of
/// `Surface.new` overrides we care about for Phase 2.
pub const StartOptions = struct {
    /// The command to run. `null` means "the user's default shell".
    command: ?configpkg.Command = null,
    /// Working directory to launch in. `null` inherits the default.
    cwd: ?[:0]const u8 = null,
    /// Reserved for a future env-override pass. Ghostty's Surface currently
    /// derives env from the app/config, so this is accepted but unused.
    env: ?*const std.process.EnvMap = null,
    /// Title hint for the underlying surface.
    title: ?[:0]const u8 = null,
};

/// The terminal pane interface. The app/layout code depends ONLY on this.
pub const TerminalPane = union(enum) {
    ghostty: GhosttyTerminalPane,

    /// Construct a Ghostty-backed pane and immediately start its process.
    /// In Phase 2 `start` is folded into construction because Ghostty's
    /// `Surface.new` takes the command override up front (the surface lazily
    /// spawns its child on realization). A future backend that supports
    /// deferred start can split these.
    pub fn initGhostty(opts: StartOptions) TerminalPane {
        return .{ .ghostty = GhosttyTerminalPane.create(opts) };
    }

    /// (Re)start is a no-op forwarder today: the command is bound at
    /// construction via `Surface.new`. Kept on the interface for symmetry and
    /// future backends.
    pub fn start(self: *TerminalPane, opts: StartOptions) void {
        switch (self.*) {
            inline else => |*b| b.start(opts),
        }
    }

    /// Move keyboard focus to this pane.
    pub fn focus(self: *TerminalPane) void {
        switch (self.*) {
            inline else => |*b| b.focus(),
        }
    }

    /// Resize hook. GTK drives surface resizes automatically via widget
    /// allocation, so this is a no-op forwarder for the Ghostty backend.
    pub fn resize(self: *TerminalPane) void {
        switch (self.*) {
            inline else => |*b| b.resize(),
        }
    }

    /// Copy the current selection to the clipboard (best-effort).
    pub fn copy(self: *TerminalPane) void {
        switch (self.*) {
            inline else => |*b| b.copy(),
        }
    }

    /// Paste clipboard contents into the pane (best-effort).
    pub fn paste(self: *TerminalPane) void {
        switch (self.*) {
            inline else => |*b| b.paste(),
        }
    }

    /// Inject text directly into the pane as if pasted (best-effort).
    pub fn sendText(self: *TerminalPane, bytes: [:0]const u8) void {
        switch (self.*) {
            inline else => |*b| b.sendText(bytes),
        }
    }

    /// Inject `bytes` into the pane's child as *typed* terminal input rather
    /// than a clipboard paste. The distinction matters for control bytes (e.g.
    /// 0x1F = Ctrl+_): `sendText`/`paste` go through bracketed paste, which the
    /// child app would either strip or treat as literal data, whereas this path
    /// writes the bytes straight to the PTY as if the user typed them. Used to
    /// remap a key to a control sequence the child understands. Best-effort.
    pub fn sendInput(self: *TerminalPane, bytes: []const u8) void {
        switch (self.*) {
            inline else => |*b| b.sendInput(bytes),
        }
    }

    /// Capture this pane's terminal text (full scrollback + screen) as an owned,
    /// NUL-terminated string, or null if unavailable. Caller frees with
    /// `alloc.free`. Used to snapshot an Agent pane into the scratchpad.
    pub fn captureText(self: *TerminalPane, alloc: std.mem.Allocator) ?[:0]const u8 {
        switch (self.*) {
            inline else => |*b| return b.captureText(alloc),
        }
    }

    /// Re-apply the application theme/config to this pane (best-effort).
    pub fn setTheme(self: *TerminalPane) void {
        switch (self.*) {
            inline else => |*b| b.setTheme(),
        }
    }

    /// Tear down the pane.
    pub fn destroy(self: *TerminalPane) void {
        switch (self.*) {
            inline else => |*b| b.destroy(),
        }
    }

    /// Whether this pane's child process is still running (the terminal hasn't
    /// observed the child exit). A surface that hasn't spawned its child yet
    /// reports false. Best-effort signal used to confirm before a destructive
    /// close would silently kill, e.g., a running agent.
    pub fn hasLiveProcess(self: *TerminalPane) bool {
        switch (self.*) {
            inline else => |*b| return b.hasLiveProcess(),
        }
    }

    /// Whether this pane is backed by `surface` — used to map a surface
    /// close-request back to the pane that should close.
    pub fn matchesSurface(self: *TerminalPane, surface: *Surface) bool {
        switch (self.*) {
            inline else => |*b| return b.matchesSurface(surface),
        }
    }

    /// The GtkWidget for this pane, to be parented into a container.
    pub fn widget(self: *TerminalPane) *gtk.Widget {
        switch (self.*) {
            inline else => |*b| return b.widget(),
        }
    }

    /// Connect a `close-request` handler. The backend forwards to whatever
    /// close affordance it exposes. `data` is passed through to the C callback.
    pub fn connectCloseRequest(
        self: *TerminalPane,
        comptime T: type,
        callback: *const fn (*Surface, T) callconv(.c) void,
        data: T,
    ) void {
        switch (self.*) {
            inline else => |*b| b.connectCloseRequest(T, callback, data),
        }
    }
};

/// Ghostty-backed implementation. This is the ONLY file in roost that touches
/// `Surface` / `CoreSurface`.
pub const GhosttyTerminalPane = struct {
    surface: *Surface,

    fn create(opts: StartOptions) GhosttyTerminalPane {
        const surface = Surface.new(.{
            .command = opts.command,
            .working_directory = opts.cwd,
            .title = opts.title,
        });
        return .{ .surface = surface };
    }

    fn start(self: *GhosttyTerminalPane, _: StartOptions) void {
        // No-op: the command was bound at construction. Ghostty spawns the
        // child process lazily when the surface is realized. See module doc.
        _ = self;
    }

    fn focus(self: *GhosttyTerminalPane) void {
        self.surface.grabFocus();
    }

    fn resize(self: *GhosttyTerminalPane) void {
        // GTK reallocates the surface widget on container resize and Ghostty
        // reacts to that internally, so there's nothing to forward here. We
        // nudge a redraw to be safe after large layout changes.
        self.surface.redraw();
    }

    fn copy(self: *GhosttyTerminalPane) void {
        // Best-effort: pull the active selection from the core surface and
        // write it to the standard clipboard. If there is no selection or the
        // surface isn't realized yet, this is a quiet no-op.
        const core = self.surface.core() orelse return;
        const alloc = Application.default().allocator();
        const sel = core.selectionString(alloc) catch |err| {
            log.warn("copy: selectionString failed err={}", .{err});
            return;
        } orelse return;
        defer alloc.free(sel);
        self.surface.setClipboard(
            .standard,
            &.{.{ .mime = "text/plain", .data = sel }},
            false,
        );
    }

    fn paste(self: *GhosttyTerminalPane) void {
        // Best-effort: request a standard-clipboard paste. This goes through
        // the same async clipboard read path the real terminal uses. The apprt
        // Surface exposes `clipboardRequest` which validates + dispatches.
        _ = self.surface.clipboardRequest(.standard, .{ .paste = {} }) catch |err| {
            log.warn("paste: clipboardRequest failed err={}", .{err});
        };
    }

    fn sendText(self: *GhosttyTerminalPane, bytes: [:0]const u8) void {
        if (bytes.len == 0) return;
        // Inject text as if it were pasted. `completeClipboardRequest(.paste,…)`
        // is the only public CoreSurface entrypoint that feeds bytes into the
        // PTY without going through a real clipboard read.
        const core = self.surface.core() orelse {
            log.warn("sendText: surface not realized yet, dropping {d} bytes", .{bytes.len});
            return;
        };
        core.completeClipboardRequest(.paste, bytes, true) catch |err| {
            log.warn("sendText: completeClipboardRequest failed err={}", .{err});
        };
    }

    fn sendInput(self: *GhosttyTerminalPane, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const core = self.surface.core() orelse {
            log.warn("sendInput: surface not realized yet, dropping {d} bytes", .{bytes.len});
            return;
        };
        // Nothing to type into a dead child (the pane auto-closes on exit, so
        // this is just defensive).
        if (core.child_exited) return;
        // The `.text` binding action parses Zig string escapes and writes the
        // result straight to the PTY (no bracketed paste). Our callers pass raw
        // control bytes, which contain no backslash, so they pass through
        // verbatim. This mirrors a `keybind = …=text:…` exactly.
        _ = core.performBindingAction(.{ .text = bytes }) catch |err| {
            log.warn("sendInput: performBindingAction failed err={}", .{err});
        };
    }

    /// Capture this pane's terminal text (full scrollback + screen) as an owned,
    /// NUL-terminated string. Mirrors Ghostty's own `dumpText` read path: take
    /// the renderer mutex, select all non-whitespace content, stringify it.
    /// Null if the surface isn't realized yet or the screen is empty. Caller
    /// frees with `alloc.free`.
    fn captureText(self: *GhosttyTerminalPane, alloc: std.mem.Allocator) ?[:0]const u8 {
        const core = self.surface.core() orelse return null;
        core.renderer_state.mutex.lock();
        defer core.renderer_state.mutex.unlock();
        const screen = core.io.terminal.screens.active; // *Screen
        const sel = screen.selectAll() orelse return null; // empty screen
        return screen.selectionString(alloc, .{ .sel = sel, .trim = true }) catch return null;
    }

    fn setTheme(self: *GhosttyTerminalPane) void {
        // Best-effort: re-apply the application's current config to the
        // surface, which causes it to re-pull theme/colors. We don't have a
        // dedicated per-pane theme API in Phase 2.
        const config = Application.default().getConfig();
        defer config.unref();
        self.surface.setConfig(config);
    }

    fn destroy(self: *GhosttyTerminalPane) void {
        // Ask the surface to close. It owns its own teardown (renderer/IO
        // threads) in response to this.
        self.surface.close();
    }

    fn hasLiveProcess(self: *GhosttyTerminalPane) bool {
        // The core surface exists once the child has spawned; `child_exited`
        // flips true when that child dies (the moment Ghostty shows its
        // "process exited" overlay). No core yet => nothing running to lose.
        const core = self.surface.core() orelse return false;
        return !core.child_exited;
    }

    fn matchesSurface(self: *GhosttyTerminalPane, surface: *Surface) bool {
        return self.surface == surface;
    }

    fn widget(self: *GhosttyTerminalPane) *gtk.Widget {
        return self.surface.as(gtk.Widget);
    }

    fn connectCloseRequest(
        self: *GhosttyTerminalPane,
        comptime T: type,
        callback: *const fn (*Surface, T) callconv(.c) void,
        data: T,
    ) void {
        _ = Surface.signals.@"close-request".connect(
            self.surface,
            T,
            callback,
            data,
            .{},
        );
    }
};
