//! Workspace: the free-form, role-aware, persistent pane tree (Phase 2.4).
//!
//! This used to be a hardcoded 2x2. It is now a thin owner around a dynamic
//! pane `Tree` (see tree.zig): a binary tree of Split / Leaf nodes rendered
//! into nested `gtk.Paned`s. The Workspace exposes the operations the app/
//! shortcuts drive (split / add-by-role / close / focus) plus persistence.
//!
//! Default layout (first run / no saved state) is the SAME 2x2 as before:
//!
//!     Agent | Git
//!     ------+-----------
//!     Shell | Scratchpad
//!
//! so nothing regresses.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gtk = @import("gtk");

const tree = @import("tree.zig");
const Tree = tree.Tree;
const Surface = @import("../apprt/gtk/class/surface.zig").Surface;

const log = std.log.scoped(.roost_layout);

/// Re-export the role + direction + agent-status enums so callers (app.zig,
/// ipc.zig) keep one import.
pub const Role = tree.Role;
pub const Direction = tree.Direction;
pub const AgentStatus = tree.AgentStatus;

pub const Workspace = struct {
    t: Tree,

    /// The root widget to set as the window's child (a stable container box).
    root: *gtk.Widget,

    /// The toplevel window, used to read the live GTK focus before a structural
    /// op so it targets the pane the user is actually in (set by app.zig after
    /// init, and after a project-switch rebuild).
    window: ?*gtk.Window = null,

    /// Build the workspace. If `saved` is non-null AND structurally valid, the
    /// tree is rebuilt from it (each leaf spawned by role in `cwd`, split
    /// ratios restored); otherwise the default 2x2 is built. A malformed saved
    /// layout never crashes — it silently falls back to the default.
    pub fn init(
        alloc: Allocator,
        git_cmd: ?[:0]const u8,
        agent_cmd: ?[:0]const u8,
        cwd: ?[:0]const u8,
        saved: ?*const tree.SerNode,
        scratch: tree.ScratchCfg,
    ) Workspace {
        const t: Tree = buildTree(alloc, git_cmd, agent_cmd, cwd, saved, scratch);
        return .{ .t = t, .root = t.root_widget };
    }

    fn buildTree(
        alloc: Allocator,
        git_cmd: ?[:0]const u8,
        agent_cmd: ?[:0]const u8,
        cwd: ?[:0]const u8,
        saved: ?*const tree.SerNode,
        scratch: tree.ScratchCfg,
    ) Tree {
        if (saved) |ser| {
            if (Tree.initFromSer(alloc, ser, git_cmd, agent_cmd, cwd, scratch)) |t| {
                return t;
            } else |err| {
                log.warn("saved layout invalid, using default 2x2 err={}", .{err});
            }
        }
        // The default build only fails on OOM; at startup that is fatal anyway.
        return Tree.initDefault(alloc, git_cmd, agent_cmd, cwd, scratch) catch
            @panic("out of memory building default layout");
    }

    pub fn deinit(self: *Workspace) void {
        self.t.deinit();
    }

    /// Connect every terminal pane's close-request to the given handler, and
    /// remember it so panes created later (via split/add) get it too.
    pub fn connectCloseRequests(
        self: *Workspace,
        callback: *const fn (*Surface, ?*anyopaque) callconv(.c) void,
        data: ?*anyopaque,
    ) void {
        self.t.connectCloseRequests(callback, data);
    }

    /// Move focus to the first leaf whose role matches `role` (tree order), or
    /// no-op if none. Used by the app on present to focus an initial pane.
    pub fn focusRole(self: *Workspace, role: Role) void {
        var found: ?*tree.Node = null;
        focusRoleWalk(self.t.root, role, &found);
        if (found) |n| self.t.focusNode(n);
    }

    fn focusRoleWalk(node: *tree.Node, role: Role, out: *?*tree.Node) void {
        if (out.* != null) return;
        switch (node.*) {
            .leaf => |l| {
                if (l.role == role) out.* = node;
            },
            .split => |*s| {
                focusRoleWalk(s.start, role, out);
                focusRoleWalk(s.end, role, out);
            },
        }
    }

    /// Focus the Nth (0-based) leaf in tree order (Alt+1..9).
    pub fn focusIndex(self: *Workspace, idx: usize) void {
        self.t.focusIndex(idx);
    }

    /// Move focus one step directionally across the tree.
    pub fn moveFocus(self: *Workspace, dir: Direction) void {
        if (self.window) |w| self.t.syncFocusFromWindow(w);
        self.t.moveFocus(dir);
    }

    /// Swap the focused pane with the pane in `dir` (Hyprland "move window").
    /// Sync live focus first so it operates on the pane the user is actually in.
    pub fn swapPane(self: *Workspace, dir: Direction) void {
        if (self.window) |w| self.t.syncFocusFromWindow(w);
        self.t.swapFocused(dir);
    }

    /// Whether closing the focused pane right now would kill a running agent.
    /// Syncs live focus first (the user may have clicked into another pane).
    pub fn focusedIsLiveAgent(self: *Workspace) bool {
        if (self.window) |w| self.t.syncFocusFromWindow(w);
        return self.t.focusedIsLiveAgent();
    }

    /// Whether any pane currently holds a running agent (for reset/rebuild).
    pub fn hasLiveAgent(self: *Workspace) bool {
        return self.t.hasLiveAgent();
    }

    /// Close the pane backed by `surface` (its process exited). Returns null if
    /// the surface isn't in this workspace, else how the close resolved.
    pub fn closeSurface(self: *Workspace, surface: *Surface) ?Tree.CloseResult {
        return self.t.closeSurface(surface);
    }

    /// Whether we're mid-teardown — the surface close-request handler uses this
    /// to ignore the close-requests our own `pane.destroy()` re-emits.
    pub fn isTearingDown(self: *Workspace) bool {
        return self.t.tearing_down;
    }

    /// Split the focused leaf; the new pane defaults to `shell`.
    pub fn split(self: *Workspace, orientation: gtk.Orientation) void {
        if (self.window) |w| self.t.syncFocusFromWindow(w);
        self.t.splitFocused(orientation, .shell) catch |err| {
            log.warn("split failed err={}", .{err});
        };
    }

    /// Split the focused pane's whole containing column/row as a unit (so the
    /// new pane spans the group with its own divider); new pane defaults to
    /// `shell`. Lets the user build independent-divider grids.
    pub fn splitGroup(self: *Workspace, orientation: gtk.Orientation) void {
        if (self.window) |w| self.t.syncFocusFromWindow(w);
        self.t.splitGroup(orientation, .shell) catch |err| {
            log.warn("split-group failed err={}", .{err});
        };
    }

    /// Resize the focused pane by nudging the nearest divider in `dir`'s
    /// direction (keyboard resize).
    pub fn resizePane(self: *Workspace, dir: Direction) void {
        if (self.window) |w| self.t.syncFocusFromWindow(w);
        self.t.resizeFocused(dir);
    }

    /// Add a new pane in the given role by splitting the focused leaf. We split
    /// vertically (new pane below) by default; the user can re-split as needed.
    /// "Add a pane by role" reuses the split machinery so the new pane lands in
    /// a real slot in the tree.
    pub fn addRole(self: *Workspace, role: Role) void {
        if (self.window) |w| self.t.syncFocusFromWindow(w);
        self.t.splitFocused(.vertical, role) catch |err| {
            log.warn("add-role failed err={}", .{err});
        };
    }

    /// Close the focused leaf, collapsing its sibling up. Returns true if that
    /// was the LAST pane (the caller should quit the app).
    pub fn closeFocused(self: *Workspace) bool {
        if (self.window) |w| self.t.syncFocusFromWindow(w);
        return self.t.closeFocused() == .closed_last;
    }

    /// Phase 3a "Send to Agent": send the focused scratchpad's text (selection
    /// or current line) into the first agent terminal pane (falling back to the
    /// first terminal of any role), then focus that pane. No-op if the focused
    /// pane isn't a scratchpad or there's no terminal to receive it.
    pub fn sendToAgent(self: *Workspace) void {
        if (self.window) |w| self.t.syncFocusFromWindow(w);
        self.t.sendFocusedScratchpadToAgent();
    }

    /// Update the Agent pane's header badge to reflect `status`. No-op if there
    /// is no agent pane. Driven by the IPC server on agent events.
    pub fn setAgentStatus(self: *Workspace, status: AgentStatus) void {
        self.t.setAgentStatus(status);
    }

    /// Route wired-action output into the first pane of `role` (agent/shell →
    /// terminal injection; scratchpad → append). Returns true if delivered.
    pub fn routeToRole(self: *Workspace, role: tree.Role, bytes: []const u8) bool {
        return self.t.routeToRole(role, bytes);
    }

    /// Snapshot the Agent pane's terminal text into the scratchpad. Returns a
    /// status the caller can surface (ok / no agent / no scratchpad / empty).
    pub fn captureAgentToScratchpad(self: *Workspace) tree.Tree.CaptureResult {
        return self.t.captureAgentToScratchpad();
    }

    /// Recompute the active-pane highlight from the window's live GTK focus.
    /// Driven by the window `notify::focus-widget` handler (mouse + keyboard +
    /// programmatic focus all route through it). No-op if no window is attached.
    pub fn updateHighlight(self: *Workspace) void {
        if (self.window) |w| self.t.updateHighlightFromWindow(w);
    }

    /// Serialize the current tree to JSON bytes (caller frees with `alloc`).
    pub fn serialize(self: *Workspace, alloc: Allocator) ![]u8 {
        return self.t.serialize(alloc);
    }

    /// Apply the current show-pane-titles preference to every open pane (live
    /// toggle from Settings). Set `tree.setShowPaneTitles` first.
    pub fn applyTitleVisibility(self: *Workspace) void {
        self.t.applyTitleVisibility();
    }

    /// Re-apply the app theme to all terminal panes (best-effort).
    pub fn setTheme(self: *Workspace) void {
        setThemeWalk(self.t.root);
    }

    fn setThemeWalk(node: *tree.Node) void {
        switch (node.*) {
            .leaf => |*l| if (l.pane == .terminal) {
                l.pane.terminal.setTheme();
            },
            .split => |*s| {
                setThemeWalk(s.start);
                setThemeWalk(s.end);
            },
        }
    }
};
