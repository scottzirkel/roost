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
//!     roost output <pane|action>   the end of a pane's screen or an action's output
//!     roost run                    list this window's wired actions
//!     roost run <action> [--wait]  run one, and with --wait report how it went
//!     roost open <file>[:line[:col]] show a file in the Editor pane
//!     roost close --all            close every window, saving them for reopen
//!     roost reopen                 bring back the windows close --all closed
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
const resume_core = @import("core/resume.zig");
const hypr = @import("hypr.zig");

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

const output_usage =
    \\usage: roost output <pane or action> [-n LINES]
    \\
    \\Prints the end of a pane's screen, or of a wired action's output, from
    \\the Roost window this pane is in.
    \\
    \\  <pane>    agent, shell, git or editor: the first pane of that kind.
    \\            Or a pane's number, counted like Alt+1...9.
    \\  <action>  a wired action's label, such as "Run tests": its latest run
    \\  -n LINES  how many lines from the end (default 50)
    \\
;

const run_usage =
    \\usage: roost run                     list the window's wired actions
    \\       roost run <action> [--wait]   run one, by its label
    \\
    \\Runs one of the wired actions of the Roost window this pane is in, such
    \\as "Run tests". It never runs anything that isn't an action.
    \\
    \\  --wait  wait for it to finish, print its output, and exit with its
    \\          exit code. The output comes here instead of going where the
    \\          action's routes send it.
    \\
    \\Without --wait, it starts the action and returns at once, and the output
    \\goes where the action's routes send it.
    \\
;

const open_usage =
    \\usage: roost open <file>[:<line>[:<column>]]
    \\
    \\Shows a file in the Editor pane of the Roost window this pane is in, at
    \\the line and column if you give them. The Editor pane has to be running
    \\Neovim.
    \\
;

const close_usage =
    \\usage: roost close --all [--yes]
    \\
    \\Closes every Roost window, after asking. Each window saves its layout
    \\and its Claude conversations as it closes, and the list of projects is
    \\saved, so `roost reopen` brings them all back.
    \\
    \\  --yes  don't ask first (needed when there's no terminal to ask in)
    \\
;

const reopen_usage =
    \\usage: roost reopen
    \\
    \\Opens a window for each project `roost close --all` last closed, and
    \\resumes each window's Claude conversations without asking. Projects
    \\that already have a window are skipped.
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
/// The same for `roost open`, which waits for Neovim to move.
const open_timeout_ms = 8000;
/// No limit: `roost run --wait` waits as long as the action runs.
const no_timeout = 0;
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
    const words = [_][]const u8{ "status", "scratch", "output", "run", "open", "close", "reopen" };
    for (words) |w| if (std.mem.eql(u8, word, w)) return true;
    return false;
}

