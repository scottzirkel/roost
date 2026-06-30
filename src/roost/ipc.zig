//! roost IPC: a tiny Unix-domain socket that lets an out-of-process agent
//! (Claude Code, via the `scripts/roost-notify` helper wired into hooks) tell
//! the running roost window what it's doing. On each message we raise a native
//! desktop notification and update the Agent pane's status badge.
//!
//! WHY a socket (not a pipe/file): the agent runs INSIDE one of our panes (the
//! Agent pane runs `claude`), as a child of our process tree. We export the
//! socket path as `ROOST_SOCK` before spawning any pane, so every pane — and
//! every tool/hook the agent shells out to — inherits it and can reach us.
//!
//! INTEGRATION: the `gio.SocketService` runs on the default GLib main context,
//! which our run loop already pumps (`glib.MainContext.iteration`). So the
//! `incoming` signal fires inline during the loop — NO extra thread.
//!
//! PROTOCOL (deliberately tiny): one connection delivers one short line. The
//! first whitespace-delimited token is the EVENT; the rest is an optional
//! human message:
//!     done            -> "Agent finished"      (notification + ✓ badge)
//!     needs-input msg  -> "Agent needs you"     (notification + 🔔 badge)
//!     working          -> (no notification)     (● working badge only)
//! Unknown events are ignored.
//!
//! ADDITIVE: our own file. It names Ghostty's `Application` only to send a
//! notification the exact way Ghostty itself does (see application.zig's
//! `desktopNotification`).

const std = @import("std");
const posix = std.posix;

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");

const Application = @import("../apprt/gtk/class/application.zig").Application;
const internal_os = @import("../os/main.zig");
const layout = @import("layout.zig");
const Workspace = layout.Workspace;
const Config = @import("config.zig").Config;

const log = std.log.scoped(.roost_ipc);

/// Agent lifecycle state we surface in the badge + notifications.
pub const AgentEvent = enum {
    working,
    needs_input,
    done,

    fn fromToken(tok: []const u8) ?AgentEvent {
        if (std.mem.eql(u8, tok, "working")) return .working;
        if (std.mem.eql(u8, tok, "needs-input")) return .needs_input;
        if (std.mem.eql(u8, tok, "done")) return .done;
        return null;
    }

    /// Map to the tree/workspace badge status.
    fn status(self: AgentEvent) layout.AgentStatus {
        return switch (self) {
            .working => .working,
            .needs_input => .needs_input,
            .done => .done,
        };
    }
};

