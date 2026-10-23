//! The checked-out git branch, read straight from the repository's `HEAD`.
//!
//! WHY: a status request is answered on the window's main loop, and a bar asks
//! every second. Running `git` there would stall the window each time, while
//! reading `HEAD` is two small file reads and is never out of date, even after
//! a checkout in the Shell pane.
//!
//! Finds the repository the way git does: walks up from the directory to the
//! first `.git`. That's a directory in a normal clone, or a file pointing at
//! the real git directory (`gitdir: <path>`) in a worktree or submodule.

const std = @import("std");

/// The branch checked out in the repository containing `dir`: its name, a
/// short commit id when HEAD is detached, or null outside a repository. The
/// result lives in `buf`.
pub fn branch(buf: []u8, dir: []const u8) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var head_buf: [512]u8 = undefined;
    const git_dir = findGitDir(&path_buf, dir) orelse return null;
    const head = readFile(&head_buf, git_dir, "HEAD") orelse return null;
    return parseHead(buf, head);
}

/// What a `HEAD` file says, copied into `buf`.
fn parseHead(buf: []u8, contents: []const u8) ?[]const u8 {
    const head = std.mem.trim(u8, contents, " \t\r\n");
    const name = if (std.mem.startsWith(u8, head, "ref: refs/heads/"))
        head["ref: refs/heads/".len..]
    else if (std.mem.startsWith(u8, head, "ref: "))
        head["ref: ".len..]
    else if (head.len >= 7 and isHex(head))
        head[0..7]
    else
        return null;
    if (name.len == 0 or name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

/// The git directory for `dir`, written into `buf`.
fn findGitDir(buf: *[std.fs.max_path_bytes]u8, dir: []const u8) ?[]const u8 {
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var d: ?[]const u8 = dir;
    while (d) |here| : (d = std.fs.path.dirname(here)) {
        const dot_git = std.fmt.bufPrint(buf, "{s}/.git", .{std.mem.trimRight(u8, here, "/")}) catch return null;
        const stat = std.fs.cwd().statFile(dot_git) catch continue;
        if (stat.kind == .directory) return dot_git;

        // A worktree's `.git` file: "gitdir: <path>", relative to `here`.
        const contents = readFile(&link_buf, here, ".git") orelse return null;
        const line = std.mem.trim(u8, contents, " \t\r\n");
        if (!std.mem.startsWith(u8, line, "gitdir: ")) return null;
        const target = std.mem.trim(u8, line["gitdir: ".len..], " \t");
        if (target.len == 0) return null;
        if (std.fs.path.isAbsolute(target)) {
            if (target.len > buf.len) return null;
            @memcpy(buf[0..target.len], target);
            return buf[0..target.len];
        }
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ here, target }) catch null;
    }
    return null;
}

/// `<dir>/<name>`'s first `buf.len` bytes, or null if it can't be read.
fn readFile(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const n = file.readAll(buf) catch return null;
    return buf[0..n];
}

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests (run with `zig test src/roost/core/git_head.zig`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseHead: a branch, a detached head, and junk" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("main", parseHead(&buf, "ref: refs/heads/main\n").?);
    try testing.expectEqualStrings("feature/x", parseHead(&buf, "ref: refs/heads/feature/x").?);
    try testing.expectEqualStrings("refs/remotes/o/m", parseHead(&buf, "ref: refs/remotes/o/m\n").?);
    try testing.expectEqualStrings("3d173dc", parseHead(&buf, "3d173dc1d4b0f6a1e2c5b7a8d9e0f1a2b3c4d5e6\n").?);
    try testing.expectEqual(@as(?[]const u8, null), parseHead(&buf, "ref: refs/heads/"));
    try testing.expectEqual(@as(?[]const u8, null), parseHead(&buf, "not a head"));
    try testing.expectEqual(@as(?[]const u8, null), parseHead(&buf, ""));
    var tiny: [3]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), parseHead(&tiny, "ref: refs/heads/main"));
}

test "branch: a clone, a subdirectory, a worktree, and no repo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    try tmp.dir.makePath("repo/.git/worktrees/wt");
    try tmp.dir.makePath("repo/src/deep");
    try tmp.dir.makePath("wt");
    try tmp.dir.makePath("loose");
    try tmp.dir.writeFile(.{ .sub_path = "repo/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(.{ .sub_path = "repo/.git/worktrees/wt/HEAD", .data = "ref: refs/heads/fix\n" });
    try tmp.dir.writeFile(.{ .sub_path = "wt/.git", .data = "gitdir: ../repo/.git/worktrees/wt\n" });

    var buf: [64]u8 = undefined;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const at = struct {
        fn f(b: []u8, r: []const u8, sub: []const u8) []const u8 {
            return std.fmt.bufPrint(b, "{s}/{s}", .{ r, sub }) catch unreachable;
        }
    }.f;
    try testing.expectEqualStrings("main", branch(&buf, at(&dir_buf, root, "repo")).?);
    try testing.expectEqualStrings("main", branch(&buf, at(&dir_buf, root, "repo/src/deep")).?);
    try testing.expectEqualStrings("fix", branch(&buf, at(&dir_buf, root, "wt")).?);

    // An absolute gitdir works too.
    var link_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "gitdir: {s}/repo/.git/worktrees/wt", .{root});
    try tmp.dir.writeFile(.{ .sub_path = "wt/.git", .data = link });
    try testing.expectEqualStrings("fix", branch(&buf, at(&dir_buf, root, "wt")).?);

    // A broken `.git` file stops the walk rather than finding an outer repo.
    try tmp.dir.makePath("repo/broken");
    try tmp.dir.writeFile(.{ .sub_path = "repo/broken/.git", .data = "nonsense" });
    try testing.expectEqual(@as(?[]const u8, null), branch(&buf, at(&dir_buf, root, "repo/broken")));

    // Outside any repo, unless the machine's temp dir is itself in one.
    if (findGitDir(&dir_buf, root) == null) {
        try testing.expectEqual(@as(?[]const u8, null), branch(&buf, at(&link_buf, root, "loose")));
    }
}