/// Run `args` (argv without the program name), printing to stdout and stderr.
pub fn run(args: []const [:0]const u8) u8 {
    var out_buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.fs.File.stderr().writer(&err_buf);
    defer err.interface.flush() catch {};
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmd = args[0];
    const rest = args[1..];
    const code = if (std.mem.eql(u8, cmd, "scratch")) code: {
        const stdin = std.fs.File.stdin();
        var in_buf: [4096]u8 = undefined;
        var in = stdin.reader(&in_buf);
        const piped = if (stdin.isTty()) null else &in.interface;
        break :code scratch(a, rest, paneSocket(), piped, &out.interface, &err.interface);
    } else if (std.mem.eql(u8, cmd, "output"))
        output(a, rest, paneSocket(), &out.interface, &err.interface)
    else if (std.mem.eql(u8, cmd, "run"))
        runAction(a, rest, paneSocket(), &out.interface, &err.interface)
    else if (std.mem.eql(u8, cmd, "open"))
        open(a, rest, paneSocket(), cwdOrRoot(a), &out.interface, &err.interface)
    else if (std.mem.eql(u8, cmd, "close")) code: {
        const stdin = std.fs.File.stdin();
        var in_buf: [256]u8 = undefined;
        var in = stdin.reader(&in_buf);
        const tty = if (stdin.isTty()) &in.interface else null;
        const where: ?*const fn (std.mem.Allocator) hypr.Workspaces = if (hypr.available()) hypr.roostWorkspaces else null;
        break :code closeAll(a, rest, socketDir(), paneSocket(), closedFile(a), tty, &out.interface, &err.interface, pidGone, where);
    } else if (std.mem.eql(u8, cmd, "reopen"))
        reopen(a, rest, socketDir(), closedFile(a), &out.interface, &err.interface, launchWindow, if (hypr.available()) hypr_placer else null)
    else
        status(rest, &out.interface, &err.interface);
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

/// Send `req` to the window at `sock` and read its reply. Says what went
/// wrong on `err`, as `roost <name>: ...`, and returns null when there's no
/// usable reply, including when the window answered with an error.
fn askWindow(
    a: std.mem.Allocator,
    name: []const u8,
    sock: ?[]const u8,
    req: control.Request,
    timeout_ms: u32,
    err: *std.Io.Writer,
) ?control.Reply {
    const path = sock orelse {
        err.print("roost {s}: not in a Roost pane, so there's no window to ask.\n", .{name}) catch {};
        return null;
    };
    var line: std.Io.Writer.Allocating = .init(a);
    req.write(&line.writer) catch return null;
    const raw = ask(a, path, line.written(), timeout_ms) catch |e| switch (e) {
        error.NoWindow => {
            err.print("roost {s}: no window answers at {s}\n", .{ name, path }) catch {};
            return null;
        },
        else => "",
    };
    const reply_line = std.mem.trim(u8, raw, " \t\r\n");
    const reply = if (reply_line.len == 0) null else control.Reply.parse(a, reply_line) catch null;
    const r = reply orelse {
        if (req == .run and req.run.wait)
            err.print("roost {s}: the window closed before the action finished, or it's an older Roost build that needs a reload.\n", .{name}) catch {}
        else
            err.print("roost {s}: the window didn't answer. If it's an older Roost build, reload it to update.\n", .{name}) catch {};
        return null;
    };
    if (r.@"error") |why| {
        err.print("roost {s}: {s}\n", .{ name, why }) catch {};
        return null;
    }
    return r;
}

/// Write `text`, ending it with a newline.
fn writeLine(out: *std.Io.Writer, text: []const u8) !void {
    if (text.len == 0) return;
    try out.writeAll(text);
    if (text[text.len - 1] != '\n') try out.writeByte('\n');
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// `roost output <pane or action> [-n LINES]`. The target's words are joined,
/// so `roost output Run tests` works without quotes.
fn output(
    a: std.mem.Allocator,
    args: []const [:0]const u8,
    sock: ?[]const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) u8 {
    var lines: u32 = control.Request.Output.default_lines;
    var words: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelp(arg)) {
            out.writeAll(output_usage) catch {};
            return 0;
        }
        const value: ?[]const u8 = if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--lines")) v: {
            i += 1;
            break :v if (i < args.len) args[i] else "";
        } else if (std.mem.startsWith(u8, arg, "--lines="))
            arg["--lines=".len..]
        else
            null;
        if (value) |v| {
            lines = std.fmt.parseInt(u32, v, 10) catch {
                err.print("roost output: '{s}' isn't a number of lines.\n\n", .{v}) catch {};
                err.writeAll(output_usage) catch {};
                return 2;
            };
            continue;
        }
        words.append(a, arg) catch return 1;
    }
    const target = std.mem.join(a, " ", words.items) catch return 1;
    if (target.len == 0) {
        err.writeAll("roost output: say which pane or action.\n\n") catch {};
        err.writeAll(output_usage) catch {};
        return 2;
    }
    const r = askWindow(a, "output", sock, .{ .output = .{ .target = target, .lines = lines } }, scratch_timeout_ms, err) orelse return 1;
    if (r.running orelse false)
        err.print("roost output: \"{s}\" is still running. This is its output so far.\n", .{target}) catch {}
    else if (r.stopped orelse false)
        err.print("roost output: \"{s}\" was stopped before it finished.\n", .{target}) catch {}
    else if (r.code) |c|
        err.print("roost output: \"{s}\" {s} (exit {d}).\n", .{ target, if (c == 0) "passed" else "failed", c }) catch {};
    writeLine(out, r.text orelse "") catch return 1;
    return 0;
}

