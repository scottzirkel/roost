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

    /// Play a sound on agent events (done / needs-input). Default off so a fresh
    /// install is quiet; pairs with the silent `gio.Notification` in `ipc.zig`.
    audio_notifications: bool = false,
    /// Persist the scratchpad pane's contents to `scratchpad_path` (load on
    /// open, autosave on edit). Default on.
    scratchpad_autosave: bool = true,
    /// Where the scratchpad is saved/loaded. Always a resolved, owned, absolute
    /// path after `load` (default `<xdg-config>/roost/scratchpad.md`).
    scratchpad_path: []const u8 = "",

    /// Load the config, applying file overrides on top of the defaults. Never
    /// fails: a missing/unreadable file yields the defaults. The returned Config
    /// owns `scratchpad_path` and must be `deinit`'d.
    pub fn load(alloc: Allocator) Config {
        var cfg: Config = .{
            .alloc = alloc,
            .scratchpad_path = defaultScratchpadPath(alloc),
        };

        const path = configPath(alloc) catch return cfg;
        defer alloc.free(path);
        const bytes = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch |err| {
            if (err != error.FileNotFound) log.warn("could not read config '{s}' err={}", .{ path, err });
            return cfg;
        };
        defer alloc.free(bytes);

        cfg.parse(bytes);
        log.info("config: audio_notifications={} scratchpad_autosave={} scratchpad_path='{s}'", .{
            cfg.audio_notifications, cfg.scratchpad_autosave, cfg.scratchpad_path,
        });
        return cfg;
    }

    pub fn deinit(self: *Config) void {
        self.alloc.free(self.scratchpad_path);
        self.* = undefined;
    }

    /// Replace `scratchpad_path` with an owned copy of `new_path` (resolving `~`
    /// + relative paths), freeing the previous value. No-op on empty input or
    /// OOM. Used by the settings UI before `save`.
    pub fn setScratchpadPath(self: *Config, new_path: []const u8) void {
        const trimmed = std.mem.trim(u8, new_path, " \t");
        if (trimmed.len == 0) return;
        const resolved = resolvePath(self.alloc, trimmed) orelse return;
        self.alloc.free(self.scratchpad_path);
        self.scratchpad_path = resolved;
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
        if (std.mem.eql(u8, key, "audio-notifications")) {
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
        try w.print("audio-notifications = {s}\n", .{boolStr(self.audio_notifications)});
        try w.print("scratchpad-autosave = {s}\n", .{boolStr(self.scratchpad_autosave)});
        try w.print("scratchpad-path = {s}\n", .{self.scratchpad_path});

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

/// `<xdg-config>/roost/scratchpad.md`. Caller owns. Falls back to a relative
/// name only if the xdg lookup fails (never expected).
fn defaultScratchpadPath(alloc: Allocator) []const u8 {
    const dir = internal_os.xdg.config(alloc, .{ .subdir = "roost" }) catch
        return alloc.dupe(u8, "scratchpad.md") catch "";
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "scratchpad.md" }) catch
        alloc.dupe(u8, "scratchpad.md") catch "";
}
