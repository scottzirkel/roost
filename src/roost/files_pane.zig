//! The Files pane's command: yazi, opened at the project's chosen folder and
//! sorted the way the project asks.
//!
//! A project sets them in `.roost/config`, `key = value` lines like Roost's
//! own config:
//!
//!     files-dir = output/router     # relative to the project, or absolute
//!     files-sort = newest           # newest | modified | name
//!
//! yazi takes the folder as an argument, but sorting only from its config.
//! So for a sort, Roost builds a config folder of its own: your yazi config
//! (`$YAZI_CONFIG_HOME`, else `~/.config/yazi`) with every file linked in,
//! except `yazi.toml`, which is copied with the sort settings added to its
//! `[mgr]` table. The pane runs yazi with `YAZI_CONFIG_HOME` pointing there,
//! so yazi elsewhere keeps your own sort.
//!
//! Std only, so it's unit-tested standalone.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.roost_files);

pub const Sort = enum {
    /// Newest created first, showing each file's creation time.
    newest,
    /// Last modified first, showing modification times.
    modified,
    /// yazi's own order.
    name,

    fn settings(self: Sort) ?[]const u8 {
        return switch (self) {
            .newest => "sort_by = \"btime\"\nsort_reverse = true\nsort_dir_first = true\nlinemode = \"btime\"\n",
            .modified => "sort_by = \"mtime\"\nsort_reverse = true\nsort_dir_first = true\nlinemode = \"mtime\"\n",
            .name => null,
        };
    }
};

/// A project's Files pane settings. Strings borrow from the text parsed.
pub const Settings = struct {
    dir: []const u8 = "",
    sort: Sort = .name,

    /// Read the `files-*` keys from `.roost/config` text. Other keys, blank
    /// lines and `#` comments are skipped; an unknown sort is ignored.
    pub fn parse(text: []const u8) Settings {
        var s: Settings = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.indexOf(u8, value, " #")) |hash| value = std.mem.trimRight(u8, value[0..hash], " \t");
            if (std.mem.eql(u8, key, "files-dir")) {
                s.dir = value;
            } else if (std.mem.eql(u8, key, "files-sort")) {
                s.sort = std.meta.stringToEnum(Sort, value) orelse s.sort;
            }
        }
        return s;
    }
};

/// `user` (the text of your `yazi.toml`, or "") with `sort`'s settings in its
/// `[mgr]` table: replacing any sort or line-mode keys there, or in a new
/// `[mgr]` table at the end. Accepts the older `[manager]` name too.
pub fn mergeToml(arena: Allocator, user: []const u8, sort: Sort) ![]const u8 {
    const ours = sort.settings() orelse return user;
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var in_mgr = false;
    var placed = false;
    var lines = std.mem.splitScalar(u8, user, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            in_mgr = std.mem.eql(u8, line, "[mgr]") or std.mem.eql(u8, line, "[manager]");
        } else if (in_mgr and isSortKey(line)) {
            continue; // ours replace it
        }
        if (!first) try w.writeByte('\n');
        first = false;
        try w.writeAll(raw);
        if (in_mgr and !placed and line.len > 0 and line[0] == '[') {
            try w.writeAll("\n");
            try w.writeAll(std.mem.trimRight(u8, ours, "\n"));
            placed = true;
        }
    }
    if (!placed) {
        if (out.written().len > 0 and out.written()[out.written().len - 1] != '\n') try w.writeByte('\n');
        try w.writeAll("\n[mgr]\n");
        try w.writeAll(ours);
    }
    return out.written();
}

fn isSortKey(line: []const u8) bool {
    const keys = [_][]const u8{ "sort_by", "sort_reverse", "sort_dir_first", "linemode" };
    for (keys) |k| {
        if (!std.mem.startsWith(u8, line, k)) continue;
        const rest = std.mem.trimLeft(u8, line[k.len..], " \t");
        if (rest.len > 0 and rest[0] == '=') return true;
    }
    return false;
}

/// `s` as one shell word, in single quotes.
fn quote(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// The shell command that starts yazi at `dir` (when not empty), with
/// `config_home` (when not empty) as its config folder.
pub fn command(arena: Allocator, program: []const u8, dir: []const u8, config_home: []const u8) ![:0]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (config_home.len > 0) {
        try w.writeAll("YAZI_CONFIG_HOME=");
        try quote(w, config_home);
        try w.writeByte(' ');
    }
    try w.writeAll(program);
    if (dir.len > 0) {
        try w.writeByte(' ');
        try quote(w, dir);
    }
    return out.toOwnedSliceSentinel(0);
}

/// Where your yazi config lives.
pub fn userConfigDir(arena: Allocator, yazi_home: ?[]const u8, config_home: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    if (yazi_home) |y| if (y.len > 0) return y;
    if (config_home) |c| if (c.len > 0) return std.fs.path.join(arena, &.{ c, "yazi" }) catch null;
    const h = home orelse return null;
    if (h.len == 0) return null;
    return std.fs.path.join(arena, &.{ h, ".config", "yazi" }) catch null;
}