/// `roost run [<action> [--wait]]`. With no action, lists them.
fn runAction(
    a: std.mem.Allocator,
    args: []const [:0]const u8,
    sock: ?[]const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) u8 {
    var wait = false;
    var words: std.ArrayListUnmanaged([]const u8) = .empty;
    for (args) |arg| {
        if (isHelp(arg)) {
            out.writeAll(run_usage) catch {};
            return 0;
        } else if (std.mem.eql(u8, arg, "--wait")) {
            wait = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            err.print("roost run: unknown option '{s}'\n\n", .{arg}) catch {};
            err.writeAll(run_usage) catch {};
            return 2;
        } else {
            words.append(a, arg) catch return 1;
        }
    }
    const label = std.mem.join(a, " ", words.items) catch return 1;

    if (label.len == 0) {
        if (wait) {
            err.writeAll("roost run: say which action to wait for.\n\n") catch {};
            err.writeAll(run_usage) catch {};
            return 2;
        }
        const r = askWindow(a, "run", sock, .actions, answer_timeout_ms * 4, err) orelse return 1;
        const labels = r.labels orelse &.{};
        if (labels.len == 0) {
            out.writeAll("This window has no wired actions. Define them in .roost/actions.json in the project, or in ~/.config/roost/actions.json.\n") catch return 1;
            return 0;
        }
        for (labels) |l| out.print("{s}\n", .{l}) catch return 1;
        return 0;
    }

    const r = askWindow(a, "run", sock, .{ .run = .{ .label = label, .wait = wait } }, if (wait) no_timeout else answer_timeout_ms * 4, err) orelse return 1;
    if (!wait) {
        err.print("roost run: started \"{s}\".\n", .{label}) catch {};
        return 0;
    }
    writeLine(out, r.text orelse "") catch return 1;
    if (r.stopped orelse false) {
        err.print("roost run: \"{s}\" was stopped from the window before it finished.\n", .{label}) catch {};
        return r.code orelse 1;
    }
    const code = r.code orelse {
        err.print("roost run: \"{s}\" ended without an exit code.\n", .{label}) catch {};
        return 1;
    };
    if (code != 0) err.print("roost run: \"{s}\" failed (exit {d}).\n", .{ label, code }) catch {};
    return code;
}

/// `roost open <file>[:line[:col]]`. Relative paths are resolved against
/// `cwd`, the caller's directory, since the window may be somewhere else.
fn open(
    a: std.mem.Allocator,
    args: []const [:0]const u8,
    sock: ?[]const u8,
    cwd: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) u8 {
    if (args.len == 1 and isHelp(args[0])) {
        out.writeAll(open_usage) catch {};
        return 0;
    }
    if (args.len != 1) {
        err.writeAll(if (args.len == 0) "roost open: say which file.\n\n" else "roost open: give one file.\n\n") catch {};
        err.writeAll(open_usage) catch {};
        return 2;
    }
    const arg: []const u8 = args[0];
    var loc = control.Location.parse(arg);
    var path = std.fs.path.resolve(a, &.{ cwd, loc.path }) catch return 1;
    if (!exists(path)) {
        // A name that really has ":12" in it.
        const whole = std.fs.path.resolve(a, &.{ cwd, arg }) catch return 1;
        if (!exists(whole)) {
            err.print("roost open: there's no file at {s}\n", .{path}) catch {};
            return 1;
        }
        path = whole;
        loc = .{ .path = arg };
    }
    _ = askWindow(a, "open", sock, .{ .open = .{ .path = path, .line = loc.line, .col = loc.col } }, open_timeout_ms, err) orelse return 1;
    return 0;
}

fn exists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

/// The caller's directory, or `/` when it's gone.
fn cwdOrRoot(a: std.mem.Allocator) []const u8 {
    return std.process.getCwdAlloc(a) catch "/";
}

/// Where `roost close --all` keeps the projects it closed.
fn closedFile(a: std.mem.Allocator) ?[]const u8 {
    return resume_core.closedPath(a, posix.getenv("XDG_STATE_HOME"), posix.getenv("HOME"));
}

/// True once `pid` has exited.
fn pidGone(pid: i32) bool {
    posix.kill(pid, 0) catch |e| return e == error.ProcessNotFound;
    return false;
}

/// How long a window gets to close before it's reported as still open.
const close_wait_ms = 5000;

