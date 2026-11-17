//! Services: wired actions that keep running, such as a dev server or
//! comfy-router. A service starts with its project's window, restarts if it
//! stops on its own, and stops when the window closes. Its output goes to a
//! log file, which the header's Services menu shows and `roost output` reads.
//!
//! WHY a log file and not a pipe: a reload re-execs the window, which closes
//! every pipe. The service writes to a file instead, so it keeps running
//! through a reload. It's still our child after the exec (same pid), so the
//! new build waits on it again (see `adoptFromEnv`).
//!
//! The process is started with fork and exec rather than std's Child, so its
//! output can go straight to the file, and so it can reset the signals
//! Ghostty ignores (SIGPIPE) before running the command. It leads its own
//! process group, so Stop reaches everything it started: Ctrl+C (SIGINT)
//! first, like stopping it in a terminal, then SIGTERM, then SIGKILL.
//!
//! The portable parts (approvals, log paths, backoff, the reload hand-off)
//! are in `core/services.zig`. One window per process, so module state.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const actions = @import("actions.zig");
const ipc = @import("ipc.zig");
const core = @import("core/services.zig");

const log = std.log.scoped(.roost_services);
const ca = std.heap.c_allocator;

pub const State = enum {
    /// From a project's actions.json, and you haven't approved this command.
    needs_approval,
    stopped,
    running,
    /// It stopped on its own; it starts again after `backoff_ms`.
    restarting,
    /// Asked to stop; waiting for it to exit.
    stopping,

    fn words(self: State) []const u8 {
        return switch (self) {
            .needs_approval => "waiting for your OK to start",
            .stopped => "stopped",
            .running => "running",
            .restarting => "restarting",
            .stopping => "stopping",
        };
    }

    fn glyph(self: State) []const u8 {
        return switch (self) {
            .needs_approval => "?",
            .stopped => "○",
            .running => "●",
            .restarting => "↻",
            .stopping => "…",
        };
    }
};

pub const Service = struct {
    label: []u8,
    command: []u8,
    cwd: ?[]u8,
    /// The project directory it belongs to.
    project: []u8,
    log_path: []u8,
    state: State,
    pid: i32 = 0,
    started_ms: i64 = 0,
    backoff_ms: u32 = 0,
    /// How it last ended, for the menu: "exit 1", "signal 9", or "".
    last_end: [32]u8 = undefined,
    last_end_len: u8 = 0,
    restart_source: c_uint = 0,
    escalate_source: c_uint = 0,
    escalate_step: u8 = 0,
    /// Restart: start again once the stop finishes.
    start_after_stop: bool = false,
    /// From a project left behind; freed once it has exited.
    retired: bool = false,
    /// You stopped it before a reload, so the reloaded window doesn't start
    /// it. Cleared when you start it.
    held: bool = false,

    fn lastEnd(self: *const Service) []const u8 {
        return self.last_end[0..self.last_end_len];
    }
};

var list: std.ArrayListUnmanaged(*Service) = .empty;
/// The current project, whose services the menu shows.
var current_project: []u8 = &.{};
var gapp: ?*gio.Application = null;

/// For notifications when a service crashes. Call once at startup.
pub fn init(app: *gio.Application) void {
    gapp = app;
}

// --- Loading ---------------------------------------------------------------

/// Take `defs` (the services from the actions files) as `project`'s. A
/// service already running with the same label and command keeps running;
/// any other service is stopped and retired. Doesn't start anything: call
/// `adoptFromEnv` (at startup) and then `startReady`.
pub fn load(project: []const u8, defs: []const actions.Action) void {
    ca.free(current_project);
    current_project = ca.dupe(u8, project) catch &.{};

    var arena: std.heap.ArenaAllocator = .init(ca);
    defer arena.deinit();
    const ar = arena.allocator();
    const approvals = loadApprovals(ar);

    // Keep matching services; retire the rest.
    var kept: std.ArrayListUnmanaged(*Service) = .empty;
    defer kept.deinit(ca);
    for (list.items) |svc| {
        if (svc.retired) continue;
        const def = for (defs) |d| {
            if (std.mem.eql(u8, d.label, svc.label) and std.mem.eql(u8, d.command, svc.command) and std.mem.eql(u8, svc.project, project)) break d;
        } else null;
        if (def != null) {
            kept.append(ca, svc) catch {};
        } else retire(svc);
    }

    for (defs) |d| {
        const exists = for (kept.items) |svc| {
            if (std.mem.eql(u8, svc.label, d.label)) break true;
        } else false;
        if (exists) continue;
        const trusted = !d.from_project or approvals.isApproved(project, d.label, d.command);
        const svc = create(project, d, if (trusted) .stopped else .needs_approval) orelse continue;
        list.append(ca, svc) catch destroy(svc);
    }
    sweep();
    refresh();
}

