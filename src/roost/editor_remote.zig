//! `roost open`: show a file at a line in the Editor pane's Neovim.
//!
//! The Editor pane's Neovim listens on an address the tree gave it (see
//! `tree.NvimAddr`). This runs `nvim --server <addr> --remote-expr <expr>`
//! with the expression from `core/nvim.zig`, and answers the client when
//! Neovim has moved. The run is asynchronous and has a time limit, so a
//! Neovim stuck on a prompt never blocks the window or the caller.
//!
//! It doesn't focus the Editor pane: the user may be typing to the agent.

const std = @import("std");

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");

const ipc = @import("ipc.zig");
const tree = @import("tree.zig");
const control = @import("core/control.zig");
const nvim = @import("core/nvim.zig");

const log = std.log.scoped(.roost_editor);

/// How long Neovim gets to answer. A prompt it's waiting on (a swap-file
/// warning, say) can hold it up.
const timeout_ms: c_uint = 5000;

/// One `nvim --server` run, until it ends or times out.
const Job = struct {
    alloc: std.mem.Allocator,
    proc: *gio.Subprocess,
    reply: *ipc.Server.Pending,
    /// The time-limit source, 0 once it has fired or been removed.
    timer: c_uint = 0,
    timed_out: bool = false,
};

/// Show `o.path` at its line in the Editor pane, then finish `reply`.
pub fn open(alloc: std.mem.Allocator, link: tree.Tree.EditorLink, o: control.Request.Open, reply: *ipc.Server.Pending) void {
    const addr = switch (link) {
        .none => return reply.finish(.{ .@"error" = "This window has no Editor pane. Add one with Ctrl+Shift+E, then try again." }),
        .not_neovim => return reply.finish(.{ .@"error" = "The Editor pane isn't running Neovim, so Roost can't move it. roost open works only with Neovim." }),
        .addr => |x| x,
    };

    const expr = nvim.openExpr(alloc, o.path, o.line, o.col) catch
        return reply.finish(.{ .@"error" = "That path can't be passed to Neovim." });
    defer alloc.free(expr);
    const prog = alloc.dupeZ(u8, nvim.program(tree.editorCommand())) catch return reply.finish(oom);
    defer alloc.free(prog);
    const addr_z = alloc.dupeZ(u8, addr) catch return reply.finish(oom);
    defer alloc.free(addr_z);
    const expr_z = alloc.dupeZ(u8, expr) catch return reply.finish(oom);
    defer alloc.free(expr_z);

    const argv = [_:null]?[*:0]const u8{ prog.ptr, "--server", addr_z.ptr, "--remote-expr", expr_z.ptr };
    var gerr: ?*glib.Error = null;
    const proc = gio.Subprocess.newv(@ptrCast(&argv), .{ .stdout_silence = true, .stderr_pipe = true }, &gerr) orelse {
        defer if (gerr) |e| e.free();
        const why: []const u8 = if (gerr) |e| std.mem.span(e.f_message orelse "unknown error") else "unknown error";
        log.warn("could not run {s} --server: {s}", .{ prog, why });
        return reply.finish(.{ .@"error" = "Roost couldn't run Neovim to move the Editor pane." });
    };

    const job = alloc.create(Job) catch {
        proc.forceExit();
        proc.unref();
        return reply.finish(oom);
    };
    job.* = .{ .alloc = alloc, .proc = proc, .reply = reply };
    job.timer = glib.timeoutAdd(timeout_ms, onTimeout, job);
    proc.communicateUtf8Async(null, null, onDone, job);
    log.debug("open {s}:{d}:{d} via {s}", .{ o.path, o.line, o.col, addr });
}

const oom: control.Reply = .{ .@"error" = "Roost ran out of memory." };

fn onTimeout(data: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(data orelse return 0));
    job.timer = 0;
    job.timed_out = true;
    // Ends the run, so `onDone` reports the timeout.
    job.proc.forceExit();
    return 0;
}

fn onDone(_: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data orelse return));
    defer {
        if (job.timer != 0) _ = glib.Source.remove(job.timer);
        job.proc.unref();
        job.alloc.destroy(job);
    }

    var errs: ?[*:0]u8 = null;
    var gerr: ?*glib.Error = null;
    const ok = job.proc.communicateUtf8Finish(res, null, @ptrCast(&errs), &gerr);
    defer if (errs) |e| glib.free(e);
    defer if (gerr) |e| e.free();

    if (job.timed_out)
        return job.reply.finish(.{ .@"error" = "Neovim in the Editor pane didn't answer. It may be waiting on a prompt there." });
    if (ok != 0 and job.proc.getIfExited() != 0 and job.proc.getExitStatus() == 0)
        return job.reply.finish(.{ .ok = true });

    const stderr: []const u8 = if (errs) |e| std.mem.span(e) else "";
    log.debug("nvim --server failed: {s}", .{stderr});
    if (std.mem.indexOf(u8, stderr, "Failed to connect") != null)
        return job.reply.finish(.{ .@"error" = "Neovim in the Editor pane isn't answering. Reload the window (Ctrl+Shift+Q) to restart it." });
    var buf: [512]u8 = undefined;
    const line = nvim.errorLine(stderr);
    const why = std.fmt.bufPrint(&buf, "Neovim said: {s}", .{if (line.len > 0) line else "it couldn't open the file."}) catch "Neovim couldn't open the file.";
    job.reply.finish(.{ .@"error" = why });
}