/// `roost close --all [--yes]`. Asks on `tty` (null when stdin isn't a
/// terminal, which then needs --yes), saves the projects to `closed_file`,
/// and closes every window, the caller's own (`own_sock`) last, since closing
/// it ends this process too. `gone` says when a window's process has exited.
fn closeAll(
    a: std.mem.Allocator,
    args: []const [:0]const u8,
    dir: []const u8,
    own_sock: ?[]const u8,
    closed_file: ?[]const u8,
    tty: ?*std.Io.Reader,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    gone: *const fn (i32) bool,
    /// Each window's workspace, when the desktop can say (Hyprland).
    where: ?*const fn (std.mem.Allocator) hypr.Workspaces,
) u8 {
    var all = false;
    var yes = false;
    for (args) |arg| {
        if (isHelp(arg)) {
            out.writeAll(close_usage) catch {};
            return 0;
        } else if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            yes = true;
        } else {
            err.print("roost close: unknown option '{s}'\n\n", .{arg}) catch {};
            err.writeAll(close_usage) catch {};
            return 2;
        }
    }
    if (!all) {
        err.writeAll("roost close: say --all. It closes every Roost window.\n\n") catch {};
        err.writeAll(close_usage) catch {};
        return 2;
    }

    const windows = collect(a, dir) catch return 1;
    if (windows.len == 0) {
        out.writeAll("No Roost windows are running.\n") catch {};
        return 0;
    }
    if (!yes) {
        const in = tty orelse {
            err.writeAll("roost close: there's no terminal to ask in. Add --yes to close every window without asking.\n") catch {};
            return 2;
        };
        writeTexts(out, windows) catch {};
        out.print("Close {s}? roost reopen brings {s} back, with {s} conversations. [y/N] ", .{
            if (windows.len == 1) "this window" else "these windows",
            if (windows.len == 1) "it" else "them",
            if (windows.len == 1) "its" else "their",
        }) catch {};
        out.flush() catch {};
        const answer = in.takeDelimiter('\n') catch null;
        const yes_answer = if (answer) |line| std.ascii.startsWithIgnoreCase(std.mem.trim(u8, line, " \t\r"), "y") else false;
        if (!yes_answer) {
            out.writeAll("Nothing closed.\n") catch {};
            return 1;
        }
    }

    // Save the list first: closing our own window ends this process.
    const workspaces: hypr.Workspaces = if (where) |f| f(a) else .empty;
    var saved: std.ArrayListUnmanaged(resume_core.Closed.Window) = .empty;
    for (windows) |w| {
        if (w.project.len == 0) continue;
        saved.append(a, .{ .project = w.project, .workspace = workspaces.get(w.pid) orelse "" }) catch return 1;
    }
    if (closed_file) |path| saveClosed(a, path, saved.items) catch |e| {
        err.print("roost close: couldn't save the list of windows to {s} ({s}), so nothing was closed.\n", .{ path, @errorName(e) }) catch {};
        return 1;
    };

    const own_pid: ?i32 = if (own_sock) |p| control.socketPid(std.fs.path.basename(p)) else null;
    var closed: usize = 0;
    var stuck: std.ArrayListUnmanaged(control.Status) = .empty;
    var own: ?control.Status = null;
    for (windows) |w| {
        if (own_pid != null and w.pid == own_pid.?) {
            own = w;
            continue;
        }
        if (closeOne(a, dir, w.pid, gone)) closed += 1 else stuck.append(a, w) catch {};
    }

    const total = closed + @intFromBool(own != null);
    out.print("Closing {d} Roost window{s}. Bring {s} back with roost reopen.\n", .{ total, if (total == 1) "" else "s", if (total == 1) "it" else "them" }) catch {};
    for (stuck.items) |w| {
        if (w.name.len > 0)
            err.print("roost close: {s} (window {d}) didn't close. If it's an older Roost build, reload it first, or close it by hand.\n", .{ w.name, w.pid }) catch {}
        else
            err.print("roost close: window {d} didn't close. It's an older Roost build: close it by hand.\n", .{w.pid}) catch {};
    }
    out.flush() catch {};
    err.flush() catch {};
    if (own) |w| _ = closeOne(a, dir, w.pid, gone);
    return if (stuck.items.len == 0) 0 else 1;
}

/// Ask window `pid` to close, and wait for it to go. True when it did.
fn closeOne(a: std.mem.Allocator, dir: []const u8, pid: i32, gone: *const fn (i32) bool) bool {
    const name = std.fmt.allocPrint(a, "roost-{d}.sock", .{pid}) catch return false;
    const path = std.fs.path.join(a, &.{ dir, name }) catch return false;
    // The window answers, then quits; or quits before its answer gets out.
    _ = ask(a, path, "close\n", answer_timeout_ms * 4) catch {};
    var waited: u32 = 0;
    while (waited < close_wait_ms) : (waited += 50) {
        if (gone(pid)) return true;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    return gone(pid);
}

fn saveClosed(a: std.mem.Allocator, path: []const u8, windows: []const resume_core.Closed.Window) !void {
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    var text: std.Io.Writer.Allocating = .init(a);
    try (resume_core.Closed{ .windows = windows }).write(&text.writer);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = text.written() });
}

/// Puts reopened windows back where they were. `before` runs ahead of
/// starting window `i`; `after` runs once all are started.
const Placer = struct {
    before: *const fn (a: std.mem.Allocator, i: usize, name: []const u8, workspace: []const u8) void,
    after: *const fn (a: std.mem.Allocator, dir: []const u8, placed: []const Placed) void,
};

/// A reopened window with a workspace to go back to.
const Placed = struct { index: usize, project: []const u8, workspace: []const u8 };

