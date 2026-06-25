//! Roost user configuration — a tiny `key = value` text file at
//! `<xdg-config>/roost/config`.
//!
//! ADDITIVE and entirely our own. This is NOT Ghostty's config (the embedded
//! Surfaces still read `~/.config/ghostty/config` for terminal/font/theme); it
//! holds only Roost-level UI settings. One flat namespace, `#` line comments,
//! whitespace-insensitive around `=`, booleans accept true/false/1/0/yes/no/
//! on/off. Unknown keys are warned-and-ignored so an older binary tolerates a
//! newer file. The settings UI (`app.zig`) reads/writes this same file via
//! `load`/`save`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.roost_config);

pub const Config = struct {
    alloc: Allocator,

    /// The agent program the Agent pane runs (default `claude`). `$ROOST_AGENT`
    /// still overrides this at launch. Owned, NUL-terminated (resolved at load).
    agent: [:0]const u8 = "claude",
    /// Focus a pane when the pointer enters it (Hyprland-style). Default on;
    /// the Ctrl+Shift+M toggle / header button / Settings switch all persist here.
    focus_follows_mouse: bool = true,
    /// Play a sound on agent events (done / needs-input). Default off so a fresh
    /// install is quiet; pairs with the silent `gio.Notification` in `ipc.zig`.
    audio_notifications: bool = false,
    /// Persist the scratchpad pane's contents to its file (load on open, autosave
    /// on edit). Default on.
    scratchpad_autosave: bool = true,
    /// Optional explicit scratchpad file path (owned). When null the path is
    /// per-project: `<project>/.roost/scratchpad.md` (see `scratchpadPathFor`).
    /// Set this to share one scratchpad across all projects instead.
    scratchpad_override: ?[]const u8 = null,

    /// Load the config, applying file overrides on top of the defaults. Never
    /// fails: a missing/unreadable file yields the defaults. The returned Config
    /// owns its heap strings and must be `deinit`'d.
    pub fn load(alloc: Allocator) Config {
        var cfg: Config = .{
            .alloc = alloc,
            .agent = alloc.dupeZ(u8, "claude") catch "claude",
        };

        const path = configPath(alloc) catch return cfg;
        defer alloc.free(path);
        const bytes = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch |err| {
            if (err != error.FileNotFound) log.warn("could not read config '{s}' err={}", .{ path, err });
            return cfg;
        };
        defer alloc.free(bytes);

        cfg.parse(bytes);
        log.info("config: agent='{s}' focus_follows_mouse={} audio_notifications={} scratchpad_autosave={} scratchpad_override='{s}'", .{
            cfg.agent, cfg.focus_follows_mouse, cfg.audio_notifications, cfg.scratchpad_autosave, cfg.scratchpad_override orelse "(per-project)",
        });
        return cfg;
    }

    pub fn deinit(self: *Config) void {
        self.alloc.free(self.agent);
        if (self.scratchpad_override) |o| self.alloc.free(o);
        self.* = undefined;
    }

    /// The effective scratchpad file for `project_path`: the explicit
    /// `scratchpad_override` if set, else `<project>/.roost/scratchpad.md`. Returns
    /// null (no persistence) when there is no override AND no project. Caller owns
    /// the result.
    pub fn scratchpadPathFor(self: *const Config, alloc: Allocator, project_path: []const u8) ?[]u8 {
        if (self.scratchpad_override) |o| return alloc.dupe(u8, o) catch null;
        if (project_path.len == 0) return null;
        return std.fs.path.join(alloc, &.{ project_path, ".roost", "scratchpad.md" }) catch null;
    }

    /// Replace `agent` with an owned NUL-terminated copy of `new_agent`, freeing
    /// the previous value. No-op on empty input or OOM. Used by the settings UI.
    pub fn setAgent(self: *Config, new_agent: []const u8) void {
        const trimmed = std.mem.trim(u8, new_agent, " \t");
        if (trimmed.len == 0) return;
        const dup = self.alloc.dupeZ(u8, trimmed) catch return;
        self.alloc.free(self.agent);
        self.agent = dup;
    }

    /// Set (or clear) the explicit scratchpad override. An empty value clears it
    /// → back to the per-project default. A non-empty value is stored resolved
    /// (`~` + relative expanded). Frees any previous override. Used by the
    /// settings UI before `save`.
    pub fn setScratchpadPath(self: *Config, new_path: []const u8) void {
        const trimmed = std.mem.trim(u8, new_path, " \t");
        if (trimmed.len == 0) {
            if (self.scratchpad_override) |o| self.alloc.free(o);
            self.scratchpad_override = null;
            return;
        }
        const resolved = resolvePath(self.alloc, trimmed) orelse return;
        if (self.scratchpad_override) |o| self.alloc.free(o);
        self.scratchpad_override = resolved;
    }

    fn parse(self: *Config, bytes: []const u8) void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                log.warn("ignoring malformed config line '{s}'", .{line});
                continue;
            };
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            self.setKV(key, val);
        }
    }

    fn setKV(self: *Config, key: []const u8, val: []const u8) void {
        if (std.mem.eql(u8, key, "agent")) {
            self.setAgent(val);
        } else if (std.mem.eql(u8, key, "focus-follows-mouse")) {
            self.focus_follows_mouse = parseBool(val) orelse self.focus_follows_mouse;
        } else if (std.mem.eql(u8, key, "audio-notifications")) {
            self.audio_notifications = parseBool(val) orelse self.audio_notifications;
        } else if (std.mem.eql(u8, key, "scratchpad-autosave")) {
            self.scratchpad_autosave = parseBool(val) orelse self.scratchpad_autosave;
        } else if (std.mem.eql(u8, key, "scratchpad-path")) {
            self.setScratchpadPath(val);
        } else {
            log.warn("unknown config key '{s}'", .{key});
        }
    }

    /// Serialize the current values to the config file (creating the dir). Best-
    /// effort: logs and returns on error so a failed save never crashes the UI.
    pub fn save(self: *const Config) void {
        self.saveImpl() catch |err| log.warn("could not save config err={}", .{err});
    }

    fn saveImpl(self: *const Config) !void {
        const path = try configPath(self.alloc);
        defer self.alloc.free(path);
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);
        try w.writeAll("# Roost configuration (key = value). Edit here or via Settings.\n\n");
        try w.print("agent = {s}\n", .{self.agent});
        try w.print("focus-follows-mouse = {s}\n", .{boolStr(self.focus_follows_mouse)});
        try w.print("audio-notifications = {s}\n", .{boolStr(self.audio_notifications)});
        try w.print("scratchpad-autosave = {s}\n", .{boolStr(self.scratchpad_autosave)});
        // Empty = per-project default (<project>/.roost/scratchpad.md).
        try w.print("scratchpad-path = {s}\n", .{self.scratchpad_override orelse ""});

        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = buf.items });
        log.info("saved config ({d} bytes)", .{buf.items.len});
    }
};

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// Parse a boolean from the common spellings; null if unrecognized (caller
/// keeps the existing value).
fn parseBool(v: []const u8) ?bool {
    const t = [_][]const u8{ "true", "1", "yes", "on" };
    const f = [_][]const u8{ "false", "0", "no", "off" };
    for (t) |s| if (std.ascii.eqlIgnoreCase(v, s)) return true;
    for (f) |s| if (std.ascii.eqlIgnoreCase(v, s)) return false;
    return null;
}

/// Resolve a user-supplied path to an owned absolute path: expand a leading
/// `~/` to $HOME, leave already-absolute paths as-is, and make relative paths
/// absolute against the cwd. Returns null on OOM.
fn resolvePath(alloc: Allocator, path: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = std.posix.getenv("HOME") orelse return alloc.dupe(u8, path) catch null;
        return std.fs.path.join(alloc, &.{ home, path[2..] }) catch null;
    }
    if (std.fs.path.isAbsolute(path)) return alloc.dupe(u8, path) catch null;
    // Relative: make absolute against the cwd (fall back to the raw path).
    const cwd = std.fs.cwd().realpathAlloc(alloc, ".") catch return alloc.dupe(u8, path) catch null;
    defer alloc.free(cwd);
    return std.fs.path.join(alloc, &.{ cwd, path }) catch alloc.dupe(u8, path) catch null;
}

/// `<xdg-config>/roost/config`. Caller frees.
fn configPath(alloc: Allocator) ![]u8 {
    const dir = try internal_os.xdg.config(alloc, .{ .subdir = "roost" });
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "config" });
}
