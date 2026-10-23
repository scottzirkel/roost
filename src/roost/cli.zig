//! `roost <command>`: ask running Roost windows about themselves, from a
//! terminal, an agent's pane, or a desktop bar. A command never opens a window.
//!
//!     roost status                 this pane's window (via ROOST_SOCK)
//!     roost status --all           every running window
//!     roost status --json          one line of JSON instead of text
//!     roost status --all --watch   JSON now and on every change, for a bar
//!
//! It's the same binary that runs the window: `main` offers its argv here
//! first, and starts the window only when the first word isn't a command.
//! Ghostty reads the window's argv as config, and its flags start with `-` or
//! `+`, so a bare command word can't be mistaken for one.
//!
//! Each window answers on its own socket (see `core/control.zig`). This file
//! only finds the sockets, asks, and prints; it uses nothing but std.

const std = @import("std");
const posix = std.posix;
const control = @import("core/control.zig");

const usage =
    \\usage: roost status [--all] [--json] [--watch]
    \\
    \\Shows a Roost window's project, branch and agent state.
    \\
    \\  --all    every running window, not just the one this pane is in
    \\  --json   one line of JSON instead of text
    \\  --watch  with --all: print JSON now, then again whenever anything
    \\           changes (for a desktop bar)
    \\
;

/// How long one window gets to answer before it's reported as unknown.
const answer_timeout_ms = 500;
/// How often `--watch` asks again.
const watch_interval_ms = 1000;

/// Run the command named in `std.os.argv` and return its exit code, or null
/// when the arguments don't start with a command and the window should start.
pub fn command() ?u8 {
    const argv = std.os.argv;
    if (argv.len < 2 or !isCommand(std.mem.span(argv[1]))) return null;
    const args = std.process.argsAlloc(std.heap.page_allocator) catch return 1;
    return run(args[1..]);
}

/// Keep in sync with the list in `scripts/roost-launch`, which passes these
/// straight through instead of opening a window.
fn isCommand(word: []const u8) bool {
    return std.mem.eql(u8, word, "status");
}

/// Run `args` (argv without the program name), printing to stdout and stderr.
pub fn run(args: []const [:0]const u8) u8 {
    var out_buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.fs.File.stderr().writer(&err_buf);
    defer err.interface.flush() catch {};
    const code = status(args[1..], &out.interface, &err.interface);
    out.interface.flush() catch return 1;
    return code;
}

const Options = struct {
    all: bool = false,
    json: bool = false,
    watch: bool = false,
};

const ParseResult = union(enum) {
    run: Options,
    help,
    bad: []const u8,
};

fn parseOptions(args: []const [:0]const u8) ParseResult {
    var o: Options = .{};
    for (args) |a| {
        if (std.mem.eql(u8, a, "--all")) {
            o.all = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            o.json = true;
        } else if (std.mem.eql(u8, a, "--watch")) {
            o.watch = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return .help;
        } else {
            return .{ .bad = a };
        }
    }
    if (o.watch and !o.all) return .{ .bad = "--watch" };
    return .{ .run = o };
}

fn status(args: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer) u8 {
    const o = switch (parseOptions(args)) {
        .run => |o| o,
        .help => {
            out.writeAll(usage) catch {};
            return 0;
        },
        .bad => |a| {
            if (std.mem.eql(u8, a, "--watch"))
                err.writeAll("roost status: --watch needs --all\n\n") catch {}
            else
                err.print("roost status: unknown option '{s}'\n\n", .{a}) catch {};
            err.writeAll(usage) catch {};
            return 2;
        },
    };

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (!o.all) {
        const sock = posix.getenv("ROOST_SOCK") orelse {
            err.writeAll("roost status: not in a Roost pane, so there's no window to ask.\nUse --all to ask every running window.\n") catch {};
            return 1;
        };
        const pid = control.socketPid(std.fs.path.basename(sock)) orelse 0;
        const window = askStatus(a, sock, pid) orelse {
            err.print("roost status: no window answers at {s}\n", .{sock}) catch {};
            return 1;
        };
        const ok = if (o.json) window.write(out) else writeText(out, window);
        ok catch return 1;
        return 0;
    }

    const dir = socketDir();
    if (!o.watch) {
        const windows = collect(a, dir) catch return 1;
        const ok = if (o.json) writeJson(out, windows) else writeTexts(out, windows);
        ok catch return 1;
        return 0;
    }

    // --watch: one JSON line now, then one per change. Runs until the reader
    // goes away and a write fails.
    var last: std.ArrayListUnmanaged(u8) = .empty;
    defer last.deinit(std.heap.page_allocator);
    while (true) : (std.Thread.sleep(watch_interval_ms * std.time.ns_per_ms)) {
        _ = arena.reset(.retain_capacity);
        const windows = collect(a, dir) catch continue;
        var line: std.Io.Writer.Allocating = .init(a);
        writeJson(&line.writer, windows) catch continue;
        if (std.mem.eql(u8, line.written(), last.items)) continue;
        out.writeAll(line.written()) catch return 0;
        out.flush() catch return 0;
        last.clearRetainingCapacity();
        last.appendSlice(std.heap.page_allocator, line.written()) catch return 1;
    }
}