/// `roost reopen`: a window for each project in `closed_file` that doesn't
/// have one, started by `launch`, and put back on its workspace by `placer`
/// when there is one. The list is removed afterwards, so running it twice
/// doesn't double up.
fn reopen(
    a: std.mem.Allocator,
    args: []const [:0]const u8,
    dir: []const u8,
    closed_file: ?[]const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    launch: *const fn (std.mem.Allocator, []const u8) bool,
    placer: ?Placer,
) u8 {
    if (args.len > 0) {
        if (args.len == 1 and isHelp(args[0])) {
            out.writeAll(reopen_usage) catch {};
            return 0;
        }
        err.print("roost reopen: unknown option '{s}'\n\n", .{args[0]}) catch {};
        err.writeAll(reopen_usage) catch {};
        return 2;
    }
    const nothing = "Nothing to reopen. roost close --all saves the windows it closes.\n";
    const path = closed_file orelse {
        out.writeAll(nothing) catch {};
        return 1;
    };
    const text = std.fs.cwd().readFileAlloc(a, path, 1024 * 1024) catch {
        out.writeAll(nothing) catch {};
        return 1;
    };
    const list = resume_core.Closed.parse(a, text) catch {
        err.print("roost reopen: {s} isn't a list of windows. Remove it, and close windows with roost close --all.\n", .{path}) catch {};
        return 1;
    };

    const open_now = collect(a, dir) catch &.{};
    var opened: usize = 0;
    var failed = false;
    var placed: std.ArrayListUnmanaged(Placed) = .empty;
    for (list.windows, 0..) |win, i| {
        const project = win.project;
        const name = std.fs.path.basename(project);
        const already = for (open_now) |w| {
            if (std.mem.eql(u8, w.project, project)) break true;
        } else false;
        if (already) {
            out.print("  {s} is already open.\n", .{name}) catch {};
            continue;
        }
        if (!exists(project)) {
            err.print("roost reopen: {s} isn't there anymore, so it's skipped.\n", .{project}) catch {};
            continue;
        }
        const place = placer != null and win.workspace.len > 0;
        if (place) placer.?.before(a, i, name, win.workspace);
        if (launch(a, project)) {
            out.print("  Opened {s}.\n", .{name}) catch {};
            opened += 1;
            if (place) placed.append(a, .{ .index = i, .project = project, .workspace = win.workspace }) catch {};
        } else {
            err.print("roost reopen: couldn't open a window for {s}.\n", .{project}) catch {};
            failed = true;
        }
    }
    if (placer) |p| if (placed.items.len > 0) {
        out.flush() catch {};
        p.after(a, dir, placed.items);
    };
    if (!failed) std.fs.cwd().deleteFile(path) catch {};
    if (opened == 0 and !failed) out.writeAll("Every window was already open.\n") catch {};
    return if (failed) 1 else 0;
}

/// Hyprland's placer: a quiet rule per window before it starts, then a move
/// for any window the rule missed. See `hypr.zig`.
const hypr_placer: Placer = .{ .before = hyprBefore, .after = hyprAfter };

fn reopenRule(a: std.mem.Allocator, i: usize) []const u8 {
    return std.fmt.allocPrint(a, "roost-reopen-{d}", .{i}) catch "roost-reopen";
}

fn hyprBefore(a: std.mem.Allocator, i: usize, name: []const u8, workspace: []const u8) void {
    const expr = hypr.ruleExpr(a, reopenRule(a, i), name, workspace) orelse return;
    _ = hypr.eval(a, expr);
}

/// How long reopened windows get to show up before their rules go.
const reopen_wait_ms = 15_000;

fn hyprAfter(a: std.mem.Allocator, dir: []const u8, placed: []const Placed) void {
    // Wait for every placed window to answer, to learn its pid.
    var pids = a.alloc(i32, placed.len) catch return;
    @memset(pids, 0);
    var waited: u32 = 0;
    while (waited < reopen_wait_ms) : (waited += 250) {
        const now = collect(a, dir) catch &.{};
        var missing: usize = 0;
        for (placed, 0..) |p, k| {
            if (pids[k] != 0) continue;
            for (now) |w| if (std.mem.eql(u8, w.project, p.project)) {
                pids[k] = w.pid;
            };
            if (pids[k] == 0) missing += 1;
        }
        if (missing == 0) break;
        std.Thread.sleep(250 * std.time.ns_per_ms);
    }
    // Move any the rule missed: a title that didn't match, say.
    const where = hypr.roostWorkspaces(a);
    for (placed, pids) |p, pid| {
        if (pid == 0) continue;
        const at = where.get(pid) orelse continue;
        if (std.mem.eql(u8, at, p.workspace)) continue;
        if (hypr.moveExpr(a, pid, p.workspace)) |expr| _ = hypr.dispatch(a, expr);
    }
    for (placed) |p| if (hypr.disableExpr(a, reopenRule(a, p.index))) |expr| {
        _ = hypr.eval(a, expr);
    };
}