/// Build (or refresh) the config folder at `out_dir` for `sort`, from your
/// config at `user_dir` (which may not exist). Errors leave yazi to fall
/// back to its defaults, so the caller just logs them.
pub fn buildConfig(arena: Allocator, user_dir: []const u8, out_dir: []const u8, sort: Sort) !void {
    try std.fs.cwd().makePath(out_dir);
    var out = try std.fs.cwd().openDir(out_dir, .{ .iterate = true });
    defer out.close();

    // Start clean: links from last time may point at files since removed.
    var stale: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = out.iterate();
    while (try it.next()) |e| try stale.append(arena, try arena.dupe(u8, e.name));
    for (stale.items) |name| out.deleteTree(name) catch {};

    var user_toml: []const u8 = "";
    if (std.fs.cwd().openDir(user_dir, .{ .iterate = true })) |ud_const| {
        var ud = ud_const;
        defer ud.close();
        var uit = ud.iterate();
        while (try uit.next()) |e| {
            if (std.mem.eql(u8, e.name, "yazi.toml")) {
                user_toml = ud.readFileAlloc(arena, "yazi.toml", 1024 * 1024) catch "";
                continue;
            }
            const target = try std.fs.path.join(arena, &.{ user_dir, e.name });
            out.symLink(target, e.name, .{ .is_directory = e.kind == .directory }) catch |err| log.warn("couldn't link {s}: {}", .{ target, err });
        }
    } else |_| {}

    try out.writeFile(.{ .sub_path = "yazi.toml", .data = try mergeToml(arena, user_toml, sort) });
}

/// The folder the pane opens: `dir` resolved against `project`, or "" (the
/// project itself) when it's empty or isn't a folder.
pub fn startDir(arena: Allocator, project: []const u8, dir: []const u8) []const u8 {
    if (dir.len == 0) return "";
    const path = std.fs.path.resolve(arena, &.{ project, dir }) catch return "";
    var d = std.fs.cwd().openDir(path, .{}) catch return "";
    d.close();
    return path;
}

// ---------------------------------------------------------------------------
// Tests (run with `zig test src/roost/files_pane.zig`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "settings: the files keys, with comments and unknown values" {
    const s = Settings.parse(
        \\# comfy
        \\files-dir = output/router   # where renders land
        \\files-sort = newest
        \\agent = claude
    );
    try testing.expectEqualStrings("output/router", s.dir);
    try testing.expectEqual(Sort.newest, s.sort);
    try testing.expectEqual(Sort.name, Settings.parse("files-sort = sideways").sort);
    try testing.expectEqualStrings("", Settings.parse("").dir);
}

test "mergeToml: into [mgr], replacing sort keys, or a new table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fresh = try mergeToml(a, "", .newest);
    try testing.expectEqualStrings("\n[mgr]\nsort_by = \"btime\"\nsort_reverse = true\nsort_dir_first = true\nlinemode = \"btime\"\n", fresh);

    const merged = try mergeToml(a,
        \\[mgr]
        \\show_hidden = true
        \\sort_by = "natural"
        \\linemode   = "size"
        \\
        \\[preview]
        \\sort_by = "keep me"
    , .modified);
    try testing.expectEqualStrings(
        \\[mgr]
        \\sort_by = "mtime"
        \\sort_reverse = true
        \\sort_dir_first = true
        \\linemode = "mtime"
        \\show_hidden = true
        \\
        \\[preview]
        \\sort_by = "keep me"
    , merged);
    // No [mgr] table: one is added at the end.
    const added = try mergeToml(a, "[preview]\nwrap = \"yes\"", .newest);
    try testing.expect(std.mem.endsWith(u8, added, "[mgr]\nsort_by = \"btime\"\nsort_reverse = true\nsort_dir_first = true\nlinemode = \"btime\"\n"));
    try testing.expect(std.mem.startsWith(u8, added, "[preview]\nwrap = \"yes\"\n"));
    // `name` leaves your file alone.
    try testing.expectEqualStrings("[mgr]\nsort_by = \"size\"", try mergeToml(a, "[mgr]\nsort_by = \"size\"", .name));
}

test "command: the folder and config, quoted for the shell" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("yazi", try command(a, "yazi", "", ""));
    try testing.expectEqualStrings("yazi '/p/it'\\''s out'", try command(a, "yazi", "/p/it's out", ""));
    try testing.expectEqualStrings("YAZI_CONFIG_HOME='/s/yazi/newest' yazi '/p/out'", try command(a, "yazi", "/p/out", "/s/yazi/newest"));
}

test "buildConfig: links your files, merges yazi.toml, and starts clean" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.makePath("user/plugins");
    try tmp.dir.writeFile(.{ .sub_path = "user/theme.toml", .data = "[mgr]\n" });
    try tmp.dir.writeFile(.{ .sub_path = "user/yazi.toml", .data = "[mgr]\nshow_hidden = true\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &buf);
    const user = try std.fs.path.join(a, &.{ root, "user" });
    const out = try std.fs.path.join(a, &.{ root, "out" });
    try tmp.dir.makePath("out");
    try tmp.dir.writeFile(.{ .sub_path = "out/gone.toml", .data = "old" });

    try buildConfig(a, user, out, .newest);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ user, "theme.toml" }), try tmp.dir.readLink("out/theme.toml", &link_buf));
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ user, "plugins" }), try tmp.dir.readLink("out/plugins", &link_buf));
    const toml = try tmp.dir.readFileAlloc(a, "out/yazi.toml", 4096);
    try testing.expect(std.mem.indexOf(u8, toml, "show_hidden = true") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "sort_by = \"btime\"") != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access("out/gone.toml", .{}));

    // No user config at all: just the sort.
    try buildConfig(a, "/nonexistent/yazi", out, .modified);
    try testing.expect(std.mem.indexOf(u8, try tmp.dir.readFileAlloc(a, "out/yazi.toml", 4096), "sort_by = \"mtime\"") != null);
}

test "startDir: inside the project, absolute, or nothing when missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.makePath("output/router");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &buf);
    const want = try std.fs.path.join(a, &.{ root, "output", "router" });
    try testing.expectEqualStrings(want, startDir(a, root, "output/router"));
    try testing.expectEqualStrings(want, startDir(a, "/elsewhere", want));
    try testing.expectEqualStrings("", startDir(a, root, "missing"));
    try testing.expectEqualStrings("", startDir(a, root, ""));
}
