//! Scratchpad backups: a copy of the notes, taken just before
//! `roost scratch replace` or `roost scratch clear` swaps them out.
//!
//! WHY: the replace is one undo step, but GTK keeps undo history only while
//! the window is open, and autosave writes the new text within a second. After
//! a reload or a close, a copy on disk is the only way back.
//!
//! LAYOUT: next to the notes file, in `<stem>-backups/`, one file per replace,
//! named by UTC time so the names sort oldest first:
//!     <project>/.roost/scratchpad.md
//!     <project>/.roost/scratchpad-backups/2026-10-26T19-03-22.123Z.md
//! Only the newest `keep` are kept. The default notes live in `.roost/`, which
//! ignores itself in git, so the backups stay out of git status too.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How many backups are kept per notes file.
pub const keep = 10;

/// The backup folder for the notes at `notes_path`. Owned by `alloc`.
pub fn dirFor(alloc: Allocator, notes_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(notes_path) orelse ".";
    const stem = std.fs.path.stem(notes_path);
    return std.fmt.allocPrint(alloc, "{s}/{s}-backups", .{ dir, stem });
}

/// Save `text` as a new backup in `dir_path`, made if needed, then drop all
/// but the newest `keep`. Returns the backup's path, owned by `alloc`.
pub fn save(alloc: Allocator, dir_path: []const u8, text: []const u8, now_ms: i64) ![]u8 {
    try std.fs.cwd().makePath(dir_path);
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var name_buf: [name_len]u8 = undefined;
    const name = nameAt(&name_buf, now_ms);
    try dir.writeFile(.{ .sub_path = name, .data = text });
    prune(alloc, dir) catch {};
    return std.fs.path.join(alloc, &.{ dir_path, name });
}

const name_len = "2026-10-26T19-03-22.123Z.md".len;

/// The backup file name for `ms` since the epoch, in UTC.
fn nameAt(buf: *[name_len]u8, ms: i64) []const u8 {
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}.{d:0>3}Z.md", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        @as(u64, @intCast(@mod(ms, 1000))),
    }) catch unreachable;
}

/// True for a file this module named, so pruning never touches anything else
/// someone put in the folder.
fn isBackup(name: []const u8) bool {
    if (name.len != name_len or !std.mem.endsWith(u8, name, "Z.md")) return false;
    return std.ascii.isDigit(name[0]) and name[4] == '-' and name[10] == 'T';
}

/// Delete the oldest backups in `dir` until `keep` are left.
fn prune(alloc: Allocator, dir: std.fs.Dir) !void {
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !isBackup(entry.name)) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    if (names.items.len <= keep) return;
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    for (names.items[0 .. names.items.len - keep]) |n| dir.deleteFile(n) catch {};
}

// ---------------------------------------------------------------------------
// Tests (run with `zig test src/roost/core/backups.zig`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "dirFor: next to the notes, named after them" {
    const a = testing.allocator;
    const d = try dirFor(a, "/p/.roost/scratchpad.md");
    defer a.free(d);
    try testing.expectEqualStrings("/p/.roost/scratchpad-backups", d);
    const n = try dirFor(a, "/home/me/notes/todo.md");
    defer a.free(n);
    try testing.expectEqualStrings("/home/me/notes/todo-backups", n);
}

test "nameAt: UTC time that sorts oldest first" {
    var buf: [name_len]u8 = undefined;
    // 2026-10-26 19:03:22.007 UTC
    try testing.expectEqualStrings("2026-10-26T19-03-22.007Z.md", nameAt(&buf, 1793041402007));
    try testing.expect(isBackup(nameAt(&buf, 0)));
    try testing.expect(!isBackup("notes.md"));
    try testing.expect(!isBackup("2026-10-26T19-03-22.007Z.txt"));
}

test "save: writes the text, keeps the newest, and leaves other files alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    const dir_path = try std.fs.path.join(a, &.{ root, "scratchpad-backups" });
    defer a.free(dir_path);

    const first = try save(a, dir_path, "# old notes\n", 1_000);
    defer a.free(first);
    const back = try std.fs.cwd().readFileAlloc(a, first, 1024);
    defer a.free(back);
    try testing.expectEqualStrings("# old notes\n", back);

    try tmp.dir.writeFile(.{ .sub_path = "scratchpad-backups/mine.md", .data = "keep me" });
    var i: i64 = 1;
    while (i <= keep + 4) : (i += 1) {
        const p = try save(a, dir_path, "x", 1_000 + i * 1000);
        a.free(p);
    }

    var dir = try tmp.dir.openDir("scratchpad-backups", .{ .iterate = true });
    defer dir.close();
    var backups: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (isBackup(entry.name)) backups += 1;
    }
    try testing.expectEqual(@as(usize, keep), backups);
    // The oldest went first, and a file that isn't a backup stays.
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(first, .{}));
    try dir.access("mine.md", .{});
}