/// Start a detached Roost window for `project` that resumes its saved
/// conversations (ROOST_RESUME_SAVED). Like the window's own "open in a new
/// window": `setsid` in the background, so it outlives this command.
fn launchWindow(a: std.mem.Allocator, project: []const u8) bool {
    const exe = std.fs.selfExePathAlloc(a) catch return false;
    var env = std.process.getEnvMap(a) catch return false;
    env.put("ROOST_PROJECT", project) catch return false;
    env.put("ROOST_RESUME_SAVED", "1") catch return false;
    // This shell may be a pane of a window that's gone, or another window's:
    // the new window sets its own.
    inline for (.{ "ROOST_SOCK", "ROOST_PANE", "ROOST_PROTOCOL", "GIO_LAUNCHED_DESKTOP_FILE_PID" }) |k| env.remove(k);
    var child = std.process.Child.init(&.{
        "/bin/sh", "-c",
        "setsid \"$1\" --gtk-single-instance=false </dev/null >/dev/null 2>&1 &",
        "sh",      exe,
    }, a);
    child.env_map = &env;
    child.cwd = project;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return false;
    return term == .Exited and term.Exited == 0;
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
    try testing.expect(isCommand("output"));
    try testing.expect(isCommand("run"));
    try testing.expect(isCommand("open"));
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

/// Which new command `commandAgainst` runs.
const Cmd = enum { output, run, open };

/// Run `roost <cmd> args` against a fake window that wants `want` and answers
/// `reply`. `open` resolves paths against the fake window's temp directory,
/// where `file` (if any) is created first. `{dir}` in `want` stands for that
/// directory.
fn commandAgainst(
    cmd: Cmd,
    args: []const [:0]const u8,
    file: ?[]const u8,
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
    if (file) |f| try tmp.dir.writeFile(.{ .sub_path = f, .data = "x\n" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ dir, "roost-1.sock" });
    const fd = try listen(path);
    defer posix.close(fd);
    const wanted = try std.mem.replaceOwned(u8, a, want, "{dir}", dir);
    const t = try std.Thread.spawn(.{}, fakeWindow, .{ fd, wanted, reply });
    defer t.join();
    return switch (cmd) {
        .output => output(a, args, path, out, err),
        .run => runAction(a, args, path, out, err),
        .open => open(a, args, path, dir, out, err),
    };
}

test "output: the target's words, the line count, and what the window says" {
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    try testing.expectEqual(@as(u8, 0), try commandAgainst(.output, &.{ "-n", "5", "Run", "tests" }, null,
        \\output {"target":"Run tests","lines":5}
        \\
    , "{\"text\":\"FAIL x\",\"code\":1}\n", &out, &err));
    try testing.expectEqualStrings("FAIL x\n", out.buffered());
    try testing.expectEqualStrings("roost output: \"Run tests\" failed (exit 1).\n", err.buffered());

    out.end = 0;
    err.end = 0;
    try testing.expectEqual(@as(u8, 0), try commandAgainst(.output, &.{"shell"}, null,
        \\output {"target":"shell","lines":50}
        \\
    , "{\"text\":\"$ make\\nok\\n\"}\n", &out, &err));
    try testing.expectEqualStrings("$ make\nok\n", out.buffered());
    try testing.expectEqualStrings("", err.buffered());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    err.end = 0;
    try testing.expectEqual(@as(u8, 2), output(arena.allocator(), &.{}, "/nonexistent", &out, &err));
    try testing.expectEqual(@as(u8, 2), output(arena.allocator(), &.{ "shell", "-n", "lots" }, "/nonexistent", &out, &err));
}

test "run: lists actions, starts one, or waits and passes on its exit code" {
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try testing.expectEqual(@as(u8, 0), try commandAgainst(.run, &.{}, null, "actions\n", "{\"labels\":[\"Run tests\",\"Lint\"]}\n", &out, &err));
    try testing.expectEqualStrings("Run tests\nLint\n", out.buffered());

    out.end = 0;
    try testing.expectEqual(@as(u8, 3), try commandAgainst(.run, &.{ "Run", "tests", "--wait" }, null,
        \\run {"label":"Run tests","wait":true}
        \\
    , "{\"code\":3,\"text\":\"1 failed\"}\n", &out, &err));
    try testing.expectEqualStrings("1 failed\n", out.buffered());
    try testing.expectEqualStrings("roost run: \"Run tests\" failed (exit 3).\n", err.buffered());

    out.end = 0;
    err.end = 0;
    try testing.expectEqual(@as(u8, 0), try commandAgainst(.run, &.{"Lint"}, null,
        \\run {"label":"Lint","wait":false}
        \\
    , "{\"ok\":true}\n", &out, &err));
    try testing.expectEqualStrings("", out.buffered());
    try testing.expectEqualStrings("roost run: started \"Lint\".\n", err.buffered());

    err.end = 0;
    try testing.expectEqual(@as(u8, 1), try commandAgainst(.run, &.{"Deploy"}, null,
        \\run {"label":"Deploy","wait":false}
        \\
    , "{\"error\":\"There's no action named \\\"Deploy\\\".\"}\n", &out, &err));
    try testing.expectEqualStrings("roost run: There's no action named \"Deploy\".\n", err.buffered());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(u8, 2), runAction(arena.allocator(), &.{"--wait"}, "/nonexistent", &out, &err));
    try testing.expectEqual(@as(u8, 2), runAction(arena.allocator(), &.{ "Lint", "--force" }, "/nonexistent", &out, &err));
}

