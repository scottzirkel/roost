//! Entry point for "Roost": a role-aware 4-pane workspace built on top of
//! real Ghostty terminal Surfaces embedded in our own GTK window.
//!
//! This file is intentionally thin. All of roost's logic lives under
//! `src/roost/` (ADDITIVE — our code, no edits to existing Ghostty source):
//!
//!   - roost/app.zig            boot sequence + custom GLib main loop + window
//!   - roost/layout.zig         the role-typed 4-pane Workspace
//!   - roost/terminal_pane.zig  the TerminalPane abstraction + Ghostty backend
//!   - roost/scratchpad_pane.zig a plain editable GtkTextView pane
//!
//! It lives in `src/` (like `src/main_ghostty.zig`) so it can relative-`@import`
//! Ghostty internals, including the GTK apprt classes.

const std = @import("std");
const builtin = @import("builtin");

const app = @import("roost/app.zig");

pub fn main() !void {
    try app.run();
}

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
};
