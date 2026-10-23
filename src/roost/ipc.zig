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
//! PROTOCOL (deliberately tiny): one connection delivers one short line, an
//! EVENT plus an optional human message, optionally led by the sender's pane:
//!     done            -> "Agent finished"      (notification + ✓ badge)
//!     needs-input msg  -> "Agent needs you"     (notification + 🔔 badge)
//!     working          -> (no notification)     (● working badge only)
//!     pane=3 done     -> the same, for the pane whose ROOST_PANE is 3
//!     hook=Stop done  -> the same, naming the Claude Code hook that sent it
//!     session=<id> done -> the same, from that Claude session (for reload)
//! Unknown events are ignored. Parsing lives in `core/hook_msg.zig`.
//!
//! The same socket answers requests (`core/control.zig`): a `status` line gets
//! one line of JSON back with the window's project, branch and agent state.
//! That's how `roost status` and the desktop bar see every window. The
//! `scratch-read` and `scratch-append` requests are `roost scratch`, which lets
//! the agent read and add to the Scratchpad.
//!
//! Hook names feed `claude_hooks.Liveness`: when the hooks that do run say one
//! that's installed never has, the server warns once with a notification.
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
const Project = @import("project.zig").Project;
const hook_msg = @import("core/hook_msg.zig");
const claude_hooks = @import("core/claude_hooks.zig");
const control = @import("core/control.zig");
const git_head = @import("core/git_head.zig");

const log = std.log.scoped(.roost_ipc);