test "open: resolves the file against the caller's directory, with its line" {
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [512]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try testing.expectEqual(@as(u8, 0), try commandAgainst(.open, &.{"a.zig:42:7"}, "a.zig",
        \\open {"path":"{dir}/a.zig","line":42,"col":7}
        \\
    , "{\"ok\":true}\n", &out, &err));
    // A name that really has a colon and digits in it.
    try testing.expectEqual(@as(u8, 0), try commandAgainst(.open, &.{"log:12"}, "log:12",
        \\open {"path":"{dir}/log:12","line":0,"col":0}
        \\
    , "{\"ok\":true}\n", &out, &err));
    try testing.expectEqualStrings("", err.buffered());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // A missing file is caught before the window is asked.
    try testing.expectEqual(@as(u8, 1), open(arena.allocator(), &.{"missing.zig:3"}, "/nonexistent", "/nonexistent-dir", &out, &err));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "there's no file at /nonexistent-dir/missing.zig") != null);
    try testing.expectEqual(@as(u8, 2), open(arena.allocator(), &.{}, "/nonexistent", "/", &out, &err));
    try testing.expectEqual(@as(u8, 2), open(arena.allocator(), &.{ "a", "b" }, "/nonexistent", "/", &out, &err));
}

/// A pretend window that answers several connections in turn: each pair is
/// the request it wants and its answer.
fn fakeWindowSeq(fd: posix.socket_t, turns: []const [2][]const u8) void {
    for (turns) |t| fakeWindow(fd, t[0], t[1]);
}

fn alwaysGone(_: i32) bool {
    return true;
}

/// Window 11 is on workspace 3; the desktop doesn't know about the rest.
fn fakeWhere(a: std.mem.Allocator) hypr.Workspaces {
    var map: hypr.Workspaces = .empty;
    map.put(a, 11, "3") catch {};
    return map;
}

test "close --all: asks, saves the projects, and closes the caller's window last" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &dir_buf);
    if (dir.len + "/roost-1234.sock".len >= 108) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try listen(try std.fs.path.join(a, &.{ dir, "roost-11.sock" }));
    defer posix.close(one);
    const two = try listen(try std.fs.path.join(a, &.{ dir, "roost-22.sock" }));
    defer posix.close(two);
    const threads = [_]std.Thread{
        try .spawn(.{}, fakeWindowSeq, .{ one, &[_][2][]const u8{
            .{ "status\n", "{\"pid\":11,\"project\":\"/p/app\",\"name\":\"app\",\"branch\":\"main\",\"state\":\"working\"}\n" },
            .{ "close\n", "{\"ok\":true}\n" },
        } }),
        try .spawn(.{}, fakeWindowSeq, .{ two, &[_][2][]const u8{
            .{ "status\n", "{\"pid\":22,\"project\":\"/p/zed\",\"name\":\"zed\",\"branch\":\"\",\"state\":\"idle\"}\n" },
            .{ "close\n", "{\"ok\":true}\n" },
        } }),
    };
    defer for (threads) |t| t.join();

    const file = try std.fs.path.join(a, &.{ dir, "state", "roost", "closed-windows.json" });
    var out_buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [512]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    var tty: std.Io.Reader = .fixed("y\n");
    const own = try std.fs.path.join(a, &.{ dir, "roost-11.sock" });
    try testing.expectEqual(@as(u8, 0), closeAll(a, &.{"--all"}, dir, own, file, &tty, &out, &err, alwaysGone, fakeWhere));
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "Close these windows?") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "Closing 2 Roost windows.") != null);
    try testing.expectEqualStrings("", err.buffered());
    const saved = try std.fs.cwd().readFileAlloc(a, file, 4096);
    try testing.expectEqualStrings("{\"windows\":[{\"project\":\"/p/app\",\"workspace\":\"3\"},{\"project\":\"/p/zed\",\"workspace\":\"\"}]}\n", saved);
}

