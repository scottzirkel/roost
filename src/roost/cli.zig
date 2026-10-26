//! `roost <command>`: ask running Roost windows about themselves, from a
//! terminal, an agent's pane, or a desktop bar. A command never opens a window.
//!
//!     roost status                 this pane's window (via ROOST_SOCK)
//!     roost status --all           every running window
//!     roost status --json          one line of JSON instead of text
//!     roost status --all --watch   JSON now and on every change, for a bar
//!     roost scratch read           print this window's Scratchpad
//!     roost scratch append [text]  add to it: the text, or stdin
//!     roost scratch replace [text] swap all of it for new text
//!     roost scratch clear          empty it
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

const scratch_usage =
    \\usage: roost scratch read
    \\       roost scratch append [text...]
    \\       roost scratch replace [text...]
    \\       roost scratch clear
    \\
    \\Reads or changes the Scratchpad of the Roost window this pane is in.
    \\
    \\  read     print the Scratchpad's Markdown
    \\  append   add Markdown to the end, as a new paragraph: the arguments,
    \\           or stdin when there are none. What's there stays as it is.
    \\  replace  swap the whole Scratchpad for new Markdown, given the same way
    \\  clear    empty the Scratchpad
    \\
    \\One Ctrl+Z in the Scratchpad undoes an append, a replace or a clear.
    \\A replace or clear also saves the old notes to a backup file first,
    \\and says where, so they survive a reload.
    \\
;

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
/// The same for `roost scratch`, which moves more text and has one window
/// to wait for.
const scratch_timeout_ms = 3000;
/// The longest reply read: a big Scratchpad, with room to spare.
const max_reply = 16 * 1024 * 1024;
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
    return std.mem.eql(u8, word, "status") or std.mem.eql(u8, word, "scratch");
}

/// Run `args` (argv without the program name), printing to stdout and stderr.
pub fn run(args: []const [:0]const u8) u8 {
    var out_buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.fs.File.stderr().writer(&err_buf);
    defer err.interface.flush() catch {};
    const code = if (std.mem.eql(u8, args[0], "scratch")) code: {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const stdin = std.fs.File.stdin();
        var in_buf: [4096]u8 = undefined;
        var in = stdin.reader(&in_buf);
        const piped = if (stdin.isTty()) null else &in.interface;
        break :code scratch(arena.allocator(), args[1..], paneSocket(), piped, &out.interface, &err.interface);
    } else status(args[1..], &out.interface, &err.interface);
    out.interface.flush() catch return 1;
    return code;
}