/// Map a hook event to the tree/workspace badge status.
/// The badge an event sets; null for one that leaves the badge alone.
fn statusOf(event: hook_msg.Event) ?layout.AgentStatus {
    return switch (event) {
        .working => .working,
        .needs_input => .needs_input,
        .done => .done,
        .session => null,
    };
}

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
    /// The window's current project, for naming the window in notifications.
    /// A POINTER to the live `AppContext.current` (not a copied name) so a
    /// project switch re-points the notifications with it — the field is
    /// reassigned in place, so this never goes stale.
    ///
    /// Null until `run` wires it: the server is initialized before the
    /// AppContext exists, and a notification without a name is better than no
    /// notification, so this stays optional rather than a required init arg.
    project: ?*const Project = null,
    /// Scratch for composing the prefixed notification title. A field, not a
    /// local: `titled` returns a slice of it, which would dangle if it lived in
    /// that function's frame. Only ever touched on the main loop (GLib delivers
    /// socket reads there), so a single shared buffer is safe.
    title_buf: [512]u8 = undefined,
    /// Which Claude Code hooks have reached this window. Settings shows it.
    liveness: claude_hooks.Liveness = .{},
    /// Set once the hooks-look-wrong notification has been shown, so it shows
    /// once per window rather than on every hook after.
    warned_hooks: bool = false,
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
        // The newest message format this build parses (see core/hook_msg.zig).
        // roost-notify only adds its newer fields when this says it may.
        _ = internal_os.setenv("ROOST_PROTOCOL", "3");

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
    /// owns the buffers until the whole line has arrived.
    /// align(8): the read binding wants `*[*]u8`, so the buffer must be
    /// pointer-aligned (the value we pass IS C's buffer address — see below).
    const ReadCtx = struct {
        server: *Server,
        connection: *gio.SocketConnection,
        /// One read's worth.
        buf: [4096]u8 align(8),
        /// The line so far. A scratchpad append can take many reads.
        line: std.ArrayListUnmanaged(u8) = .empty,

        /// Ask for the next chunk; `onReadComplete` runs when it's in.
        fn readMore(ctx: *ReadCtx) void {
            const istream = ctx.connection.as(gio.IOStream).getInputStream();
            // The binding types g_input_stream_read_async's `void* buffer` as
            // `*[*]u8`; the pointer VALUE we pass is C's buffer address, so we
            // hand it a `*[*]u8` whose value is &ctx.buf, i.e. @ptrCast(&ctx.buf).
            istream.readAsync(@ptrCast(&ctx.buf), ctx.buf.len, 0, null, onReadComplete, ctx);
        }

        /// Act on the line (when `use` is set), then drop the connection ref
        /// taken in `onIncoming` and free everything.
        fn finish(ctx: *ReadCtx, use: bool) void {
            const server = ctx.server;
            if (use) server.dispatch(ctx.connection, ctx.line.items);
            ctx.connection.as(gobject.Object).unref();
            ctx.line.deinit(server.alloc);
            server.alloc.destroy(ctx);
        }
    };

    /// `incoming` signal handler. Starts an ASYNCHRONOUS read of one line and
    /// returns TRUE immediately. A synchronous read here would block the GTK
    /// main loop until the client writes — so a process that connects to
    /// ROOST_SOCK (exported into every pane) but stalls before writing could
    /// freeze the whole UI. The reads are serviced off the loop in
    /// `onReadComplete`, which drops the connection once the line is in.
    fn onIncoming(
        _: *gio.SocketService,
        connection: *gio.SocketConnection,
        _: ?*gobject.Object,
        self: *Server,
    ) callconv(.c) c_int {
        const ctx = self.alloc.create(ReadCtx) catch return @intFromBool(true);
        ctx.* = .{ .server = self, .connection = connection, .buf = undefined };
        // Keep the connection alive across the async reads: the SocketService
        // drops its ref once we return TRUE. Released in ReadCtx.finish.
        _ = connection.as(gobject.Object).ref();
        ctx.readMore();
        return @intFromBool(true);
    }

    /// Async-read completion (main loop). The line ends at a newline, which a
    /// request sends so it can wait for the answer, or when the client closes,
    /// which is how a hook sends (roost-notify writes no newline).
    fn onReadComplete(_: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const ctx: *ReadCtx = @ptrCast(@alignCast(data.?));
        const istream = ctx.connection.as(gio.IOStream).getInputStream();
        var gerr: ?*glib.Error = null;
        defer if (gerr) |e| e.free();
        const n = istream.readFinish(res, &gerr);
        if (n < 0) return ctx.finish(false);
        if (n == 0) return ctx.finish(ctx.line.items.len > 0);

        const chunk = ctx.buf[0..@intCast(n)];
        const end = std.mem.indexOfScalar(u8, chunk, '\n');
        const part = chunk[0 .. end orelse chunk.len];
        if (ctx.line.items.len + part.len > control.Request.max_line) {
            log.debug("dropping an ipc line over {d} bytes", .{control.Request.max_line});
            return ctx.finish(false);
        }
        ctx.line.appendSlice(ctx.server.alloc, part) catch return ctx.finish(false);
        if (end != null) return ctx.finish(true);
        ctx.readMore();
    }

    /// The longest hook line acted on. Anything past it was cut off before
    /// requests could be long, and a notification body has to fit `notifyApp`.
    const max_hook_line = 1024;

    /// One line from a client: a request gets its answer on the same
    /// connection, and anything else is a hook message.
    fn dispatch(self: *Server, connection: *gio.SocketConnection, raw: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (control.Request.parse(arena.allocator(), line)) |req| return self.answer(connection, req);
        self.handle(std.mem.trimRight(u8, line[0..@min(line.len, max_hook_line)], " \t\r"));
    }

    /// Heap context for an in-flight async reply: keeps the connection alive
    /// and owns the reply until the write completes.
    const WriteCtx = struct {
        server: *Server,
        connection: *gio.SocketConnection,
        reply: []u8,
    };

    /// Answer a control request on its own connection, then close it. The
    /// write is asynchronous for the same reason the read is: a client that
    /// asks and never reads must not stall the window.
    fn answer(self: *Server, connection: *gio.SocketConnection, req: control.Request) void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        self.reply(req, &out.writer) catch return;
        const ctx = self.alloc.create(WriteCtx) catch return;
        ctx.* = .{
            .server = self,
            .connection = connection,
            .reply = out.toOwnedSlice() catch {
                self.alloc.destroy(ctx);
                return;
            },
        };
        // Released in onWriteComplete, like the read's ref.
        _ = connection.as(gobject.Object).ref();
        const ostream = connection.as(gio.IOStream).getOutputStream();
        ostream.writeAllAsync(ctx.reply.ptr, ctx.reply.len, 0, null, onWriteComplete, ctx);
    }

    fn onWriteComplete(_: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const ctx: *WriteCtx = @ptrCast(@alignCast(data.?));
        defer {
            ctx.connection.as(gobject.Object).unref();
            ctx.server.alloc.free(ctx.reply);
            ctx.server.alloc.destroy(ctx);
        }
        const ostream = ctx.connection.as(gio.IOStream).getOutputStream();
        var gerr: ?*glib.Error = null;
        defer if (gerr) |e| e.free();
        // A client that hung up early is its own business; nothing to undo.
        _ = ostream.writeAllFinish(res, null, &gerr);
    }

    /// Carry out `req` and write its answer line.
    fn reply(self: *Server, req: control.Request, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const no_pad: control.Reply = .{ .@"error" = "This Roost window has no Scratchpad pane. Add one with Ctrl+Shift+N." };
        switch (req) {
            .status => {
                var branch_buf: [256]u8 = undefined;
                try self.statusReply(&branch_buf).write(w);
            },
            .scratch_read => {
                const pad = self.workspace.scratchpad() orelse return no_pad.write(w);
                const text = pad.readText(self.alloc) orelse
                    return (control.Reply{ .@"error" = "Roost ran out of memory reading the scratchpad." }).write(w);
                defer self.alloc.free(text);
                try (control.Reply{ .text = text }).write(w);
            },
            .scratch_append => |text| {
                const pad = self.workspace.scratchpad() orelse return no_pad.write(w);
                pad.appendBlock(text);
                try (control.Reply{ .ok = true }).write(w);
            },
            .agent_note => try (control.Reply{ .text = control.agent_note }).write(w),
            .invalid => |why| try (control.Reply{ .@"error" = why }).write(w),
        }
    }

    /// This window's answer to `status`. The branch lives in `branch_buf`.
    fn statusReply(self: *Server, branch_buf: []u8) control.Status {
        const proj = self.project;
        return .{
            .pid = std.os.linux.getpid(),
            .project = if (proj) |p| p.path else "",
            .name = if (proj) |p| p.displayName() else "",
            .branch = if (proj) |p| git_head.branch(branch_buf, p.path) orelse "" else "",
            .state = switch (self.workspace.agentAttention()) {
                .blocked => .needs_input,
                .done => .done,
                .working => .working,
                .idle => .idle,
                .unknown => .unknown,
            },
        };
    }

    /// Parse + act on one message line. Public for direct unit-style exercise.
    pub fn handle(self: *Server, line: []const u8) void {
        const msg = hook_msg.parse(line) orelse {
            if (line.len > 0) log.debug("ignoring unrecognized ipc message ({d} bytes)", .{line.len});
            return;
        };
        const rest = msg.text;

        log.info("agent event: {s} pane={?d} hook={s}{s}{s}", .{
            @tagName(msg.event),
            msg.pane,
            msg.hook,
            if (rest.len > 0) " — " else "",
            rest,
        });
        if (msg.hook.len > 0) {
            self.liveness.record(msg.hook);
            if (self.liveness.silent()) |i| {
                var buf: [256]u8 = undefined;
                const body = std.fmt.bufPrint(&buf, "Claude Code's {s} hook hasn't run, though its other hooks have. A Claude Code update may have changed it. See Settings → Claude Code hooks.", .{claude_hooks.required[i].event}) catch "";
                self.warnHooks("Claude Code hook not running", body);
            }
        }

        // Update the sender's Agent-pane badge for every event that sets one.
        if (statusOf(msg.event)) |status| self.workspace.setAgentStatus(msg.pane, status);
        if (msg.session.len > 0) self.workspace.setAgentSession(msg.pane, msg.session);

        // Notify (+ optional sound) for the attention-worthy events only. An
        // agent in a Shell pane gets no badge, but still gets its popup.
        switch (msg.event) {
            .working, .session => {},
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

    /// Say once per window that the Claude Code hooks look wrong. Its own
    /// notification id, so it never replaces an agent's popup.
    pub fn warnHooks(self: *Server, title: [:0]const u8, body: []const u8) void {
        if (self.warned_hooks) return;
        self.warned_hooks = true;
        log.warn("{s}: {s}", .{ title, body });
        notifyApp(self.app.as(gio.Application), "roost-hooks", self.titled(title), body);
    }

    /// Raise a native desktop notification. Mirrors Ghostty's own
    /// `Application.desktopNotification` (application.zig): build a
    /// `gio.Notification`, set body + themed icon, send via the GApplication.
    /// Delegates to the shared `notifyApp` (the wired-actions runner uses it too)
    /// with the stable id "roost-agent" so a newer agent event REPLACES the old.
    /// The id is per PROCESS, so this never reaches another window's popup: gio's
    /// freedesktop backend remembers which daemon notification each id produced
    /// in this process only, and every Roost window is its own process. (Checked
    /// against GLib 2.90 with two processes sharing the id: the second one's
    /// first Notify went out with replaces_id=0.)
    ///
    /// The title is prefixed with the project name ("roost — Agent needs you"),
    /// because the popup is the one place Roost speaks to you with no window
    /// attached: with several Roost windows open, "Agent needs you" alone can't
    /// tell you WHICH agent, and the sound can't either (it encodes the event,
    /// not the project). Name first so it survives a daemon's title truncation.
    fn notify(self: *Server, title: [:0]const u8, body: []const u8) void {
        notifyApp(self.app.as(gio.Application), "roost-agent", self.titled(title), body);
    }

    /// `"<project> — <title>"`, or `title` unchanged when there's no usable
    /// name — an unwired project pointer, or the empty-path sentinel Project
    /// that stands in when resolution failed. Falls back to `title` on overflow
    /// too: a plain notification beats a truncated one, and beats none at all.
    ///
    /// Returns a slice of `self.title_buf` (not the stack) so the result stays
    /// alive for the caller's `notifyApp` — gio copies the title out of it
    /// during that call, and nothing retains it after.
    fn titled(self: *Server, title: [:0]const u8) [:0]const u8 {
        const p = self.project orelse return title;
        const name = p.displayName();
        if (name.len == 0) return title;
        return std.fmt.bufPrintZ(&self.title_buf, "{s} — {s}", .{ name, title }) catch title;
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
