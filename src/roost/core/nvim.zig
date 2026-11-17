//! Steering Neovim in the Editor pane, for `roost open`.
//!
//! WHY: the Editor pane runs `$EDITOR`. When that's Neovim, Roost starts it
//! with `--listen <address>`, so it can later show a file at a line there. It
//! does that by running `nvim --server <address> --remote-expr <expr>`, which
//! keeps Neovim's RPC format out of Roost. Other editors have no such door, so
//! `roost open` says it needs Neovim.
//!
//! The expression calls Lua through `luaeval`, because `nvim_exec_lua` isn't
//! callable from an expression. Probed against Neovim 0.12: quotes and `|` in
//! paths, a line past the end, and a modified buffer (Neovim's default
//! 'hidden' lets it switch away) all work.
//!
//! Plain std, so a Mac Roost can use it too.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The editor the Editor pane runs: `$EDITOR`, else `$VISUAL`, else `nvim`,
/// the same order as the pane's shell command.
pub fn editorFrom(editor: ?[]const u8, visual: ?[]const u8) []const u8 {
    if (editor) |e| if (std.mem.trim(u8, e, " \t").len > 0) return e;
    if (visual) |v| if (std.mem.trim(u8, v, " \t").len > 0) return v;
    return "nvim";
}

/// The program an editor command runs: its first word.
pub fn program(cmd: []const u8) []const u8 {
    var words = std.mem.tokenizeAny(u8, cmd, " \t");
    return words.next() orelse "";
}

/// Whether an editor command runs Neovim.
pub fn isNeovim(cmd: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(program(cmd)), "nvim");
}

/// Where one Editor pane's Neovim listens: in the runtime directory, named for
/// the window and pane, plus a random part so a reload's new Neovim never
/// meets the old one's socket. Not `roost-<pid>.sock`, which would read as a
/// window's socket.
pub fn listenAddress(buf: []u8, runtime_dir: []const u8, pid: i32, pane: u32, nonce: u32) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/roost-nvim-{d}-{d}-{x:0>8}", .{ runtime_dir, pid, pane, nonce }) catch null;
}

/// `s` as one shell word, in single quotes.
pub fn shellQuote(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// The Lua run inside Neovim. Double quotes only, so it fits in a Vim
/// single-quoted string as is. It skips `:edit` when the file is already the
/// current buffer, which would refuse a modified one.
const open_lua =
    "(function(path, line, col) " ++
    "if vim.fn.resolve(vim.fn.expand(\"%:p\")) ~= vim.fn.resolve(path) then vim.cmd.edit(vim.fn.fnameescape(path)) end " ++
    "if line > 0 then " ++
    "vim.api.nvim_win_set_cursor(0, { math.min(line, vim.api.nvim_buf_line_count(0)), math.max(col - 1, 0) }) " ++
    "if col == 0 then vim.cmd(\"normal! ^\") end " ++
    "vim.cmd(\"normal! zz\") " ++
    "end end)(unpack(_A))";

/// The `--remote-expr` that shows `path` at `line` and `col` (1-based; 0 for
/// none). Fails on a path with a newline, which can't go in a Vim string.
pub fn openExpr(alloc: Allocator, path: []const u8, line: u32, col: u32) ![]u8 {
    if (std.mem.indexOfAny(u8, path, "\r\n\x00") != null) return error.BadPath;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("luaeval('" ++ open_lua ++ "', ['");
    for (path) |c| {
        if (c == '\'') try w.writeAll("''") else try w.writeByte(c);
    }
    try w.print("', {d}, {d}])", .{ line, col });
    return out.toOwnedSlice();
}

/// The useful part of what `nvim --server` printed on failure: the last
/// "Lua:" line's Vim error ("E492: Not an editor command: x"), else the
/// first line. Borrows from `stderr`.
pub fn errorLine(stderr: []const u8) []const u8 {
    var first: []const u8 = "";
    var lua: []const u8 = "";
    var lines = std.mem.tokenizeAny(u8, stderr, "\r\n");
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t");
        if (l.len == 0) continue;
        if (first.len == 0) first = l;
        if (std.mem.startsWith(u8, l, "Lua:")) lua = l;
    }
    if (lua.len == 0) return first;
    const vim = std.mem.lastIndexOf(u8, lua, "Vim:") orelse return lua;
    return std.mem.trim(u8, lua[vim + "Vim:".len ..], " ");
}

// ---------------------------------------------------------------------------
// Tests (run with `zig test src/roost/core/nvim.zig`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "editorFrom: EDITOR, then VISUAL, then nvim" {
    try testing.expectEqualStrings("hx", editorFrom("hx", "code"));
    try testing.expectEqualStrings("code", editorFrom("  ", "code"));
    try testing.expectEqualStrings("nvim", editorFrom(null, ""));
}

test "isNeovim: by the program's name, with or without a path and flags" {
    try testing.expect(isNeovim("nvim"));
    try testing.expect(isNeovim("/usr/bin/nvim -u NONE"));
    try testing.expect(isNeovim("  nvim"));
    try testing.expect(!isNeovim("vim"));
    try testing.expect(!isNeovim("hx"));
    try testing.expect(!isNeovim("nvim-qt"));
    try testing.expect(!isNeovim(""));
    try testing.expectEqualStrings("/usr/bin/nvim", program("/usr/bin/nvim -u NONE"));
}

test "listenAddress: per window and pane, never a window's socket name" {
    var buf: [128]u8 = undefined;
    const addr = listenAddress(&buf, "/run/user/1000", 4242, 3, 0xbeef).?;
    try testing.expectEqualStrings("/run/user/1000/roost-nvim-4242-3-0000beef", addr);
    try testing.expect(!std.mem.endsWith(u8, addr, ".sock"));
    var tiny: [8]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), listenAddress(&tiny, "/run/user/1000", 1, 1, 1));
}

test "shellQuote: one word, even with quotes" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try shellQuote(&w, "/run/it's here");
    try testing.expectEqualStrings("'/run/it'\\''s here'", w.buffered());
}

test "openExpr: the path is one Vim string, and the numbers follow" {
    const expr = try openExpr(testing.allocator, "/p/it's|odd.zig", 42, 7);
    defer testing.allocator.free(expr);
    try testing.expect(std.mem.startsWith(u8, expr, "luaeval('(function(path, line, col) "));
    try testing.expect(std.mem.endsWith(u8, expr, "', ['/p/it''s|odd.zig', 42, 7])"));
    // The Lua has no single quote, so the Vim string around it stays whole.
    try testing.expect(std.mem.indexOfScalar(u8, open_lua, '\'') == null);
    try testing.expectError(error.BadPath, openExpr(testing.allocator, "/p/a\nb", 1, 0));
}

test "errorLine: Neovim's error, not the stack" {
    try testing.expectEqualStrings("E492: Not an editor command: bogus", errorLine(
        \\Lua: Vim:E492: Not an editor command: bogus
        \\stack traceback:
        \\    [C]: in function 'rpcrequest'
    ));
    try testing.expectEqualStrings("E325: ATTENTION", errorLine(
        \\E325: ATTENTION
        \\Found a swap file by the name "x.swp"
        \\Lua: Vim:E5108: Lua: [string "luaeval()"]:1: Vim:E325: ATTENTION
        \\stack traceback:
    ));
    try testing.expectEqualStrings("E247: Failed to connect to '/run/x': connection refused. Send expression failed.", errorLine(
        "\nE247: Failed to connect to '/run/x': connection refused. Send expression failed.\n",
    ));
    try testing.expectEqualStrings("", errorLine(""));
}
