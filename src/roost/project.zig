//! Project-directory resolution and recent-projects persistence for roost.
//!
//! Phase 2.3: roost now has a real notion of "the current project directory".
//! Every terminal pane (Agent / Shell / Git-lazygit) launches there instead of
//! the user's home dir, so e.g. lazygit sees the repo.
//!
//! Resolution order (see `resolve`):
//!   1. The `ROOST_PROJECT` env var, if set and an existing dir.
//!   2. The process current working directory (where `roost` was launched).
//!   3. Fall back to `null` (panes inherit Ghostty's default cwd).
//!
//! NOTE: we deliberately do NOT read a positional CLI argument for the project
//! dir. Ghostty's own `state.init()` / config loader (`Config.loadCliArgs`)
//! parses `std.os.argv`, and any bare positional token there is treated as a
//! config field, producing a runtime "Configuration Errors: cli:1:<path>:
//! invalid field" dialog. The env var bypasses argv entirely, so there is no
//! collision and a bare `roost` (no args) produces no config error.
//!
//! Recents are persisted most-recent-first, newline-delimited, to
//! `$XDG_CONFIG_HOME/roost/recent-projects` (default `~/.config/...`).
//!
//! ADDITIVE: this is our own file; it touches no existing Ghostty source. It
//! reuses Ghostty's `internal_os.xdg` helper for the config dir.

const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.roost_project);

/// Max recent entries we keep on disk.
const max_recents = 20;

/// Owns the canonical absolute path to the current project directory and the
/// allocator used to back it. The path is always an absolute, sentinel-
/// terminated slice safe to hand to `Surface.new` (which dupes it anyway).
pub const Project = struct {
    alloc: Allocator,
    /// Absolute path to the project dir. Owned by `alloc`.
    path: [:0]const u8,

    /// Resolve the project directory and return a `Project`.
    ///
    /// Order: `ROOST_PROJECT` env var (validated as an existing directory) →
    /// process cwd → error (caller decides the null/inherit fallback).
    ///
    /// We intentionally read NO CLI args here: Ghostty's own argv parsing would
    /// reject a bare positional path as an invalid config field. The env var
    /// never touches argv, so it composes cleanly with `state.init()`.
    pub fn resolve(alloc: Allocator) !Project {
        // 1. Try the ROOST_PROJECT env var as an explicit project dir.
        //    std.posix.getenv is fine here: resolve() runs once at startup,
        //    single-threaded, before any env mutation.
        if (std.posix.getenv("ROOST_PROJECT")) |env_val| {
            if (env_val.len > 0) {
                if (try canonicalDir(alloc, env_val)) |abs| {
                    log.info("project dir from ROOST_PROJECT: {s}", .{abs});
                    return .{ .alloc = alloc, .path = abs };
                }
                log.warn(
                    "ROOST_PROJECT='{s}' is not an existing directory; falling back to cwd",
                    .{env_val},
                );
            }
        }

        // 2. Fall back to the process current working directory.
        const cwd = try std.process.getCwdAlloc(alloc);
        defer alloc.free(cwd);
        if (try canonicalDir(alloc, cwd)) |abs| {
            log.info("project dir from cwd: {s}", .{abs});
            return .{ .alloc = alloc, .path = abs };
        }

        return error.NoProjectDir;
    }

    /// Build a `Project` directly from a (possibly relative) path, validating
    /// it is an existing directory. Used by the picker. Caller owns nothing;
    /// `Project.deinit` frees the stored path.
    pub fn fromPath(alloc: Allocator, path: []const u8) !Project {
        const abs = (try canonicalDir(alloc, path)) orelse return error.NotADirectory;
        return .{ .alloc = alloc, .path = abs };
    }

    pub fn deinit(self: *Project) void {
        self.alloc.free(self.path);
        self.* = undefined;
    }

    /// The display name for the window title: the final path component
    /// (basename), or the full path if it has none (e.g. "/").
    pub fn displayName(self: *const Project) []const u8 {
        const base = std.fs.path.basename(self.path);
        return if (base.len == 0) self.path else base;
    }
};