test "close: needs --all, and --yes when there's no terminal; a no closes nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    try testing.expectEqual(@as(u8, 2), closeAll(a, &.{}, "/nonexistent", null, null, null, &out, &err, alwaysGone, null));
    try testing.expectEqual(@as(u8, 2), closeAll(a, &.{ "--all", "--force" }, "/nonexistent", null, null, null, &out, &err, alwaysGone, null));
    // No windows: nothing to ask about.
    try testing.expectEqual(@as(u8, 0), closeAll(a, &.{"--all"}, "/nonexistent", null, null, null, &out, &err, alwaysGone, null));
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "No Roost windows are running.") != null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &dir_buf);
    if (dir.len + "/roost-1234.sock".len >= 108) return error.SkipZigTest;
    const fd = try listen(try std.fs.path.join(a, &.{ dir, "roost-33.sock" }));
    defer posix.close(fd);
    const status_reply = "{\"pid\":33,\"project\":\"/p/x\",\"name\":\"x\",\"branch\":\"\",\"state\":\"idle\"}\n";
    const t = try std.Thread.spawn(.{}, fakeWindowSeq, .{ fd, &[_][2][]const u8{ .{ "status\n", status_reply }, .{ "status\n", status_reply } } });
    defer t.join();
    err.end = 0;
    try testing.expectEqual(@as(u8, 2), closeAll(a, &.{"--all"}, dir, null, null, null, &out, &err, alwaysGone, null));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "Add --yes") != null);
    out.end = 0;
    var no: std.Io.Reader = .fixed("n\n");
    try testing.expectEqual(@as(u8, 1), closeAll(a, &.{"--all"}, dir, null, null, &no, &out, &err, alwaysGone, null));
    try testing.expect(std.mem.endsWith(u8, out.buffered(), "Nothing closed.\n"));
}

var placed_buf: [256]u8 = undefined;
var placed_log: std.Io.Writer = .fixed(&placed_buf);

const fake_placer: Placer = .{
    .before = struct {
        fn f(_: std.mem.Allocator, i: usize, name: []const u8, workspace: []const u8) void {
            placed_log.print("before {d} {s} {s};", .{ i, name, workspace }) catch {};
        }
    }.f,
    .after = struct {
        fn f(_: std.mem.Allocator, _: []const u8, placed: []const Placed) void {
            placed_log.print("after {d}", .{placed.len}) catch {};
            for (placed) |p| placed_log.print(" {s}@{s}", .{ std.fs.path.basename(p.project), p.workspace }) catch {};
            placed_log.writeAll(";") catch {};
        }
    }.f,
};

var launched: [4][]const u8 = undefined;
var launched_count: usize = 0;

fn fakeLaunch(a: std.mem.Allocator, project: []const u8) bool {
    launched[launched_count] = a.dupe(u8, project) catch return false;
    launched_count += 1;
    return true;
}

test "reopen: opens what isn't open, skips what's gone, then forgets the list" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &dir_buf);
    if (dir.len + "/roost-1234.sock".len >= 108) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.makePath("app");
    try tmp.dir.makePath("site");
    const app = try std.fs.path.join(a, &.{ dir, "app" });
    const site = try std.fs.path.join(a, &.{ dir, "site" });
    const file = try std.fs.path.join(a, &.{ dir, "closed-windows.json" });
    try saveClosed(a, file, &.{ .{ .project = app, .workspace = "2" }, .{ .project = site, .workspace = "5" }, .{ .project = "/nonexistent/gone" } });

    // `site` already has a window.
    const fd = try listen(try std.fs.path.join(a, &.{ dir, "roost-44.sock" }));
    defer posix.close(fd);
    const reply = try std.fmt.allocPrint(a, "{{\"pid\":44,\"project\":\"{s}\",\"name\":\"site\",\"branch\":\"\",\"state\":\"idle\"}}\n", .{site});
    const t = try std.Thread.spawn(.{}, fakeWindow, .{ fd, "status\n", reply });
    defer t.join();

    var out_buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [512]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    launched_count = 0;
    placed_log.end = 0;
    try testing.expectEqual(@as(u8, 0), reopen(a, &.{}, dir, file, &out, &err, fakeLaunch, fake_placer));
    try testing.expectEqual(@as(usize, 1), launched_count);
    // Only the window that was opened is placed, on its old workspace.
    try testing.expectEqualStrings("before 0 app 2;after 1 app@2;", placed_log.buffered());
    try testing.expectEqualStrings(app, launched[0]);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "Opened app.") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "site is already open.") != null);
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "/nonexistent/gone isn't there anymore") != null);
    // Forgotten, so a second reopen has nothing to do.
    out.end = 0;
    try testing.expectEqual(@as(u8, 1), reopen(a, &.{}, dir, file, &out, &err, fakeLaunch, null));
    try testing.expect(std.mem.startsWith(u8, out.buffered(), "Nothing to reopen."));
}