fn socketDir() []const u8 {
    return posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
}

/// Ask every window with a socket in `dir`. Sorted by project name, so a bar's
/// list stays put; windows that didn't say go last.
fn collect(arena: std.mem.Allocator, dir_path: []const u8) ![]control.Status {
    var list: std.ArrayListUnmanaged(control.Status) = .empty;
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return list.items;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const pid = control.socketPid(entry.name) orelse continue;
        if (entry.kind != .unix_domain_socket and entry.kind != .unknown) continue;
        const path = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        if (askStatus(arena, path, pid)) |s| try list.append(arena, s);
    }
    std.mem.sort(control.Status, list.items, {}, before);
    return list.items;
}

fn before(_: void, x: control.Status, y: control.Status) bool {
    if ((x.name.len == 0) != (y.name.len == 0)) return x.name.len != 0;
    return switch (std.ascii.orderIgnoreCase(x.name, y.name)) {
        .lt => true,
        .gt => false,
        .eq => x.pid < y.pid,
    };
}

/// The window at `path`, or null when nothing listens there (a socket left by
/// a window that died). A window that doesn't answer, or answers with
/// something else, is reported with only its pid.
fn askStatus(arena: std.mem.Allocator, path: []const u8, pid: i32) ?control.Status {
    const reply = ask(arena, path, "status\n") catch |e| switch (e) {
        error.NoWindow => return null,
        else => return .{ .pid = pid },
    };
    const line = std.mem.trim(u8, reply, " \t\r\n");
    if (line.len == 0) return .{ .pid = pid };
    return control.Status.parse(arena, line) catch .{ .pid = pid };
}

/// Send `request` to the socket at `path` and read the reply until the window
/// closes the connection.
fn ask(arena: std.mem.Allocator, path: []const u8, request: []const u8) ![]u8 {
    const addr = std.net.Address.initUnix(path) catch return error.NoWindow;
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return error.NoWindow;
    defer posix.close(fd);
    const timeout: posix.timeval = .{ .sec = 0, .usec = answer_timeout_ms * 1000 };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return error.NoWindow;
    // NOSIGNAL: a window that hangs up first must not kill us with SIGPIPE.
    _ = try posix.send(fd, request, posix.MSG.NOSIGNAL);

    var reply: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (reply.items.len < 64 * 1024) {
        const n = try posix.read(fd, &buf);
        if (n == 0) break;
        try reply.appendSlice(arena, buf[0..n]);
    }
    return reply.items;
}

fn writeJson(out: *std.Io.Writer, windows: []const control.Status) std.Io.Writer.Error!void {
    try std.json.Stringify.value(.{ .windows = windows }, .{}, out);
    try out.writeByte('\n');
}

fn writeTexts(out: *std.Io.Writer, windows: []const control.Status) std.Io.Writer.Error!void {
    if (windows.len == 0) return out.writeAll("No Roost windows are running.\n");
    for (windows) |w| try writeText(out, w);
}

/// One window as a line of text, with the same glyphs as the window title.
fn writeText(out: *std.Io.Writer, w: control.Status) std.Io.Writer.Error!void {
    if (w.name.len == 0) {
        return out.print("  Roost window {d}: no status. If it's an older build, reload it.\n", .{w.pid});
    }
    const glyph = switch (w.state) {
        .needs_input => "🔔",
        .done => "✓",
        .working => "●",
        .idle, .unknown => " ",
    };
    try out.print("{s} {s}", .{ glyph, w.name });
    if (w.branch.len > 0) try out.print(" · {s}", .{w.branch});
    switch (w.state) {
        .needs_input => try out.writeAll(" — needs you"),
        .done => try out.writeAll(" — done"),
        .working => try out.writeAll(" — working"),
        .idle => try out.writeAll(" — idle"),
        .unknown => {},
    }
    try out.writeByte('\n');
}