/// Everything an incoming message needs to act on the live UI. Lives in
/// `run`'s stack frame (like AppContext) so the pointer we hand the GLib signal
/// as user-data stays valid for the whole run loop.
pub const Server = struct {
    alloc: std.mem.Allocator,
    /// The GObject application, for `sendNotification`.
    app: *Application,
    /// The live workspace, for the Agent-pane status badge.
    workspace: *Workspace,
    /// User settings, for the audio-notifications toggle.
    config: *Config,
    /// Owned socket path (heap); unlinked + freed on `deinit`.
    path: [:0]u8,
    /// The listening service. Started on `init`; stopped/freed on `deinit`.
    service: *gio.SocketService,

    /// Create the socket, bind+listen, and connect the `incoming` handler to
    /// the default main context. `self` must be stored at a STABLE address by
    /// the caller (we hand its pointer to GLib as user-data).
    pub fn init(
        self: *Server,
        alloc: std.mem.Allocator,
        app: *Application,
        workspace: *Workspace,
        config: *Config,
    ) !void {
        const path = try socketPath(alloc);
        errdefer alloc.free(path);

        // Remove any stale socket file from a previous (crashed) run; otherwise
        // bind() fails with EADDRINUSE. Best-effort.
        std.fs.deleteFileAbsolute(path) catch {};

        const service = gio.SocketService.new();
        errdefer service.unref();

        const addr = gio.UnixSocketAddress.new(path.ptr);
        defer addr.unref();

        var gerr: ?*glib.Error = null;
        const ok = service.as(gio.SocketListener).addAddress(
            addr.as(gio.SocketAddress),
            .stream,
            .default,
            null, // no source object
            null, // we don't need the effective address back
            &gerr,
        );
        if (ok == 0) {
            defer if (gerr) |e| e.free();
            log.warn("could not listen on {s}: {s}", .{
                path,
                if (gerr) |e| (e.f_message orelse "(unknown)") else "(unknown)",
            });
            return error.ListenFailed;
        }

        self.* = .{
            .alloc = alloc,
            .app = app,
            .workspace = workspace,
            .config = config,
            .path = path,
            .service = service,
        };

        _ = gio.SocketService.signals.incoming.connect(
            service,
            *Server,
            onIncoming,
            self,
            .{},
        );

        // gio.SocketService starts active; `start` is idempotent, call it so we
        // don't depend on that default.
        service.start();

        // Export the path so every spawned pane (and the agent's hooks) can
        // reach us. MUST happen before the workspace spawns its panes.
        _ = internal_os.setenv("ROOST_SOCK", path);

        log.info("ipc listening on {s} (exported as ROOST_SOCK)", .{path});
    }

    /// Stop listening, unlink the socket, and free the path. Best-effort.
    pub fn deinit(self: *Server) void {
        self.service.stop();
        self.service.as(gio.SocketListener).close();
        self.service.unref();
        std.fs.deleteFileAbsolute(self.path) catch {};
        self.alloc.free(self.path);
        self.* = undefined;
    }

    /// Heap context for an in-flight async read: keeps the connection alive and
    /// owns the read buffer until the read completes off the main loop.
    /// align(8): the read binding wants `*[*]u8`, so the buffer must be
    /// pointer-aligned (the value we pass IS C's buffer address — see below).
    const ReadCtx = struct {
        server: *Server,
        connection: *gio.SocketConnection,
        buf: [1024]u8 align(8),
    };

    /// `incoming` signal handler. Starts an ASYNCHRONOUS read of one short
    /// message and returns TRUE immediately. A synchronous read here would block
    /// the GTK main loop until the client writes — so a process that connects to
    /// ROOST_SOCK (exported into every pane) but stalls before writing could
    /// freeze the whole UI. The read is serviced off the loop in
    /// `onReadComplete`, which drops the connection.
    fn onIncoming(
        _: *gio.SocketService,
        connection: *gio.SocketConnection,
        _: ?*gobject.Object,
        self: *Server,
    ) callconv(.c) c_int {
        const ctx = self.alloc.create(ReadCtx) catch return @intFromBool(true);
        ctx.* = .{ .server = self, .connection = connection, .buf = undefined };
        // Keep the connection alive across the async read: the SocketService
        // drops its ref once we return TRUE. Released in onReadComplete.
        _ = connection.as(gobject.Object).ref();
        const istream = connection.as(gio.IOStream).getInputStream();
        // The binding types g_input_stream_read_async's `void* buffer` as
        // `*[*]u8`; the pointer VALUE we pass is C's buffer address, so we hand
        // it a `*[*]u8` whose value is &ctx.buf — i.e. @ptrCast(&ctx.buf).
        istream.readAsync(@ptrCast(&ctx.buf), ctx.buf.len, 0, null, onReadComplete, ctx);
        return @intFromBool(true);
    }

    /// Async-read completion (main loop): parse the message, then free the
    /// context and drop the connection ref taken in `onIncoming`.
    fn onReadComplete(_: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const ctx: *ReadCtx = @ptrCast(@alignCast(data.?));
        defer {
            ctx.connection.as(gobject.Object).unref();
            ctx.server.alloc.destroy(ctx);
        }
        const istream = ctx.connection.as(gio.IOStream).getInputStream();
        var gerr: ?*glib.Error = null;
        defer if (gerr) |e| e.free();
        const n = istream.readFinish(res, &gerr);
        if (n <= 0) return; // EOF or error: nothing usable.
        const msg = std.mem.trim(u8, ctx.buf[0..@intCast(n)], " \t\r\n");
        ctx.server.handle(msg);
    }

    /// Parse + act on one message line. Public for direct unit-style exercise.
    pub fn handle(self: *Server, line: []const u8) void {
        if (line.len == 0) return;

        // Split into "<event> <rest...>".
        const sp = std.mem.indexOfScalar(u8, line, ' ');
        const tok = if (sp) |i| line[0..i] else line;
        const rest = if (sp) |i| std.mem.trim(u8, line[i + 1 ..], " \t") else "";

        const event = AgentEvent.fromToken(tok) orelse {
            log.debug("ignoring unknown ipc event '{s}'", .{tok});
            return;
        };

        log.info("agent event: {s}{s}{s}", .{
            @tagName(event),
            if (rest.len > 0) " — " else "",
            rest,
        });

        // Update the Agent-pane badge for every known event.
        self.workspace.setAgentStatus(event.status());

        // Notify (+ optional sound) for the attention-worthy events only.
        switch (event) {
            .working => {},
            .needs_input => {
                self.notify("Agent needs you", if (rest.len > 0) rest else "Your agent is waiting for input.");
                self.playSound("message");
            },
            .done => {
                self.notify("Agent finished", if (rest.len > 0) rest else "Your agent finished its task.");
                self.playSound("complete");
            },
        }
    }

    /// Raise a native desktop notification. Mirrors Ghostty's own
    /// `Application.desktopNotification` (application.zig): build a
    /// `gio.Notification`, set body + themed icon, send via the GApplication.
    /// Delegates to the shared `notifyApp` (the wired-actions runner uses it too)
    /// with the stable id "roost-agent" so a newer agent event REPLACES the old.
    fn notify(self: *Server, title: [:0]const u8, body: []const u8) void {
        notifyApp(self.app.as(gio.Application), "roost-agent", title, body);
    }

    /// Play a freedesktop event sound (e.g. `complete`, `message`) when the
    /// `audio-notifications` setting is on. No-op otherwise. Uses
    /// `canberra-gtk-play -i <id>` via gio.Subprocess — fire-and-forget (GLib
    /// reaps it on the main loop), and missing/failed spawns are swallowed so a
    /// sound never disrupts the agent. gio Notifications are silent by design, so
    /// this is the only audible cue.
    fn playSound(self: *Server, event_id: [*:0]const u8) void {
        if (!self.config.audio_notifications) return;
        const argv = [_:null]?[*:0]const u8{ "canberra-gtk-play", "-i", event_id };
        var gerr: ?*glib.Error = null;
        const proc = gio.Subprocess.newv(@ptrCast(&argv), .flags_none, &gerr) orelse {
            defer if (gerr) |e| e.free();
            log.debug("could not play sound '{s}': {s}", .{ event_id, if (gerr) |e| (e.f_message orelse "(unknown)") else "(unknown)" });
            return;
        };
        // We don't wait on it; drop our ref and let GLib reap it asynchronously.
        proc.unref();
    }
};

