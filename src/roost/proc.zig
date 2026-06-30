//! Shared subprocess runner — spawn an argv, capture stdout+stderr + exit code.
//!
//! ADDITIVE: our own file. Extracted from `git.zig`'s proven blueprint-compiler
//! invocation (spawn -> collectOutput -> wait) so the git helpers AND the
//! wired-actions runner share one implementation. `run` BLOCKS until the child
//! exits; callers that must not stall the GTK main loop (actions) run it on a
//! worker thread and marshal the result back via `glib.idleAdd`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.roost_proc);

/// Captured result of a finished child process. `stdout`/`stderr` are owned by
/// the caller's allocator.
pub const Output = struct {
    /// Process exit code; non-`Exited` termination (signal/stopped) maps to 1.
    code: u8,
    stdout: []u8,
    stderr: []u8,

    /// Free both captured buffers with the allocator they were produced by.
    pub fn deinit(self: *const Output, alloc: Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

/// Run `argv` to completion in `cwd` (null = inherit the caller's cwd), capturing
/// stdout+stderr (both owned by `alloc`). Returns an error only if the process
/// could not be spawned or its pipes could not be read.
pub fn run(alloc: Allocator, argv: []const []const u8, cwd: ?[]const u8) !Output {
    var child = std.process.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;

    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stdout.deinit(alloc);
    var stderr: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stderr.deinit(alloc);

    try child.spawn();
    // Reap the child on any failure between here and wait(): collectOutput can
    // error (StreamTooLong on >1MiB, or a pipe read failure) and would otherwise
    // leak the child's two pipe fds + a zombie. Mirrors std's own Child.run.
    errdefer _ = child.kill() catch {};
    // collectOutput must precede wait(): it drains the pipes the child writes.
    try child.collectOutput(alloc, &stdout, &stderr, 1024 * 1024);
    const term = try child.wait();

    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };
    // Bind the first owned slice to a local with its own errdefer: toOwnedSlice
    // empties the ArrayList (so the `stdout.deinit` errdefer above no longer frees
    // anything), and if the *second* toOwnedSlice then OOMs, this slice would
    // otherwise leak with no owner.
    const out = try stdout.toOwnedSlice(alloc);
    errdefer alloc.free(out);
    const err = try stderr.toOwnedSlice(alloc);
    return .{ .code = code, .stdout = out, .stderr = err };
}