fn create(project: []const u8, d: actions.Action, state: State) ?*Service {
    var arena: std.heap.ArenaAllocator = .init(ca);
    defer arena.deinit();
    const path = core.logPath(arena.allocator(), posix.getenv("XDG_STATE_HOME"), posix.getenv("HOME"), project, d.label) orelse return null;
    const svc = ca.create(Service) catch return null;
    svc.* = .{
        .label = ca.dupe(u8, d.label) catch return null,
        .command = ca.dupe(u8, d.command) catch return null,
        .cwd = if (d.cwd) |c| (ca.dupe(u8, c) catch null) else null,
        .project = ca.dupe(u8, project) catch return null,
        .log_path = ca.dupe(u8, path) catch return null,
        .state = state,
    };
    return svc;
}

fn destroy(svc: *Service) void {
    if (svc.restart_source != 0) _ = glib.Source.remove(svc.restart_source);
    if (svc.escalate_source != 0) _ = glib.Source.remove(svc.escalate_source);
    ca.free(svc.label);
    ca.free(svc.command);
    if (svc.cwd) |c| ca.free(c);
    ca.free(svc.project);
    ca.free(svc.log_path);
    ca.destroy(svc);
}

/// Stop `svc` for good: it's freed once it has exited.
fn retire(svc: *Service) void {
    svc.retired = true;
    svc.start_after_stop = false;
    stop(svc);
}

/// Free retired services that have exited.
fn sweep() void {
    var i: usize = 0;
    while (i < list.items.len) {
        const svc = list.items[i];
        if (svc.retired and svc.pid == 0) {
            _ = list.orderedRemove(i);
            destroy(svc);
        } else i += 1;
    }
}

fn loadApprovals(arena: std.mem.Allocator) core.Approvals {
    const path = core.approvalsPath(arena, posix.getenv("XDG_CONFIG_HOME"), posix.getenv("HOME")) orelse return .{};
    return core.Approvals.load(arena, path);
}

/// What a reload handed over, taken out of the environment by
/// `takeHandoff` before any pane starts, so no pane's shell inherits it.
var handed_over: ?[]u8 = null;

/// Take `ROOST_SERVICES` out of the environment. Call at startup, before the
/// panes are spawned.
pub fn takeHandoff() void {
    const text = posix.getenv("ROOST_SERVICES") orelse return;
    handed_over = ca.dupe(u8, text) catch null;
    _ = @import("../os/main.zig").unsetenv("ROOST_SERVICES");
}

/// Whether `pid` is this process's child: only a child survives our reload,
/// and only a child can be waited on.
fn isOurChild(pid: i32) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return false;
    var buf: [512]u8 = undefined;
    const stat = std.fs.cwd().readFile(path, &buf) catch return false;
    // "pid (comm) state ppid ...": comm may hold spaces and parens, so read
    // after the last ')'.
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return false;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    _ = fields.next(); // state
    const ppid = std.fmt.parseInt(i32, fields.next() orelse return false, 10) catch return false;
    return ppid == linux.getpid();
}

/// Pick up services a reload left running (see `handoff`). One that no
/// longer matches a service is stopped.
pub fn adoptFromEnv() void {
    const text = handed_over orelse return;
    defer {
        ca.free(text);
        handed_over = null;
    }
    var arena: std.heap.ArenaAllocator = .init(ca);
    defer arena.deinit();
    const left = core.Handoff.parse(arena.allocator(), text);
    for (left.stopped) |label| {
        for (list.items) |s| if (!s.retired and std.mem.eql(u8, s.label, label)) {
            s.held = true;
        };
    }
    for (left.services) |r| {
        if (r.pid <= 0 or !alive(r.pid)) continue;
        if (!isOurChild(r.pid)) {
            log.warn("service '{s}': pid {d} isn't ours, so it can't be picked up", .{ r.label, r.pid });
            continue;
        }
        const svc = for (list.items) |s| {
            if (!s.retired and s.pid == 0 and std.mem.eql(u8, s.label, r.label) and std.mem.eql(u8, s.command, r.command)) break s;
        } else null;
        if (svc) |s| {
            s.pid = r.pid;
            s.started_ms = r.started_ms;
            s.state = .running;
            watch(r.pid);
            log.info("service '{s}': picked up after reload (pid {d})", .{ s.label, r.pid });
        } else {
            // Its definition changed or went away: stop it like a retired one.
            const orphan = create(current_project, .{ .label = r.label, .command = r.command }, .running) orelse continue;
            orphan.pid = r.pid;
            list.append(ca, orphan) catch {
                destroy(orphan);
                continue;
            };
            watch(r.pid);
            retire(orphan);
            log.info("service '{s}': no longer defined; stopping it (pid {d})", .{ r.label, r.pid });
        }
    }
    refresh();
}