/// Build + send a desktop notification via `gio_app`. Shared by the IPC server
/// (agent events, id "roost-agent") and the wired-actions runner (action
/// results, id "roost-action"); a distinct `id` keeps action popups from
/// replacing agent ones (and vice-versa). `body` may be any slice (copied
/// NUL-terminated). The icon is the agent's `claude-desktop` with our app id as
/// a fallback — same lookup that makes Ghostty's own icon render under mako.
pub fn notifyApp(gio_app: *gio.Application, id: [*:0]const u8, title: [:0]const u8, body: []const u8) void {
    var body_buf: [1024]u8 = undefined;
    const body_z = std.fmt.bufPrintZ(&body_buf, "{s}", .{body}) catch body_buf[0..0 :0];

    const notification = gio.Notification.new(title);
    defer notification.unref();
    notification.setBody(body_z);

    const icon = gio.ThemedIcon.new("claude-desktop");
    defer icon.unref();
    icon.appendName("dev.scottzirkel.Roost");
    notification.setIcon(icon.as(gio.Icon));

    gio_app.sendNotification(id, notification);
}

/// Build the socket path: `${XDG_RUNTIME_DIR}/roost-<pid>.sock`, falling back
/// to `/tmp` when XDG_RUNTIME_DIR is unset. Caller owns the returned slice.
fn socketPath(alloc: std.mem.Allocator) ![:0]u8 {
    const dir = posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrintSentinel(alloc, "{s}/roost-{d}.sock", .{ dir, pid }, 0);
}

