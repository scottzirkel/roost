//! Services: wired actions that keep running, such as a dev server. The
//! portable parts: which services you've approved, where their logs go, how
//! long to wait before restarting one that crashed, and what a reload hands
//! the new build so it can pick running services back up.
//!
//! A service in a project's `.roost/actions.json` starts on its own only after
//! you approve it, because opening a cloned repo must not run its commands.
//! The approval is for that exact command, so a changed command asks again.
//! Services in your own `~/.config/roost/actions.json` need no approval.
//!
//! Plain std, so a Mac Roost can use it too.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The services you've approved, kept in `approvalsPath`.
pub const Approvals = struct {
    approved: []const Entry = &.{},

    pub const Entry = struct {
        project: []const u8,
        label: []const u8,
        command: []const u8,
    };

    pub fn isApproved(self: Approvals, project: []const u8, label: []const u8, command: []const u8) bool {
        for (self.approved) |e| {
            if (std.mem.eql(u8, e.project, project) and std.mem.eql(u8, e.label, label) and std.mem.eql(u8, e.command, command)) return true;
        }
        return false;
    }

    /// A copy with `entry` approved, replacing any earlier approval of the
    /// same service. Allocations live in `arena`.
    pub fn with(self: Approvals, arena: Allocator, entry: Entry) !Approvals {
        var list: std.ArrayListUnmanaged(Entry) = .empty;
        for (self.approved) |e| {
            if (std.mem.eql(u8, e.project, entry.project) and std.mem.eql(u8, e.label, entry.label)) continue;
            try list.append(arena, e);
        }
        try list.append(arena, entry);
        return .{ .approved = list.items };
    }

    pub fn write(self: Approvals, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.json.Stringify.value(self, .{ .whitespace = .indent_2 }, w);
        try w.writeByte('\n');
    }

    pub fn parse(arena: Allocator, text: []const u8) !Approvals {
        return std.json.parseFromSliceLeaky(Approvals, arena, text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    /// The approvals at `path`, or none when the file is missing or broken.
    pub fn load(arena: Allocator, path: []const u8) Approvals {
        const text = std.fs.cwd().readFileAlloc(arena, path, 1024 * 1024) catch return .{};
        return parse(arena, text) catch .{};
    }

    /// Write to `path` through a temporary file, so a crash can't leave half
    /// a file.
    pub fn save(self: Approvals, arena: Allocator, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
        var text: std.Io.Writer.Allocating = .init(arena);
        try self.write(&text.writer);
        const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
        try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = text.written() });
        try std.fs.cwd().rename(tmp, path);
    }
};

/// `$XDG_CONFIG_HOME/roost/approved-services.json`, else under `~/.config`.
/// In config, not state: it's a decision you made.
pub fn approvalsPath(arena: Allocator, config_home: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    if (config_home) |c| if (c.len > 0) return std.fs.path.join(arena, &.{ c, "roost", "approved-services.json" }) catch null;
    const h = home orelse return null;
    if (h.len == 0) return null;
    return std.fs.path.join(arena, &.{ h, ".config", "roost", "approved-services.json" }) catch null;
}

/// Where a service's output goes:
/// `$XDG_STATE_HOME/roost/services/<hash of project>/<label>.log`, else under
/// `~/.local/state`. The label is reduced to letters, digits and dashes.
pub fn logPath(arena: Allocator, state_home: ?[]const u8, home: ?[]const u8, project: []const u8, label: []const u8) ?[]const u8 {
    const base = if (state_home) |s| (if (s.len > 0) s else null) else null;
    const root = base orelse blk: {
        const h = home orelse return null;
        if (h.len == 0) return null;
        break :blk std.fs.path.join(arena, &.{ h, ".local", "state" }) catch return null;
    };
    var hash_buf: [16]u8 = undefined;
    const hash = std.fmt.bufPrint(&hash_buf, "{x:0>16}", .{std.hash.Wyhash.hash(0, project)}) catch return null;
    const name = std.fmt.allocPrint(arena, "{s}.log", .{slug(arena, label) orelse return null}) catch return null;
    return std.fs.path.join(arena, &.{ root, "roost", "services", hash, name }) catch null;
}

/// `label` as a file name: lowercase letters and digits, other runs as one
/// dash. "service" when nothing is left.
fn slug(arena: Allocator, label: []const u8) ?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var dash = false;
    for (label) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and out.items.len > 0) out.append(arena, '-') catch return null;
            dash = false;
            out.append(arena, std.ascii.toLower(c)) catch return null;
        } else dash = true;
    }
    if (out.items.len == 0) return "service";
    return out.items;
}

/// The first wait before restarting a service that stopped on its own.
pub const first_backoff_ms: u32 = 1000;
/// The longest wait.
pub const max_backoff_ms: u32 = 60_000;
/// A run at least this long counts as healthy, so the wait starts over.
pub const healthy_ms: i64 = 60_000;

/// How long to wait before restarting a service that ran for `ran_ms` and
/// last waited `last_ms` (0 for none): doubling while it keeps failing fast,
/// back to the start after a healthy run.
pub fn nextBackoff(last_ms: u32, ran_ms: i64) u32 {
    if (last_ms == 0 or ran_ms >= healthy_ms) return first_backoff_ms;
    return @min(last_ms *| 2, max_backoff_ms);
}