/// Start every service that may start and isn't running, unless a copy is
/// already running: one a crashed window left, which this window takes
/// over, or one another window runs.
pub fn startReady() void {
    for (list.items) |svc| {
        if (svc.retired or svc.held or svc.state != .stopped or !std.mem.eql(u8, svc.project, current_project)) continue;
        if (takeOverLeftover(svc)) continue;
        start(svc, true);
    }
    refresh();
}

/// Look for a running copy of `svc` from its pid file. A copy whose window
/// is gone (a crash) is adopted; one another live window runs is left to
/// it; one running an old command is stopped. True when `svc` must not be
/// started now.
fn takeOverLeftover(svc: *Service) bool {
    var arena: std.heap.ArenaAllocator = .init(ca);
    defer arena.deinit();
    const ar = arena.allocator();
    const path = core.pidPath(ar, svc.log_path) orelse return false;
    const text = std.fs.cwd().readFileAlloc(ar, path, 64 * 1024) catch return false;
    const pf = core.PidFile.parse(ar, text) orelse return false;
    if (pf.pid <= 0 or !alive(pf.pid) or startTime(pf.pid) != pf.start_time) {
        std.fs.deleteFileAbsolute(path) catch {};
        return false;
    }
    if (pf.owner != linux.getpid() and isRoostWindow(pf.owner)) {
        log.info("service '{s}' runs in Roost window {d}; not starting a second copy", .{ svc.label, pf.owner });
        setLastEnd(svc, "running in another Roost window");
        svc.held = true;
        return true;
    }
    if (!std.mem.eql(u8, pf.command, svc.command)) {
        log.info("service '{s}': stopping a copy running an old command (pid {d})", .{ svc.label, pf.pid });
        const orphan = create(svc.project, .{ .label = svc.label, .command = pf.command }, .running) orelse return false;
        orphan.pid = pf.pid;
        list.append(ca, orphan) catch {
            destroy(orphan);
            return false;
        };
        watch(pf.pid);
        retire(orphan);
        return false;
    }
    svc.pid = pf.pid;
    svc.state = .running;
    svc.started_ms = nowMs();
    watch(pf.pid);
    writePidFile(svc);
    log.info("service '{s}': took over the copy a closed window left running (pid {d})", .{ svc.label, pf.pid });
    return true;
}

/// Whether `pid` is a running Roost window: it answers on its socket file.
fn isRoostWindow(pid: i32) bool {
    if (pid <= 0 or !alive(pid)) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const sock = std.fmt.bufPrint(&buf, "{s}/roost-{d}.sock", .{ dir, pid }) catch return false;
    std.fs.accessAbsolute(sock, .{}) catch return false;
    return true;
}

/// The start time of `pid` from `/proc`, or 0 when it can't be read.
fn startTime(pid: i32) u64 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return 0;
    var buf: [1024]u8 = undefined;
    const stat = std.fs.cwd().readFile(path, &buf) catch return 0;
    return core.statStartTime(stat) orelse 0;
}

/// Record the running `svc` in its pid file, owned by this window.
fn writePidFile(svc: *Service) void {
    var arena: std.heap.ArenaAllocator = .init(ca);
    defer arena.deinit();
    const ar = arena.allocator();
    const path = core.pidPath(ar, svc.log_path) orelse return;
    var text: std.Io.Writer.Allocating = .init(ar);
    (core.PidFile{ .pid = svc.pid, .start_time = startTime(svc.pid), .owner = linux.getpid(), .command = svc.command }).write(&text.writer) catch return;
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = text.written() }) catch |e| log.warn("couldn't write {s}: {}", .{ path, e });
}

fn removePidFile(svc: *Service) void {
    var arena: std.heap.ArenaAllocator = .init(ca);
    defer arena.deinit();
    const path = core.pidPath(arena.allocator(), svc.log_path) orelse return;
    std.fs.deleteFileAbsolute(path) catch {};
}

