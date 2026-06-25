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

    /// `incoming` signal handler. Reads one short message off the connection,
    /// parses it, reacts, and returns TRUE (handled). Per the
    /// gio.SocketService contract, returning TRUE stops further emission for
    /// this connection; the connection is dropped when our last ref goes away
    /// at the end of this callback.
    fn onIncoming(
        _: *gio.SocketService,
        connection: *gio.SocketConnection,
        _: ?*gobject.Object,
        self: *Server,
    ) callconv(.c) c_int {
        // align(8): the read() binding wants `*[*]u8` (pointer alignment), so
        // the buffer we @ptrCast to it must be pointer-aligned.
        var buf: [1024]u8 align(8) = undefined;
        const istream = connection.as(gio.IOStream).getInputStream();

        var gerr: ?*glib.Error = null;
        // The zig-gobject binding types g_input_stream_read's `void* buffer` as
        // `*[*]u8`. At the ABI level the pointer VALUE we pass IS C's buffer
        // address, so we hand it a `*[*]u8` whose value is &buf — i.e.
        // @ptrCast(&buf). (The original `&buf_ptr` pointed at a pointer variable,
        // so the read landed there and left `buf` uninitialized → garbage.)
        const n = istream.read(@ptrCast(&buf), buf.len, null, &gerr);
        defer if (gerr) |e| e.free();
        if (n <= 0) {
            // EOF or error: nothing usable. Either way we're done with it.
            return @intFromBool(true);
        }

        const msg = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
        self.handle(msg);
        return @intFromBool(true);
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

        // Notify for the attention-worthy events only.
        switch (event) {
            .working => {},
            .needs_input => self.notify("Agent needs you", if (rest.len > 0) rest else "Your agent is waiting for input."),
            .done => self.notify("Agent finished", if (rest.len > 0) rest else "Your agent finished its task."),
        }
    }

    /// Raise a native desktop notification. Mirrors Ghostty's own
    /// `Application.desktopNotification` (application.zig): build a
    /// `gio.Notification`, set body + themed icon, send via the GApplication.
    fn notify(self: *Server, title: [:0]const u8, body: []const u8) void {
        // `gio.Notification.setBody` wants a NUL-terminated string; `body` is a
        // slice into our read buffer, so copy it NUL-terminated on the stack.
        var body_buf: [1024]u8 = undefined;
        const body_z = std.fmt.bufPrintZ(&body_buf, "{s}", .{body}) catch body_buf[0..0 :0];

        const notification = gio.Notification.new(title);
        defer notification.unref();
        notification.setBody(body_z);

        // Use Ghostty's app icon; falls back gracefully if the theme lacks it.
        const icon = gio.ThemedIcon.new("dev.scottzirkel.Roost");
        defer icon.unref();
        notification.setIcon(icon.as(gio.Icon));

        const gio_app = self.app.as(gio.Application);
        // Stable id "roost-agent" so a newer notification REPLACES the old one
        // in the shell rather than stacking.
        gio_app.sendNotification("roost-agent", notification);
    }
};

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