// ---------------------------------------------------------------------------
// Tests (run with `zig test src/roost/cli.zig`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "options: flags, help, and mistakes" {
    try testing.expectEqual(Options{}, parseOptions(&.{}).run);
    try testing.expectEqual(Options{ .all = true, .json = true, .watch = true }, parseOptions(&.{ "--watch", "--json", "--all" }).run);
    try testing.expect(parseOptions(&.{"--help"}) == .help);
    try testing.expectEqualStrings("--al", parseOptions(&.{"--al"}).bad);
    try testing.expectEqualStrings("--watch", parseOptions(&.{"--watch"}).bad);
    try testing.expect(isCommand("status"));
    try testing.expect(!isCommand("--class=dev.scottzirkel.Roost"));
}

test "text: glyphs, branches, and a window that didn't say" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeTexts(&w, &.{
        .{ .pid = 1, .name = "roost", .branch = "main", .state = .needs_input },
        .{ .pid = 2, .name = "notes", .state = .idle },
        .{ .pid = 3, .name = "app", .branch = "fix", .state = .unknown },
        .{ .pid = 4 },
    });
    try testing.expectEqualStrings(
        \\🔔 roost · main — needs you
        \\  notes — idle
        \\  app · fix
        \\  Roost window 4: no status. If it's an older build, reload it.
        \\
    , w.buffered());

    var empty: std.Io.Writer = .fixed(&buf);
    try writeTexts(&empty, &.{});
    try testing.expectEqualStrings("No Roost windows are running.\n", empty.buffered());
}

/// A pretend window: answers one connection on `fd` with `reply`, or closes
/// without a word when `reply` is empty, the way an older Roost does.
fn fakeWindow(fd: posix.socket_t, reply: []const u8) void {
    const conn = posix.accept(fd, null, null, posix.SOCK.CLOEXEC) catch return;
    defer posix.close(conn);
    var buf: [64]u8 = undefined;
    const n = posix.read(conn, &buf) catch return;
    if (!std.mem.eql(u8, buf[0..n], "status\n")) return;
    _ = posix.write(conn, reply) catch {};
}

fn listen(path: []const u8) !posix.socket_t {
    const addr = try std.net.Address.initUnix(path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 1);
    return fd;
}

test "collect: windows that answer, an older one, and dead sockets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &dir_buf);
    // Socket paths max out at 108 bytes; skip on a machine with a deep temp dir.
    if (dir.len + "/roost-1234.sock".len >= 108) return error.SkipZigTest;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const at = struct {
        fn f(al: std.mem.Allocator, d: []const u8, name: []const u8) []const u8 {
            return std.fs.path.join(al, &.{ d, name }) catch unreachable;
        }
    }.f;

    const zed = try listen(at(a, dir, "roost-11.sock"));
    defer posix.close(zed);
    const app = try listen(at(a, dir, "roost-22.sock"));
    defer posix.close(app);
    const old = try listen(at(a, dir, "roost-33.sock"));
    defer posix.close(old);
    // Bound but never listening: what a window that died leaves behind.
    const dead = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(dead);
    const dead_addr = try std.net.Address.initUnix(at(a, dir, "roost-44.sock"));
    try posix.bind(dead, &dead_addr.any, dead_addr.getOsSockLen());
    // Not a window's socket at all.
    try tmp.dir.writeFile(.{ .sub_path = "roost-55.sock.txt", .data = "" });

    const threads = [_]std.Thread{
        try .spawn(.{}, fakeWindow, .{ zed, "{\"pid\":11,\"project\":\"/z/zed\",\"name\":\"zed\",\"branch\":\"main\",\"state\":\"working\"}\n" }),
        try .spawn(.{}, fakeWindow, .{ app, "{\"pid\":22,\"project\":\"/a/App\",\"name\":\"App\",\"branch\":\"\",\"state\":\"needs-input\"}\n" }),
        try .spawn(.{}, fakeWindow, .{ old, "" }),
    };
    defer for (threads) |t| t.join();

    const windows = try collect(a, dir);
    try testing.expectEqual(@as(usize, 3), windows.len);
    try testing.expectEqualStrings("App", windows[0].name);
    try testing.expectEqual(control.State.needs_input, windows[0].state);
    try testing.expectEqualStrings("zed", windows[1].name);
    try testing.expectEqualStrings("main", windows[1].branch);
    try testing.expectEqual(@as(i32, 33), windows[2].pid);
    try testing.expectEqual(control.State.unknown, windows[2].state);

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJson(&w, windows[2..]);
    try testing.expectEqualStrings(
        \\{"windows":[{"pid":33,"project":"","name":"","branch":"","state":"unknown"}]}
        \\
    , w.buffered());
}