/// What a reload hands the new build: the running services, as JSON for
/// `ROOST_SERVICES`. Owned by `alloc`; null when nothing's running.
pub fn handoff(alloc: std.mem.Allocator) ?[:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(ca);
    defer arena.deinit();
    var running: std.ArrayListUnmanaged(core.Handoff.Running) = .empty;
    var stopped: std.ArrayListUnmanaged([]const u8) = .empty;
    for (list.items) |svc| {
        if (svc.retired) continue;
        if (svc.state == .stopped or (svc.state == .stopping and !svc.start_after_stop)) {
            stopped.append(arena.allocator(), svc.label) catch {};
            continue;
        }
        if (svc.pid == 0 or svc.state != .running) continue;
        running.append(arena.allocator(), .{ .label = svc.label, .command = svc.command, .pid = svc.pid, .started_ms = svc.started_ms }) catch {};
    }
    if (running.items.len == 0 and stopped.items.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    (core.Handoff{ .services = running.items, .stopped = stopped.items }).write(&out.writer) catch {
        out.deinit();
        return null;
    };
    return out.toOwnedSliceSentinel(0) catch null;
}

// --- Running -----------------------------------------------------------------

fn nowMs() i64 {
    return std.time.milliTimestamp();
}

fn alive(pid: i32) bool {
    posix.kill(pid, 0) catch |e| return e == error.PermissionDenied;
    return true;
}

/// Start `svc`. `fresh` begins a new log (the old one is kept as `.log.1`);
/// a restart adds to the current one, so the crash stays readable.
fn start(svc: *Service, fresh: bool) void {
    if (svc.pid != 0) return;
    svc.held = false;
    if (svc.restart_source != 0) {
        _ = glib.Source.remove(svc.restart_source);
        svc.restart_source = 0;
    }
    spawn(svc, fresh) catch |e| {
        log.warn("service '{s}': couldn't start: {}", .{ svc.label, e });
        svc.state = .stopped;
        setLastEnd(svc, "couldn't start");
        refresh();
        return;
    };
    svc.state = .running;
    svc.started_ms = nowMs();
    log.info("service '{s}' started (pid {d}): {s}", .{ svc.label, svc.pid, svc.command });
    refresh();
}

fn spawn(svc: *Service, fresh: bool) !void {
    const path_z = try ca.dupeZ(u8, svc.log_path);
    defer ca.free(path_z);
    if (std.fs.path.dirname(svc.log_path)) |d| std.fs.cwd().makePath(d) catch {};
    if (fresh) {
        const old = try std.fmt.allocPrintSentinel(ca, "{s}.1", .{svc.log_path}, 0);
        defer ca.free(old);
        std.fs.renameAbsolute(svc.log_path, old) catch {};
    }
    const fd = try posix.openZ(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    defer posix.close(fd);
    var head_buf: [512]u8 = undefined;
    const head = (if (fresh or svc.last_end_len == 0)
        std.fmt.bufPrint(&head_buf, "--- roost: {s}: {s} ---\n", .{ if (fresh) "started" else "restarted", svc.command })
    else
        std.fmt.bufPrint(&head_buf, "--- roost: restarted after {s}: {s} ---\n", .{ svc.lastEnd(), svc.command })) catch "";
    _ = posix.write(fd, head) catch {};
    const null_fd = try posix.openZ("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer posix.close(null_fd);

    // Everything the child needs is ready before the fork: after it, only
    // async-signal-safe calls.
    const cmd_z = try ca.dupeZ(u8, svc.command);
    defer ca.free(cmd_z);
    const cwd_src = svc.cwd orelse svc.project;
    const cwd_z = try ca.dupeZ(u8, cwd_src);
    defer ca.free(cwd_z);
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr };

    const pid = try posix.fork();
    if (pid == 0) {
        _ = linux.setpgid(0, 0);
        // Undo what the window changed: Ghostty ignores SIGPIPE, and an
        // ignored signal stays ignored through exec, where a shell can't
        // even trap it. And a clean mask.
        var dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
        var sig: u8 = 1;
        while (sig < 32) : (sig += 1) {
            if (sig == linux.SIG.KILL or sig == linux.SIG.STOP) continue;
            _ = linux.sigaction(sig, &dfl, null);
        }
        const empty = linux.sigemptyset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
        _ = linux.dup2(null_fd, 0);
        _ = linux.dup2(fd, 1);
        _ = linux.dup2(fd, 2);
        _ = linux.chdir(cwd_z.ptr);
        _ = linux.execve("/bin/sh", &argv, @ptrCast(std.c.environ));
        linux.exit(127);
    }
    // Both sides set the group, so a signal sent right away still reaches it.
    _ = linux.setpgid(pid, pid);
    svc.pid = pid;
    writePidFile(svc);
    watch(pid);
}

/// Wait for `pid` on its own thread, and report its end on the main loop.
fn watch(pid: i32) void {
    const t = std.Thread.spawn(.{}, waiter, .{pid}) catch |e| {
        log.warn("couldn't watch pid {d}: {}", .{ pid, e });
        return;
    };
    t.detach();
}

const Ended = struct { pid: i32, status: u32, known: bool };

fn waiter(pid: i32) void {
    var status: u32 = 0;
    const known = while (true) {
        const rc = linux.waitpid(pid, &status, 0);
        switch (linux.E.init(rc)) {
            .SUCCESS => break true,
            .INTR => continue,
            // Not ours to wait on: watch it until it's gone instead.
            else => {
                while (alive(pid)) std.Thread.sleep(std.time.ns_per_s);
                break false;
            },
        }
    };
    const msg = ca.create(Ended) catch return;
    msg.* = .{ .pid = pid, .status = status, .known = known };
    _ = glib.idleAdd(onEnded, msg);
}

fn onEnded(data: ?*anyopaque) callconv(.c) c_int {
    const msg: *Ended = @ptrCast(@alignCast(data orelse return 0));
    defer ca.destroy(msg);
    const svc = for (list.items) |s| {
        if (s.pid == msg.pid) break s;
    } else return 0;

    svc.pid = 0;
    if (!svc.retired) removePidFile(svc);
    if (svc.escalate_source != 0) {
        _ = glib.Source.remove(svc.escalate_source);
        svc.escalate_source = 0;
    }
    var end_buf: [32]u8 = undefined;
    const end: []const u8 = if (!msg.known)
        "ended"
    else if (linux.W.IFEXITED(msg.status))
        std.fmt.bufPrint(&end_buf, "exit {d}", .{linux.W.EXITSTATUS(msg.status)}) catch "ended"
    else if (linux.W.IFSIGNALED(msg.status))
        std.fmt.bufPrint(&end_buf, "signal {d}", .{linux.W.TERMSIG(msg.status)}) catch "ended"
    else
        "ended";
    setLastEnd(svc, end);
    log.info("service '{s}' ended: {s}", .{ svc.label, end });

    if (svc.retired) {
        sweep();
    } else if (svc.state == .stopping) {
        svc.state = .stopped;
        if (svc.start_after_stop) {
            svc.start_after_stop = false;
            start(svc, false);
        }
    } else {
        // It stopped on its own: start it again, waiting longer each time it
        // fails fast.
        const ran = nowMs() - svc.started_ms;
        if (ran >= core.healthy_ms) notifyCrash(svc, end);
        svc.backoff_ms = core.nextBackoff(svc.backoff_ms, ran);
        svc.state = .restarting;
        svc.restart_source = glib.timeoutAdd(svc.backoff_ms, onRestartDue, svc);
    }
    refresh();
    return 0;
}

fn onRestartDue(data: ?*anyopaque) callconv(.c) c_int {
    const svc: *Service = @ptrCast(@alignCast(data orelse return 0));
    svc.restart_source = 0;
    if (svc.state == .restarting) start(svc, false);
    return 0;
}

fn setLastEnd(svc: *Service, end: []const u8) void {
    const n = @min(end.len, svc.last_end.len);
    @memcpy(svc.last_end[0..n], end[0..n]);
    svc.last_end_len = @intCast(n);
}

/// Stop `svc`: Ctrl+C to its group, then SIGTERM after 5 seconds, then
/// SIGKILL after 3 more.
fn stop(svc: *Service) void {
    if (svc.restart_source != 0) {
        _ = glib.Source.remove(svc.restart_source);
        svc.restart_source = 0;
    }
    if (svc.pid == 0) {
        if (svc.state != .needs_approval) svc.state = .stopped;
        return;
    }
    if (svc.state == .stopping) return;
    svc.state = .stopping;
    svc.escalate_step = 0;
    posix.kill(-svc.pid, posix.SIG.INT) catch {};
    svc.escalate_source = glib.timeoutAdd(5000, onEscalate, svc);
}

fn onEscalate(data: ?*anyopaque) callconv(.c) c_int {
    const svc: *Service = @ptrCast(@alignCast(data orelse return 0));
    if (svc.pid == 0) {
        svc.escalate_source = 0;
        return 0;
    }
    svc.escalate_step += 1;
    if (svc.escalate_step == 1) {
        log.info("service '{s}' ignored Ctrl+C; sending SIGTERM", .{svc.label});
        posix.kill(-svc.pid, posix.SIG.TERM) catch {};
        svc.escalate_source = glib.timeoutAdd(3000, onEscalate, svc);
    } else {
        log.info("service '{s}' ignored SIGTERM; sending SIGKILL", .{svc.label});
        posix.kill(-svc.pid, posix.SIG.KILL) catch {};
        svc.escalate_source = 0;
    }
    return 0;
}

/// The window is closing: stop every service and wait, up to 5 seconds for
/// Ctrl+C and 2 more for SIGTERM, before SIGKILL. Blocks; the window is
/// about to exit anyway.
pub fn stopAllBlocking() void {
    var any = false;
    for (list.items) |svc| {
        if (svc.pid == 0) continue;
        posix.kill(-svc.pid, posix.SIG.INT) catch {};
        any = true;
    }
    if (!any) return;
    log.info("stopping services before closing", .{});
    if (waitAllGone(5000)) return;
    for (list.items) |svc| if (svc.pid != 0 and alive(svc.pid)) posix.kill(-svc.pid, posix.SIG.TERM) catch {};
    if (waitAllGone(2000)) return;
    for (list.items) |svc| if (svc.pid != 0 and alive(svc.pid)) posix.kill(-svc.pid, posix.SIG.KILL) catch {};
}

/// Whether every service process exits within `ms`. The waiter threads reap
/// them, so a gone pid stops answering `kill(pid, 0)`.
fn waitAllGone(ms: u32) bool {
    var waited: u32 = 0;
    while (waited < ms) : (waited += 50) {
        const any = for (list.items) |svc| {
            if (svc.pid != 0 and alive(svc.pid)) break true;
        } else false;
        if (!any) return true;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    return false;
}

fn notifyCrash(svc: *Service, end: []const u8) void {
    const app = gapp orelse return;
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "{s} — {s} stopped", .{ std.fs.path.basename(svc.project), svc.label }) catch "A service stopped";
    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "It ended ({s}). Roost is starting it again.", .{end}) catch "";
    ipc.notifyApp(app, "roost-service", .roost, title, body);
}

// --- For the control socket --------------------------------------------------

/// The current project's service labeled `label`, ignoring case.
pub fn find(label: []const u8) ?*Service {
    for (list.items) |svc| {
        if (!svc.retired and std.mem.eql(u8, svc.project, current_project) and std.ascii.eqlIgnoreCase(svc.label, label)) return svc;
    }
    return null;
}

/// The end of `svc`'s log, at most `max` bytes. Lives in `arena`.
pub fn logTail(arena: std.mem.Allocator, svc: *const Service, max: usize) []const u8 {
    return core.tailFile(arena, svc.log_path, max);
}

/// What `roost run` does with a service: start it if it may and isn't
/// running. Null when it started, else why not.
pub fn runFromControl(svc: *Service) ?[]const u8 {
    return switch (svc.state) {
        .needs_approval => "It's a service from this project's actions.json that you haven't approved yet. Approve it in the window's Services menu.",
        .running, .stopping => "It's a service, and it's already running. Restart it from the window's Services menu.",
        .stopped, .restarting => {
            start(svc, svc.state == .stopped);
            return null;
        },
    };
}

// --- The header's Services menu ----------------------------------------------

var header_btn: ?*gtk.MenuButton = null;
var header_label: ?*gtk.Label = null;
var menu_box: ?*gtk.Box = null;
var window: ?*gtk.Window = null;

/// The header's Services menu button, hidden while the project has no
/// services. Call once, when building the header bar.
pub fn headerButton(win: *gtk.Window) *gtk.Widget {
    window = win;
    const btn = gtk.MenuButton.new();
    const label = gtk.Label.new("");
    btn.setChild(label.as(gtk.Widget));
    btn.setAlwaysShowArrow(1);
    const pop = gtk.Popover.new();
    const box = gtk.Box.new(.vertical, 10);
    box.as(gtk.Widget).setMarginTop(8);
    box.as(gtk.Widget).setMarginBottom(8);
    box.as(gtk.Widget).setMarginStart(8);
    box.as(gtk.Widget).setMarginEnd(8);
    pop.setChild(box.as(gtk.Widget));
    btn.setPopover(pop);
    header_btn = btn;
    header_label = label;
    menu_box = box;
    refresh();
    return btn.as(gtk.Widget);
}

/// The current project's services, in order.
fn shown(buf: []*Service) []*Service {
    var n: usize = 0;
    for (list.items) |svc| {
        if (svc.retired or !std.mem.eql(u8, svc.project, current_project)) continue;
        if (n == buf.len) break;
        buf[n] = svc;
        n += 1;
    }
    return buf[0..n];
}

/// Redraw the header button and its menu from the services' state.
fn refresh() void {
    const btn = header_btn orelse return;
    var buf: [32]*Service = undefined;
    const svcs = shown(&buf);
    btn.as(gtk.Widget).setVisible(@intFromBool(svcs.len > 0));
    if (svcs.len == 0) return;

    // The button: one service by name, several by count, led by the state
    // that most wants attention.
    var worst: State = .running;
    var running: usize = 0;
    for (svcs) |s| {
        if (s.state == .running) running += 1;
        if (rank(s.state) > rank(worst)) worst = s.state;
    }
    var text_buf: [160]u8 = undefined;
    const text = if (svcs.len == 1)
        std.fmt.bufPrintZ(&text_buf, "{s} {s}", .{ svcs[0].state.glyph(), svcs[0].label }) catch "Services"
    else
        std.fmt.bufPrintZ(&text_buf, "{s} {d}/{d} services", .{ worst.glyph(), running, svcs.len }) catch "Services";
    if (header_label) |l| l.setText(text);
    var tip: std.Io.Writer.Allocating = .init(ca);
    defer tip.deinit();
    for (svcs, 0..) |s, i| tip.writer.print("{s}{s} — {s}", .{ if (i > 0) "\n" else "", s.label, s.state.words() }) catch {};
    if (ca.dupeZ(u8, tip.written())) |z| {
        defer ca.free(z);
        btn.as(gtk.Widget).setTooltipText(z);
    } else |_| {}

    // The menu: a row per service, rebuilt each time.
    const box = menu_box orelse return;
    while (box.as(gtk.Widget).getFirstChild()) |child| box.remove(child);
    for (svcs) |s| box.append(serviceRow(s));
}

fn rank(state: State) u8 {
    return switch (state) {
        .running => 0,
        .stopped => 1,
        .stopping => 2,
        .restarting => 3,
        .needs_approval => 4,
    };
}

fn serviceRow(svc: *Service) *gtk.Widget {
    const row = gtk.Box.new(.vertical, 4);
    const title_z = ca.dupeZ(u8, svc.label) catch return row.as(gtk.Widget);
    defer ca.free(title_z);
    const title = gtk.Label.new(title_z);
    title.setXalign(0);
    title.as(gtk.Widget).addCssClass("heading");
    row.append(title.as(gtk.Widget));

    var detail_buf: [256]u8 = undefined;
    const detail = switch (svc.state) {
        .restarting => std.fmt.bufPrintZ(&detail_buf, "{s} ({s}); starting again in {d} s", .{ svc.state.words(), svc.lastEnd(), (svc.backoff_ms + 999) / 1000 }),
        .stopped => if (svc.last_end_len > 0)
            std.fmt.bufPrintZ(&detail_buf, "{s} ({s})", .{ svc.state.words(), svc.lastEnd() })
        else
            std.fmt.bufPrintZ(&detail_buf, "{s}", .{svc.state.words()}),
        else => std.fmt.bufPrintZ(&detail_buf, "{s}", .{svc.state.words()}),
    } catch "";
    const state = gtk.Label.new(detail);
    state.setXalign(0);
    state.as(gtk.Widget).addCssClass("dim-label");
    row.append(state.as(gtk.Widget));

    if (svc.state == .needs_approval) {
        // Show exactly what would run, so the OK means something.
        var cmd_buf: [600]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "This project's actions.json wants to run:\n{s}", .{svc.command}) catch "";
        const cmd_label = gtk.Label.new(cmd);
        cmd_label.setXalign(0);
        cmd_label.setWrap(1);
        cmd_label.setMaxWidthChars(50);
        cmd_label.setSelectable(1);
        row.append(cmd_label.as(gtk.Widget));
    }

    const buttons = gtk.Box.new(.horizontal, 6);
    switch (svc.state) {
        .needs_approval => addButton(buttons, "Approve and Start", onApprove, svc),
        .stopped => addButton(buttons, "Start", onStart, svc),
        .running => {
            addButton(buttons, "Restart", onRestart, svc);
            addButton(buttons, "Stop", onStop, svc);
        },
        .restarting => addButton(buttons, "Stop", onStop, svc),
        .stopping => {},
    }
    addButton(buttons, "Output", onOutput, svc);
    row.append(buttons.as(gtk.Widget));
    return row.as(gtk.Widget);
}