/// What a reload hands the new build, in `ROOST_SERVICES`: each running
/// service's label, command and pid. The service keeps running through the
/// re-exec, still our child, so the new build can wait on it again. And the
/// services you stopped, which stay stopped.
pub const Handoff = struct {
    services: []const Running = &.{},
    stopped: []const []const u8 = &.{},

    pub const Running = struct {
        label: []const u8,
        command: []const u8,
        pid: i32,
        /// When it started (ms since the epoch), for its uptime and backoff.
        started_ms: i64 = 0,
    };

    pub fn write(self: Handoff, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.json.Stringify.value(self, .{}, w);
    }

    pub fn parse(arena: Allocator, text: []const u8) Handoff {
        return std.json.parseFromSliceLeaky(Handoff, arena, text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch .{};
    }
};

/// The last `max` bytes of the file at `path`, starting on a line when it
/// can. Empty when there's no file. Lives in `arena`.
pub fn tailFile(arena: Allocator, path: []const u8, max: usize) []const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return "";
    defer file.close();
    const size = file.getEndPos() catch return "";
    const start = if (size > max) size - max else 0;
    file.seekTo(start) catch return "";
    const buf = arena.alloc(u8, @intCast(size - start)) catch return "";
    const n = file.readAll(buf) catch return "";
    const got = buf[0..n];
    if (start == 0) return got;
    const nl = std.mem.indexOfScalar(u8, got, '\n') orelse return got;
    return got[nl + 1 ..];
}

// ---------------------------------------------------------------------------
// Tests (run with `zig test src/roost/core/services.zig`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "approvals: an exact command, replaced when approved again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ap: Approvals = .{};
    try testing.expect(!ap.isApproved("/p", "Web", "npm run dev"));
    ap = try ap.with(a, .{ .project = "/p", .label = "Web", .command = "npm run dev" });
    try testing.expect(ap.isApproved("/p", "Web", "npm run dev"));
    // A changed command needs approving again; another project is separate.
    try testing.expect(!ap.isApproved("/p", "Web", "npm run dev -- --host"));
    try testing.expect(!ap.isApproved("/q", "Web", "npm run dev"));
    ap = try ap.with(a, .{ .project = "/p", .label = "Web", .command = "npm run dev -- --host" });
    try testing.expectEqual(@as(usize, 1), ap.approved.len);
    try testing.expect(ap.isApproved("/p", "Web", "npm run dev -- --host"));
}

test "approvals: saved and loaded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buf);
    const path = try std.fs.path.join(a, &.{ dir, "roost", "approved-services.json" });
    try testing.expectEqual(@as(usize, 0), Approvals.load(a, path).approved.len);
    const ap = try (Approvals{}).with(a, .{ .project = "/p", .label = "Comfy Router", .command = "comfy-router --no-browser" });
    try ap.save(a, path);
    try testing.expect(Approvals.load(a, path).isApproved("/p", "Comfy Router", "comfy-router --no-browser"));
}

test "paths: approvals in config, logs in state, named by the label" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/c/roost/approved-services.json", approvalsPath(a, "/c", "/h").?);
    try testing.expectEqualStrings("/h/.config/roost/approved-services.json", approvalsPath(a, null, "/h").?);
    const log = logPath(a, "/s", "/h", "/home/me/comfy", "Comfy Router!").?;
    try testing.expect(std.mem.startsWith(u8, log, "/s/roost/services/"));
    try testing.expect(std.mem.endsWith(u8, log, "/comfy-router.log"));
    try testing.expect(std.mem.startsWith(u8, logPath(a, "", "/h", "/p", "x").?, "/h/.local/state/roost/services/"));
    try testing.expect(!std.mem.eql(u8, logPath(a, "/s", null, "/a", "Web").?, logPath(a, "/s", null, "/b", "Web").?));
    try testing.expectEqualStrings("service", slug(a, "!!!").?);
    try testing.expectEqualStrings("npm-run-dev", slug(a, "  npm run  dev ").?);
}

test "backoff: doubles while failing fast, starts over after a healthy run" {
    try testing.expectEqual(first_backoff_ms, nextBackoff(0, 10));
    try testing.expectEqual(@as(u32, 2000), nextBackoff(1000, 10));
    try testing.expectEqual(@as(u32, 32_000), nextBackoff(16_000, 500));
    try testing.expectEqual(max_backoff_ms, nextBackoff(32_000, 500));
    try testing.expectEqual(max_backoff_ms, nextBackoff(max_backoff_ms, 500));
    try testing.expectEqual(first_backoff_ms, nextBackoff(max_backoff_ms, healthy_ms));
}

test "handoff: round-trips, and a bad one is empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try (Handoff{ .services = &.{.{ .label = "Web \"dev\"", .command = "npm run dev", .pid = 4242, .started_ms = 7 }}, .stopped = &.{"Queue"} }).write(&w);
    const back = Handoff.parse(a, w.buffered());
    try testing.expectEqual(@as(usize, 1), back.services.len);
    try testing.expectEqualStrings("Queue", back.stopped[0]);
    try testing.expectEqualStrings("Web \"dev\"", back.services[0].label);
    try testing.expectEqual(@as(i32, 4242), back.services[0].pid);
    try testing.expectEqual(@as(usize, 0), Handoff.parse(a, "garbage").services.len);
}

test "tailFile: the end of the file, from a line start" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(.{ .sub_path = "x.log", .data = "first line\nsecond line\nthird\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realpath(".", &buf), "x.log" });
    try testing.expectEqualStrings("first line\nsecond line\nthird\n", tailFile(a, path, 1000));
    try testing.expectEqualStrings("third\n", tailFile(a, path, 12));
    try testing.expectEqualStrings("", tailFile(a, "/nonexistent/x.log", 10));
}