/// Return an owned, absolute, sentinel-terminated path IF `path` resolves to an
/// existing directory; otherwise `null`. Errors only on OOM.
fn canonicalDir(alloc: Allocator, path: []const u8) !?[:0]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // Any realpath failure (FileNotFound / NotDir / AccessDenied / ...) just
    // means "not a usable directory" here; the caller falls back.
    const real = std.fs.cwd().realpath(path, &buf) catch return null;

    // realpath resolves symlinks but does not guarantee it is a directory;
    // confirm by trying to open it as one.
    var dir = std.fs.openDirAbsolute(real, .{}) catch return null;
    dir.close();

    return try alloc.dupeZ(u8, real);
}

// --- Recent projects ------------------------------------------------------

/// Path to the recent-projects file: `<xdg-config>/roost/recent-projects`.
/// Caller owns the returned slice.
fn recentsPath(alloc: Allocator) ![]u8 {
    // internal_os.xdg.config honors XDG_CONFIG_HOME and falls back to
    // ~/.config. `subdir` keeps it a single allocation.
    const dir = try internal_os.xdg.config(alloc, .{ .subdir = "roost" });
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "recent-projects" });
}

// --- Layout persistence ---------------------------------------------------
//
// The pane tree is persisted PER PROJECT/WORKTREE (Phase 3c): each project dir
// gets its own layout file under `<xdg-config>/roost/layouts/<key>.json`,
// where `<key>` is a hash of the canonical project path. This way switching
// between worktrees (or projects) restores each one's own arrangement. The
// previous global `<xdg-config>/roost/layout.json` is no longer read (a
// one-time reset to the default 2x2 on the first launch after upgrade).

/// Path to the per-project layout file:
/// `<xdg-config>/roost/layouts/<hash-of-path>.json`. Keyed by a 64-bit hash of
/// the (canonical) project path, hex-encoded, so it is always filename-safe.
/// Caller frees the returned slice.
fn layoutPathFor(alloc: Allocator, project_path: []const u8) ![]u8 {
    const dir = try internal_os.xdg.config(alloc, .{ .subdir = "roost" });
    defer alloc.free(dir);

    var hex: [16]u8 = undefined;
    const h = std.hash.Wyhash.hash(0, project_path);
    _ = std.fmt.bufPrint(&hex, "{x:0>16}", .{h}) catch unreachable; // u64 -> 16 hex chars

    const fname = try std.fmt.allocPrint(alloc, "layouts/{s}.json", .{hex[0..]});
    defer alloc.free(fname);
    return std.fs.path.join(alloc, &.{ dir, fname });
}

/// Read the saved layout JSON for `project_path`. Returns owned bytes, or null
/// if the file is missing/unreadable (caller falls back to the default layout).
/// Never throws on a missing file.
pub fn readLayout(alloc: Allocator, project_path: []const u8) ?[]u8 {
    const path = layoutPathFor(alloc, project_path) catch return null;
    defer alloc.free(path);
    return std.fs.cwd().readFileAlloc(alloc, path, 256 * 1024) catch |err| {
        if (err != error.FileNotFound) {
            log.warn("could not read layout file '{s}' err={}", .{ path, err });
        }
        return null;
    };
}

/// Write the layout JSON for `project_path`. Best-effort: logs and returns on
/// error so a failed save never disrupts shutdown.
pub fn writeLayout(alloc: Allocator, project_path: []const u8, bytes: []const u8) void {
    writeLayoutImpl(alloc, project_path, bytes) catch |err| {
        log.warn("could not write layout file err={}", .{err});
    };
}

fn writeLayoutImpl(alloc: Allocator, project_path: []const u8, bytes: []const u8) !void {
    const path = try layoutPathFor(alloc, project_path);
    defer alloc.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
    log.info("saved layout ({d} bytes)", .{bytes.len});
}

// --- Default layout -------------------------------------------------------
//
// A single user-wide "default layout" (vs. the per-project layouts above): the
// arrangement a project/worktree with NO saved layout of its own opens with,
// replacing the hardcoded built-in 2x2. Stored as the same serialized layout
// JSON at `<xdg-config>/roost/default-layout.json`. Set via "save current layout
// as default" in Settings; cleared to fall back to the built-in default.