fn addButton(box: *gtk.Box, label: [*:0]const u8, cb: *const fn (*gtk.Button, *Service) callconv(.c) void, svc: *Service) void {
    const b = gtk.Button.newWithLabel(label);
    _ = gtk.Button.signals.clicked.connect(b, *Service, cb, svc, .{});
    box.append(b.as(gtk.Widget));
}

fn popdown() void {
    if (header_btn) |b| b.popdown();
}

fn onStart(_: *gtk.Button, svc: *Service) callconv(.c) void {
    popdown();
    svc.backoff_ms = 0;
    svc.last_end_len = 0;
    if (!takeOverLeftover(svc)) start(svc, true);
    refresh();
}

fn onStop(_: *gtk.Button, svc: *Service) callconv(.c) void {
    popdown();
    svc.start_after_stop = false;
    stop(svc);
    refresh();
}

fn onRestart(_: *gtk.Button, svc: *Service) callconv(.c) void {
    popdown();
    svc.backoff_ms = 0;
    svc.start_after_stop = true;
    stop(svc);
    refresh();
}

fn onApprove(_: *gtk.Button, svc: *Service) callconv(.c) void {
    popdown();
    var arena: std.heap.ArenaAllocator = .init(ca);
    defer arena.deinit();
    const ar = arena.allocator();
    const path = core.approvalsPath(ar, posix.getenv("XDG_CONFIG_HOME"), posix.getenv("HOME")) orelse return;
    const approvals = core.Approvals.load(ar, path).with(ar, .{ .project = svc.project, .label = svc.label, .command = svc.command }) catch return;
    approvals.save(ar, path) catch |e| {
        log.warn("couldn't save the approval to {s}: {}", .{ path, e });
        return;
    };
    log.info("service '{s}' approved: {s}", .{ svc.label, svc.command });
    svc.state = .stopped;
    start(svc, true);
}