/// The directory roost sockets live in (`$XDG_RUNTIME_DIR`, else `/tmp`).
fn socketDir() []const u8 {
    return posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
}

/// True if another roost process is currently alive. Scans the socket dir for
/// `roost-<pid>.sock` and pings each PID (`kill(pid, 0)`), skipping our own.
/// Used to decide whether a fresh desktop launch should open the project
/// chooser (a sibling is running) or just open the last project. Best-effort:
/// any error is treated as "no sibling" (open normally). Note: this runs before
/// we create our OWN socket, so there's nothing of ours to skip yet — but we
/// exclude our PID anyway to stay correct if the call site ever moves.
pub fn liveSiblingExists() bool {
    const self_pid = std.os.linux.getpid();
    var dir = std.fs.openDirAbsolute(socketDir(), .{ .iterate = true }) catch return false;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        const name = entry.name;
        if (!std.mem.startsWith(u8, name, "roost-")) continue;
        if (!std.mem.endsWith(u8, name, ".sock")) continue;
        const pid_str = name["roost-".len .. name.len - ".sock".len];
        const pid = std.fmt.parseInt(std.os.linux.pid_t, pid_str, 10) catch continue;
        if (pid == self_pid) continue;
        // kill(pid, 0): no signal sent, just an existence/permission probe.
        // Success (or EPERM, which still means it exists) → a sibling is alive.
        posix.kill(pid, 0) catch |err| switch (err) {
            error.PermissionDenied => return true,
            else => continue, // ESRCH (dead) or anything else → not this one
        };
        return true;
    }
    return false;
}

/// Remove stale `roost-<pid>.sock` files whose PID has no live process. A
/// crashed/SIGKILLed instance can't unlink its own socket (only a clean exit
/// does, via `Server.deinit`), so dead sockets accumulate across launches. This
/// sweeps them once at startup. Best-effort: every error is ignored — leftover
/// clutter is harmless (`liveSiblingExists` already skips dead PIDs); this just
/// keeps the runtime dir tidy. Live sockets, and other users' sockets we can't
/// signal (EPERM), are left untouched. We collect the dead names first (an
/// `entry.name` is only valid during the walk) and unlink after, never mutating
/// the directory mid-iteration.
pub fn sweepStaleSockets(alloc: std.mem.Allocator) void {
    const self_pid = std.os.linux.getpid();
    var dir = std.fs.openDirAbsolute(socketDir(), .{ .iterate = true }) catch return;
    defer dir.close();

    var dead: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (dead.items) |n| alloc.free(n);
        dead.deinit(alloc);
    }

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        const name = entry.name;
        if (!std.mem.startsWith(u8, name, "roost-")) continue;
        if (!std.mem.endsWith(u8, name, ".sock")) continue;
        const pid_str = name["roost-".len .. name.len - ".sock".len];
        const pid = std.fmt.parseInt(std.os.linux.pid_t, pid_str, 10) catch continue;
        if (pid == self_pid) continue;

        const alive = alive: {
            posix.kill(pid, 0) catch |err| switch (err) {
                error.PermissionDenied => break :alive true, // exists (other user)
                else => break :alive false, // ESRCH → dead
            };
            break :alive true; // signal-able → alive
        };
        if (alive) continue;

        const dup = alloc.dupe(u8, name) catch continue;
        dead.append(alloc, dup) catch alloc.free(dup);
    }

    var removed: usize = 0;
    for (dead.items) |name| {
        dir.deleteFile(name) catch continue;
        removed += 1;
    }
    if (removed > 0) log.info("swept {d} stale roost socket(s)", .{removed});
}