/// `roost scratch read|append|replace|clear` against the window at `sock`
/// (ROOST_SOCK). `stdin` is null when it's a terminal, so `append` and
/// `replace` don't sit waiting.
fn scratch(
    a: std.mem.Allocator,
    args: []const [:0]const u8,
    sock: ?[]const u8,
    stdin: ?*std.Io.Reader,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) u8 {
    const sub = if (args.len > 0) args[0] else "";
    if (std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "--help")) {
        out.writeAll(scratch_usage) catch {};
        return 0;
    }
    const append = std.mem.eql(u8, sub, "append");
    const req: control.Request = if (std.mem.eql(u8, sub, "read") and args.len == 1)
        .scratch_read
    else if (std.mem.eql(u8, sub, "clear") and args.len == 1)
        .{ .scratch_replace = "" }
    else if (append or std.mem.eql(u8, sub, "replace")) req: {
        const text = if (args.len > 1)
            std.mem.join(a, " ", args[1..]) catch return 1
        else if (stdin) |in|
            in.allocRemaining(a, .limited(control.Request.max_line)) catch |e| {
                if (e == error.StreamTooLong)
                    err.print("roost scratch {s}: that's too long. The limit is {d} KB.\n", .{ sub, control.Request.max_line / 1024 }) catch {}
                else
                    err.print("roost scratch {s}: couldn't read stdin.\n", .{sub}) catch {};
                return 1;
            }
        else {
            err.print("roost scratch {s}: give the text as arguments, or pipe it in.\n\n", .{sub}) catch {};
            err.writeAll(scratch_usage) catch {};
            return 2;
        };
        if (std.mem.trim(u8, text, &std.ascii.whitespace).len == 0) {
            if (append)
                err.writeAll("roost scratch append: nothing to add.\n") catch {}
            else
                err.writeAll("roost scratch replace: nothing to put there. To empty the Scratchpad, use roost scratch clear.\n") catch {};
            return 1;
        }
        if (!control.isText(text)) {
            err.print("roost scratch {s}: that isn't text. The Scratchpad takes UTF-8.\n", .{sub}) catch {};
            return 1;
        }
        break :req if (append) .{ .scratch_append = text } else .{ .scratch_replace = text };
    } else {
        if (sub.len == 0)
            err.writeAll("roost scratch: say read, append, replace or clear.\n\n") catch {}
        else
            err.print("roost scratch: unknown command '{s}'\n\n", .{std.mem.join(a, " ", args) catch sub}) catch {};
        err.writeAll(scratch_usage) catch {};
        return 2;
    };

    const path = sock orelse {
        err.writeAll("roost scratch: not in a Roost pane, so there's no Scratchpad to use.\n") catch {};
        return 1;
    };
    var line: std.Io.Writer.Allocating = .init(a);
    req.write(&line.writer) catch return 1;
    if (line.written().len > control.Request.max_line) {
        err.print("roost scratch {s}: that's too long. The limit is {d} KB.\n", .{ sub, control.Request.max_line / 1024 }) catch {};
        return 1;
    }

    const raw = ask(a, path, line.written(), scratch_timeout_ms) catch |e| switch (e) {
        error.NoWindow => {
            err.print("roost scratch: no window answers at {s}\n", .{path}) catch {};
            return 1;
        },
        else => "",
    };
    const reply_line = std.mem.trim(u8, raw, " \t\r\n");
    const reply = if (reply_line.len == 0) null else control.Reply.parse(a, reply_line) catch null;
    const r = reply orelse {
        err.writeAll("roost scratch: the window didn't answer. If it's an older Roost build, reload it to update.\n") catch {};
        return 1;
    };
    if (r.@"error") |why| {
        err.print("roost scratch: {s}\n", .{why}) catch {};
        return 1;
    }
    if (r.backup) |p| err.print("roost scratch: saved the old notes to {s}\n", .{p}) catch {};
    if (req == .scratch_read) {
        const text = r.text orelse "";
        out.writeAll(text) catch return 1;
        if (text.len > 0 and text[text.len - 1] != '\n') out.writeByte('\n') catch return 1;
    }
    return 0;
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
        const sock = paneSocket() orelse {
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

/// The socket of the window this pane is in, from ROOST_SOCK.
fn paneSocket() ?[]const u8 {
    const sock = posix.getenv("ROOST_SOCK") orelse return null;
    return if (sock.len > 0) sock else null;
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
    const reply = ask(arena, path, "status\n", answer_timeout_ms) catch |e| switch (e) {
        error.NoWindow => return null,
        else => return .{ .pid = pid },
    };
    const line = std.mem.trim(u8, reply, " \t\r\n");
    if (line.len == 0) return .{ .pid = pid };
    return control.Status.parse(arena, line) catch .{ .pid = pid };
}

/// Send `request` to the socket at `path` and read the reply until the window
/// closes the connection. Each send and read gets `timeout_ms`.
fn ask(arena: std.mem.Allocator, path: []const u8, request: []const u8, timeout_ms: u32) ![]u8 {
    const addr = std.net.Address.initUnix(path) catch return error.NoWindow;
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return error.NoWindow;
    defer posix.close(fd);
    const timeout: posix.timeval = .{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast(timeout_ms % 1000 * 1000),
    };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return error.NoWindow;
    var sent: usize = 0;
    while (sent < request.len) {
        // NOSIGNAL: a window that hangs up first must not kill us with SIGPIPE.
        sent += try posix.send(fd, request[sent..], posix.MSG.NOSIGNAL);
    }

    var reply: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (reply.items.len < max_reply) {
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
    try testing.expect(isCommand("scratch"));
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

/// A pretend window: answers one connection on `fd` with `reply` when the
/// request is `want`, or closes without a word when `reply` is empty, the way
/// an older Roost does.
fn fakeWindow(fd: posix.socket_t, want: []const u8, reply: []const u8) void {
    const conn = posix.accept(fd, null, null, posix.SOCK.CLOEXEC) catch return;
    defer posix.close(conn);
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len and std.mem.indexOfScalar(u8, buf[0..n], '\n') == null) {
        const got = posix.read(conn, buf[n..]) catch return;
        if (got == 0) break;
        n += got;
    }
    if (!std.mem.eql(u8, buf[0..n], want)) return;
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
        try .spawn(.{}, fakeWindow, .{ zed, "status\n", "{\"pid\":11,\"project\":\"/z/zed\",\"name\":\"zed\",\"branch\":\"main\",\"state\":\"working\"}\n" }),
        try .spawn(.{}, fakeWindow, .{ app, "status\n", "{\"pid\":22,\"project\":\"/a/App\",\"name\":\"App\",\"branch\":\"\",\"state\":\"needs-input\"}\n" }),
        try .spawn(.{}, fakeWindow, .{ old, "status\n", "" }),
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

/// Run `roost scratch` with `args` against a fake window that wants `want`
/// and answers `reply`. Returns the exit code; output lands in `out`/`err`.
fn scratchAgainst(
    args: []const [:0]const u8,
    stdin: ?*std.Io.Reader,
    want: []const u8,
    reply: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &dir_buf);
    if (dir.len + "/roost-1.sock".len >= 108) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ dir, "roost-1.sock" });
    const fd = try listen(path);
    defer posix.close(fd);
    const t = try std.Thread.spawn(.{}, fakeWindow, .{ fd, want, reply });
    defer t.join();
    return scratch(a, args, path, stdin, out, err);
}