// --- The output dialog ---------------------------------------------------------

/// A live view of one service's log while its dialog is open.
const OutputView = struct {
    view: *gtk.TextView,
    path: [:0]u8,
    size: u64 = std.math.maxInt(u64),
    timer: c_uint = 0,
};

fn onOutput(_: *gtk.Button, svc: *Service) callconv(.c) void {
    popdown();
    const win = window orelse return;
    const ov = ca.create(OutputView) catch return;
    const path = ca.dupeZ(u8, svc.log_path) catch {
        ca.destroy(ov);
        return;
    };
    const view = gtk.TextView.new();
    view.setEditable(0);
    view.setCursorVisible(0);
    view.setMonospace(1);
    view.setWrapMode(.word_char);
    const scroller = gtk.ScrolledWindow.new();
    scroller.as(gtk.Widget).setSizeRequest(760, 440);
    scroller.setChild(view.as(gtk.Widget));
    ov.* = .{ .view = view, .path = path };
    reloadOutput(ov);
    ov.timer = glib.timeoutAdd(1000, onOutputTick, ov);

    var title_buf: [160]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "{s} — output", .{svc.label}) catch "Service output";
    const dialog = adw.AlertDialog.new(title, null);
    dialog.setExtraChild(scroller.as(gtk.Widget));
    dialog.addResponse("close", "Close");
    dialog.setDefaultResponse("close");
    dialog.setCloseResponse("close");
    _ = adw.Dialog.signals.closed.connect(dialog.as(adw.Dialog), *OutputView, onOutputClosed, ov, .{});
    dialog.choose(win.as(gtk.Widget), null, null, null);
}

