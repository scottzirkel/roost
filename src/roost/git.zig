//! Git subprocess helpers for roost's worktree command center (Phase 3c).
//!
//! ADDITIVE: our own file. It shells out to `git` via `std.process.Child`,
//! mirroring the proven blueprint-compiler invocation in
//! `apprt/gtk/build/blueprint.zig` (spawn -> collectOutput -> wait). Nothing
//! here touches existing Ghostty source.

const std = @import("std");
const Allocator = std.mem.Allocator;

const proc = @import("proc.zig");

const log = std.log.scoped(.roost_git);

// The subprocess runner now lives in `proc.zig` (shared with the wired-actions
// runner). `proc.run(alloc, argv, cwd)` returns the same `{code,stdout,stderr}`
// Output this file used before; git commands pass `null` cwd (they target a dir
// via `-C <dir>` already).

/// Resolve the git repository root containing `dir`:
/// `git -C <dir> rev-parse --show-toplevel`. Returns the trimmed absolute path
/// (owned by `alloc`), or null if `dir` is not in a git work tree or git is
/// unavailable.
pub fn repoRoot(alloc: Allocator, dir: []const u8) ?[]u8 {
    const out = proc.run(alloc, &.{ "git", "-C", dir, "rev-parse", "--show-toplevel" }, null) catch |err| {
        log.warn("git rev-parse failed to run err={}", .{err});
        return null;
    };
    defer alloc.free(out.stdout);
    defer alloc.free(out.stderr);

    if (out.code != 0) return null;

    const trimmed = std.mem.trim(u8, out.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return alloc.dupe(u8, trimmed) catch null;
}

/// Resolve the current branch name of the repo containing `dir`:
/// `git -C <dir> rev-parse --abbrev-ref HEAD`. On a detached HEAD that command
/// prints the literal "HEAD", so we fall back to the short commit SHA
/// (`rev-parse --short HEAD`). Returns the trimmed name (owned by `alloc`), or
/// null if `dir` is not in a git work tree or git is unavailable.
pub fn currentBranch(alloc: Allocator, dir: []const u8) ?[]u8 {
    const out = proc.run(alloc, &.{ "git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD" }, null) catch |err| {
        log.warn("git rev-parse --abbrev-ref failed to run err={}", .{err});
        return null;
    };
    defer alloc.free(out.stdout);
    defer alloc.free(out.stderr);

    if (out.code != 0) return null;

    const trimmed = std.mem.trim(u8, out.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    // Detached HEAD: report the short SHA instead of the placeholder "HEAD".
    if (std.mem.eql(u8, trimmed, "HEAD")) return shortHead(alloc, dir);
    return alloc.dupe(u8, trimmed) catch null;
}

/// `git -C <dir> rev-parse --short HEAD` → owned short SHA, or null on error /
/// empty repo (no commits yet).
fn shortHead(alloc: Allocator, dir: []const u8) ?[]u8 {
    const out = proc.run(alloc, &.{ "git", "-C", dir, "rev-parse", "--short", "HEAD" }, null) catch return null;
    defer alloc.free(out.stdout);
    defer alloc.free(out.stderr);
    if (out.code != 0) return null;
    const trimmed = std.mem.trim(u8, out.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return alloc.dupe(u8, trimmed) catch null;
}

/// Create a new worktree+branch:
/// `git -C <repo_root> worktree add <dest> -b <branch>`.
///
/// Returns null on success. On failure, returns an owned, human-readable error
/// message (git's stderr, trimmed) suitable for a dialog; the caller frees it.
pub fn addWorktree(
    alloc: Allocator,
    repo_root: []const u8,
    dest: []const u8,
    branch: []const u8,
) ?[]u8 {
    const out = proc.run(alloc, &.{
        "git", "-C", repo_root, "worktree", "add", dest, "-b", branch,
    }, null) catch |err| {
        return std.fmt.allocPrint(alloc, "could not run git: {s}", .{@errorName(err)}) catch null;
    };
    defer alloc.free(out.stdout);
    defer alloc.free(out.stderr);

    if (out.code == 0) {
        log.info("created worktree '{s}' (branch '{s}')", .{ dest, branch });
        return null;
    }

    const trimmed = std.mem.trim(u8, out.stderr, &std.ascii.whitespace);
    const msg = if (trimmed.len > 0) trimmed else "git worktree add failed";
    log.warn("worktree add failed: {s}", .{msg});
    return alloc.dupe(u8, msg) catch null;
}

/// List the worktrees of the repo at `repo_root`:
/// `git -C <root> worktree list --porcelain`. The porcelain output is one block
/// per worktree, each beginning with a `worktree <abs-path>` line. Returns owned,
/// sentinel-terminated paths (each + the slice owned by `alloc`), or null on
/// error / not-a-repo.
pub fn worktreeList(alloc: Allocator, repo_root: []const u8) ?[][:0]u8 {
    const out = proc.run(alloc, &.{
        "git", "-C", repo_root, "worktree", "list", "--porcelain",
    }, null) catch return null;
    defer alloc.free(out.stdout);
    defer alloc.free(out.stderr);
    if (out.code != 0) return null;

    var list: std.ArrayListUnmanaged([:0]u8) = .empty;
    var ok = false;
    defer if (!ok) {
        for (list.items) |p| alloc.free(p);
        list.deinit(alloc);
    };

    const prefix = "worktree ";
    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const path = std.mem.trim(u8, line[prefix.len..], " \t\r");
        if (path.len == 0) continue;
        const dup = alloc.dupeZ(u8, path) catch return null;
        list.append(alloc, dup) catch {
            alloc.free(dup);
            return null;
        };
    }

    const slice = list.toOwnedSlice(alloc) catch return null;
    ok = true;
    return slice;
}