test "scratch: read prints the text, ending in a newline" {
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    const code = try scratchAgainst(&.{"read"}, null, "scratch-read\n", "{\"text\":\"# Notes\\n\\n- one\"}\n", &out, &err);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("# Notes\n\n- one\n", out.buffered());
    try testing.expectEqualStrings("", err.buffered());
}

test "scratch: append sends stdin, or the arguments" {
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    var in: std.Io.Reader = .fixed("## Plan\n\n- ship\n");
    try testing.expectEqual(@as(u8, 0), try scratchAgainst(&.{"append"}, &in, "scratch-append {\"text\":\"## Plan\\n\\n- ship\\n\"}\n", "{\"ok\":true}\n", &out, &err));
    try testing.expectEqual(@as(u8, 0), try scratchAgainst(&.{ "append", "fix", "it" }, null, "scratch-append {\"text\":\"fix it\"}\n", "{\"ok\":true}\n", &out, &err));
    try testing.expectEqualStrings("", out.buffered());
    try testing.expectEqualStrings("", err.buffered());
}

test "scratch: replace sends the new text, and clear sends none" {
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [512]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    var in: std.Io.Reader = .fixed("## Next\n");
    try testing.expectEqual(@as(u8, 0), try scratchAgainst(&.{"replace"}, &in, "scratch-replace {\"text\":\"## Next\\n\"}\n", "{\"ok\":true,\"backup\":\"/p/old.md\"}\n", &out, &err));
    try testing.expectEqualStrings("roost scratch: saved the old notes to /p/old.md\n", err.buffered());
    err.end = 0;
    // Nothing to back up (an empty Scratchpad), so nothing to say.
    try testing.expectEqual(@as(u8, 0), try scratchAgainst(&.{"clear"}, null, "scratch-replace {\"text\":\"\"}\n", "{\"ok\":true}\n", &out, &err));
    try testing.expectEqualStrings("", err.buffered());

    // An empty replace would clear by accident, so it takes `clear` to do that.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var blank: std.Io.Reader = .fixed("\n");
    try testing.expectEqual(@as(u8, 1), scratch(arena.allocator(), &.{"replace"}, "/nonexistent", &blank, &out, &err));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "use roost scratch clear") != null);
    err.end = 0;
    try testing.expectEqual(@as(u8, 2), scratch(arena.allocator(), &.{ "clear", "all" }, "/nonexistent", null, &out, &err));
}

test "scratch: the window's error, an older window, and mistakes" {
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try testing.expectEqual(@as(u8, 1), try scratchAgainst(&.{"read"}, null, "scratch-read\n", "{\"error\":\"no pad\"}\n", &out, &err));
    try testing.expectEqualStrings("roost scratch: no pad\n", err.buffered());

    err.end = 0;
    try testing.expectEqual(@as(u8, 1), try scratchAgainst(&.{"read"}, null, "scratch-read\n", "", &out, &err));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "reload it") != null);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    err.end = 0;
    try testing.expectEqual(@as(u8, 2), scratch(a, &.{"append"}, "/nonexistent", null, &out, &err));
    err.end = 0;
    try testing.expectEqual(@as(u8, 2), scratch(a, &.{"wipe"}, "/nonexistent", null, &out, &err));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "unknown command 'wipe'") != null);
    err.end = 0;
    try testing.expectEqual(@as(u8, 2), scratch(a, &.{ "read", "more" }, "/nonexistent", null, &out, &err));
    err.end = 0;
    try testing.expectEqual(@as(u8, 1), scratch(a, &.{ "append", " " }, "/nonexistent", null, &out, &err));
    try testing.expectEqualStrings("roost scratch append: nothing to add.\n", err.buffered());
    err.end = 0;
    try testing.expectEqual(@as(u8, 1), scratch(a, &.{ "append", "caf\xe9" }, "/nonexistent", null, &out, &err));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "isn't text") != null);
    err.end = 0;
    try testing.expectEqual(@as(u8, 1), scratch(a, &.{"read"}, null, null, &out, &err));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "not in a Roost pane") != null);
    try testing.expectEqualStrings("", out.buffered());
}