fn onOutputTick(data: ?*anyopaque) callconv(.c) c_int {
    const ov: *OutputView = @ptrCast(@alignCast(data orelse return 0));
    reloadOutput(ov);
    return 1;
}

/// Show the log's last 256 KB, when it has changed.
fn reloadOutput(ov: *OutputView) void {
    const size: u64 = if (std.fs.cwd().statFile(ov.path)) |st| st.size else |_| 0;
    if (size == ov.size) return;
    ov.size = size;
    var arena: std.heap.ArenaAllocator = .init(ca);
    defer arena.deinit();
    const text = core.tailFile(arena.allocator(), ov.path, 256 * 1024);
    const clean = if (std.unicode.utf8ValidateSlice(text)) text else "(the log isn't valid UTF-8)";
    const clean_z = arena.allocator().dupeZ(u8, clean) catch return;
    const buffer = ov.view.getBuffer();
    buffer.setText(clean_z.ptr, @intCast(clean_z.len));
    var end: gtk.TextIter = undefined;
    buffer.getEndIter(&end);
    _ = ov.view.scrollToIter(&end, 0.0, 0, 0.0, 0.0);
}

fn onOutputClosed(_: *adw.Dialog, ov: *OutputView) callconv(.c) void {
    if (ov.timer != 0) _ = glib.Source.remove(ov.timer);
    ca.free(ov.path);
    ca.destroy(ov);
}