/// Path to the user default-layout file. Caller frees.
fn defaultLayoutPath(alloc: Allocator) ![]u8 {
    const dir = try internal_os.xdg.config(alloc, .{ .subdir = "roost" });
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "default-layout.json" });
}

/// Read the user default layout JSON, or null if none is set (caller then builds
/// the built-in default tree). Never throws on a missing file.
pub fn readDefaultLayout(alloc: Allocator) ?[]u8 {
    const path = defaultLayoutPath(alloc) catch return null;
    defer alloc.free(path);
    return std.fs.cwd().readFileAlloc(alloc, path, 256 * 1024) catch |err| {
        if (err != error.FileNotFound) {
            log.warn("could not read default layout '{s}' err={}", .{ path, err });
        }
        return null;
    };
}

/// Whether the user has saved a custom default layout (for the Settings UI).
pub fn hasDefaultLayout(alloc: Allocator) bool {
    const path = defaultLayoutPath(alloc) catch return false;
    defer alloc.free(path);
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Write the user default layout JSON. Best-effort: logs and returns on error.
pub fn writeDefaultLayout(alloc: Allocator, bytes: []const u8) void {
    writeDefaultLayoutImpl(alloc, bytes) catch |err| {
        log.warn("could not write default layout err={}", .{err});
    };
}

fn writeDefaultLayoutImpl(alloc: Allocator, bytes: []const u8) !void {
    const path = try defaultLayoutPath(alloc);
    defer alloc.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
    log.info("saved default layout ({d} bytes)", .{bytes.len});
}

/// Delete the user default layout (reset to the built-in default). Best-effort;
/// a missing file is treated as success.
pub fn clearDefaultLayout(alloc: Allocator) void {
    const path = defaultLayoutPath(alloc) catch return;
    defer alloc.free(path);
    std.fs.cwd().deleteFile(path) catch |err| {
        if (err != error.FileNotFound) log.warn("could not clear default layout err={}", .{err});
    };
}

/// Read the recent-projects list (most-recent-first). Returns an owned slice of
/// owned strings; caller frees each entry then the slice. Missing file => empty.
pub fn readRecents(alloc: Allocator) ![][]const u8 {
    const path = try recentsPath(alloc);
    defer alloc.free(path);

    const data = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return alloc.alloc([]const u8, 0),
        else => return err,
    };
    defer alloc.free(data);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |it| alloc.free(it);
        list.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try list.append(alloc, try alloc.dupe(u8, trimmed));
    }

    return list.toOwnedSlice(alloc);
}

/// Promote `project_path` to the front of the recents list (de-duplicating),
/// truncate to `max_recents`, and write it back. Creates the config dir if
/// missing. Best-effort: logs and returns on error rather than failing launch.
pub fn recordRecent(alloc: Allocator, project_path: []const u8) void {
    recordRecentImpl(alloc, project_path) catch |err| {
        log.warn("could not record recent project '{s}' err={}", .{ project_path, err });
    };
}

fn recordRecentImpl(alloc: Allocator, project_path: []const u8) !void {
    // The recents file is newline-delimited, so a path containing a newline
    // (legal on Linux) would split into bogus entries on the next read,
    // corrupting the list. Such paths are pathological — skip recording rather
    // than mangle every other recent. (Entries already on disk are newline-free
    // by construction, so only the freshly-promoted path needs this guard.)
    if (std.mem.indexOfScalar(u8, project_path, '\n') != null) return;

    const path = try recentsPath(alloc);
    defer alloc.free(path);

    // Ensure the parent dir (`<xdg-config>/roost`) exists.
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const existing = try readRecents(alloc);
    defer {
        for (existing) |it| alloc.free(it);
        alloc.free(existing);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // New entry first.
    try buf.print(alloc, "{s}\n", .{project_path});

    // Then prior entries, skipping any duplicate of the promoted path, capped.
    var written: usize = 1;
    for (existing) |entry| {
        if (written >= max_recents) break;
        if (std.mem.eql(u8, entry, project_path)) continue;
        try buf.print(alloc, "{s}\n", .{entry});
        written += 1;
    }

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = buf.items });
    log.info("recorded recent project: {s}", .{project_path});
}
