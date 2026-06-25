//! Free-form, role-aware, persistent pane TREE for roost (Phase 2.4).
//!
//! This REPLACES the old fixed 2x2 layout with a dynamic binary tree of panes:
//!
//!   Node = Split { orientation, gtk.Paned, two child Nodes }
//!        | Leaf  { role, Pane, labeled header box }
//!
//! A Leaf's Pane is either a Ghostty `TerminalPane` (agent/shell/git/editor) or
//! a `ScratchpadPane` (a GtkTextView). The tree renders into nested
//! `gtk.Paned`s; the window's child is the root node's widget.
//!
//! Each node is heap-allocated and owned by the `Tree`. Structural operations
//! (split / add / close-collapse) rewire the GTK widget hierarchy in place,
//! refing widgets across reparents the same way Ghostty's own split_tree.zig
//! does (see `detach` / the ref/unref dance below).
//!
//! ADDITIVE: our own file. Only `terminal_pane.zig` (and, here, scratchpad)
//! name Ghostty's `Surface`; this module talks to panes through the
//! `TerminalPane` abstraction and to GTK through the generated bindings.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gtk = @import("gtk");
const gobject = @import("gobject");
const glib = @import("glib");

const terminal_pane = @import("terminal_pane.zig");
const TerminalPane = terminal_pane.TerminalPane;
const ScratchpadPane = @import("scratchpad_pane.zig").ScratchpadPane;
const Surface = @import("../apprt/gtk/class/surface.zig").Surface;

const log = std.log.scoped(.roost_tree);

/// Focus-follows-mouse: when on, the pointer entering a pane focuses it (mini-
/// Hyprland feel). App-wide mode (not per-tree), so a module global; toggled at
/// runtime. Default on. Read by every leaf's motion controller (`onLeafEnter`).
var follow_mouse: bool = true;

/// Flip focus-follows-mouse and return the new state (for the toggle action).
pub fn toggleFollowMouse() bool {
    follow_mouse = !follow_mouse;
    return follow_mouse;
}

/// Current focus-follows-mouse state (to initialize UI that reflects it).
pub fn followMouseEnabled() bool {
    return follow_mouse;
}

/// The semantic roles a pane can have. Extensible: add a variant + its `title`
/// and `spawn` behavior (in `Tree.spawnPane`) and everything else follows.
pub const Role = enum {
    agent,
    shell,
    git,
    editor,
    scratchpad,

    pub fn title(self: Role) [:0]const u8 {
        return switch (self) {
            .agent => "Agent",
            .shell => "Shell",
            .git => "Git",
            .editor => "Editor",
            .scratchpad => "Scratchpad",
        };
    }

    /// Stable string key used in the persisted layout JSON.
    pub fn key(self: Role) []const u8 {
        return @tagName(self);
    }

    pub fn fromKey(s: []const u8) ?Role {
        return std.meta.stringToEnum(Role, s);
    }
};

/// The agent's lifecycle state, reflected in the Agent pane's header badge.
/// `idle` is the resting state (plain "Agent"); the others are driven by IPC
/// events from the running agent (see ipc.zig).
pub const AgentStatus = enum {
    idle,
    working,
    needs_input,
    done,

    /// The header label text for this status. The Agent pane shows this.
    fn badge(self: AgentStatus) [:0]const u8 {
        return switch (self) {
            .idle => "Agent",
            .working => "Agent — ● working",
            .needs_input => "Agent — 🔔 needs you",
            .done => "Agent — ✓ done",
        };
    }
};

/// A direction for directional pane-focus movement across the tree.
pub const Direction = enum {
    left,
    right,
    up,
    down,
};

/// A pane's content: either a Ghostty terminal or the scratchpad text view.
pub const Pane = union(enum) {
    terminal: TerminalPane,
    scratchpad: ScratchpadPane,

    fn widget(self: *Pane) *gtk.Widget {
        return switch (self.*) {
            .terminal => |*t| t.widget(),
            .scratchpad => |*s| s.widget(),
        };
    }

    fn focus(self: *Pane) void {
        switch (self.*) {
            .terminal => |*t| t.focus(),
            .scratchpad => |*s| s.focus(),
        }
    }

    fn destroy(self: *Pane) void {
        switch (self.*) {
            .terminal => |*t| t.destroy(),
            // ScratchpadPane has no process to tear down; GTK frees the widget
            // tree when it is unparented and unreffed.
            .scratchpad => {},
        }
    }
};

/// A leaf node: one pane plus its labeled header box.
pub const Leaf = struct {
    role: Role,
    pane: Pane,
    /// The vertical box holding [header label, pane content]. This is the
    /// widget parented into the tree (so it can be reparented as a unit).
    box: *gtk.Box,
    /// The header `gtk.Label` (the box's first child). Stored so we can update
    /// it in place for the Agent-pane status badge without re-walking widgets.
    label: *gtk.Label,
};

/// A split node: a gtk.Paned with two child nodes.
pub const Split = struct {
    orientation: gtk.Orientation,
    paned: *gtk.Paned,
    start: *Node,
    end: *Node,
};

/// A tree node.
pub const Node = union(enum) {
    leaf: Leaf,
    split: Split,

    /// The GTK widget for this node (the header box for a leaf, the paned for a
    /// split). This is what gets parented into the containing paned/window.
    pub fn widget(self: *Node) *gtk.Widget {
        return switch (self.*) {
            .leaf => |*l| l.box.as(gtk.Widget),
            .split => |*s| s.paned.as(gtk.Widget),
        };
    }
};

// --- Serializable representation (for persistence) ------------------------

/// JSON-facing node. Recursive via heap pointers; we serialize with a manual
/// writer and parse via std.json.Value walking so a malformed file can never
/// crash us (we just return null and the caller falls back to the default).
pub const SerNode = union(enum) {
    leaf: struct { role: []const u8 },
    split: struct {
        orientation: []const u8, // "horizontal" | "vertical"
        ratio: f64, // start-child proportion, 0..1
        start: *SerNode,
        end: *SerNode,
    },
};

// --- The Tree -------------------------------------------------------------

pub const Tree = struct {
    alloc: Allocator,
    root: *Node,
    /// A stable single-child container (a vertical gtk.Box) that ALWAYS holds
    /// exactly the current root node's widget. The window's child is set to
    /// this container ONCE; root-level structural changes (split/collapse at
    /// the top) just swap the container's child, so we never reparent a
    /// widget directly off the GtkWindow (which has special child semantics).
    container: *gtk.Box,
    /// The widget to set as the window's child: the stable container.
    root_widget: *gtk.Widget,
    /// The widget currently appended into `container` (the current root node's
    /// widget). Tracked so `setRoot` can `remove` it before appending the next.
    cur_root_widget: *gtk.Widget = undefined,
    /// Whether `container` currently holds a root widget.
    has_root: bool = false,
    /// The currently-focused leaf. Always a node within the tree.
    focused: *Node,

    /// The leaf currently carrying the `.roost-active` CSS highlight (the
    /// active-pane indicator). Tracked so we can clear it from the old leaf when
    /// focus moves. Null until the first highlight is applied. May briefly point
    /// at a leaf that is mid-teardown only between detach and node-free, which we
    /// never dereference (we only `removeCssClass`, guarded by a leaf check).
    highlighted: ?*Node = null,

    /// Command the Git role runs (lazygit or null=shell). Editor uses $EDITOR.
    git_cmd: ?[:0]const u8,
    /// Command the Agent role runs (e.g. `claude`, or null=shell fallback).
    agent_cmd: ?[:0]const u8,
    /// Working directory new terminal panes start in (null inherits default).
    cwd: ?[:0]const u8,

    /// Connected per-surface close-request handler, re-applied to every new
    /// terminal pane so a child process exiting never closes the window.
    close_cb: ?*const fn (*Surface, ?*anyopaque) callconv(.c) void = null,
    close_data: ?*anyopaque = null,
    /// True while WE are tearing down panes (close/deinit). Our own
    /// `pane.destroy()` calls `surface.close()`, which re-emits the surface
    /// `close-request` signal; the handler checks this flag and ignores those
    /// self-inflicted requests so it only acts on a genuine child-exit / user
    /// close (which is how `closeSurface` auto-closes an exited pane).
    tearing_down: bool = false,

    /// Build the DEFAULT 2x2 layout (first run / no saved state):
    ///   Agent (top-left) / Shell (bottom-left) | Git (top-right) / Scratchpad
    pub fn initDefault(alloc: Allocator, git_cmd: ?[:0]const u8, agent_cmd: ?[:0]const u8, cwd: ?[:0]const u8) Allocator.Error!Tree {
        var self = newEmpty(alloc, git_cmd, agent_cmd, cwd);

        const agent = try self.makeLeaf(.agent);
        const shell = try self.makeLeaf(.shell);
        const git = try self.makeLeaf(.git);
        const scratch = try self.makeLeaf(.scratchpad);

        const left = try self.makeSplit(.vertical, agent, shell, 0.5);
        const right = try self.makeSplit(.vertical, git, scratch, 0.5);
        const outer = try self.makeSplit(.horizontal, left, right, 0.5);

        self.setRoot(outer);
        self.focused = agent;
        return self;
    }

    /// Construct the Tree shell (allocator, container box, fields) with no root
    /// node attached yet. Callers fill `root`/`focused` via `setRoot`.
    fn newEmpty(alloc: Allocator, git_cmd: ?[:0]const u8, agent_cmd: ?[:0]const u8, cwd: ?[:0]const u8) Tree {
        const container = gtk.Box.new(.vertical, 0);
        container.as(gtk.Widget).setVexpand(1);
        container.as(gtk.Widget).setHexpand(1);
        return .{
            .alloc = alloc,
            .root = undefined,
            .container = container,
            .root_widget = container.as(gtk.Widget),
            .focused = undefined,
            .git_cmd = git_cmd,
            .agent_cmd = agent_cmd,
            .cwd = cwd,
        };
    }

    /// Set the root node and make the container display its widget. Removes any
    /// previous child first. `cur_root_widget` is tracked so we can remove it.
    fn setRoot(self: *Tree, node: *Node) void {
        // Remove the old root widget from the container if present.
        if (self.has_root) {
            self.container.remove(self.cur_root_widget);
        }
        self.root = node;
        self.cur_root_widget = node.widget();
        self.has_root = true;
        const w = node.widget();
        w.setVexpand(1);
        w.setHexpand(1);
        self.container.append(w);
    }

    /// Build a tree from a parsed `SerNode`. Spawns each leaf's role in `cwd`.
    /// Returns error.Invalid for a structurally broken description (the caller
    /// falls back to the default).
    pub fn initFromSer(
        alloc: Allocator,
        ser: *const SerNode,
        git_cmd: ?[:0]const u8,
        agent_cmd: ?[:0]const u8,
        cwd: ?[:0]const u8,
    ) !Tree {
        var self = newEmpty(alloc, git_cmd, agent_cmd, cwd);
        const root = try self.buildFromSer(ser);
        self.setRoot(root);
        // Focus the first leaf in tree order.
        self.focused = firstLeaf(self.root);
        return self;
    }

    fn buildFromSer(self: *Tree, ser: *const SerNode) !*Node {
        switch (ser.*) {
            .leaf => |l| {
                const role = Role.fromKey(l.role) orelse return error.Invalid;
                return self.makeLeaf(role);
            },
            .split => |s| {
                const orientation: gtk.Orientation =
                    if (std.mem.eql(u8, s.orientation, "horizontal"))
                        .horizontal
                    else if (std.mem.eql(u8, s.orientation, "vertical"))
                        .vertical
                    else
                        return error.Invalid;
                // If a deeper node is invalid (or makeSplit OOMs), free the
                // children already built so the partial subtree doesn't leak.
                // Safe to tear down here: close_cb is still null during the
                // build (callers connect it after init), so makeLeaf hasn't
                // wired any surface close-request handler that could re-enter.
                const start = try self.buildFromSer(s.start);
                errdefer self.destroyNode(start);
                const end = try self.buildFromSer(s.end);
                errdefer self.destroyNode(end);
                const ratio = std.math.clamp(s.ratio, 0.05, 0.95);
                return self.makeSplit(orientation, start, end, ratio);
            },
        }
    }

    /// Allocate a leaf node for `role`, spawning its pane + header box.
    fn makeLeaf(self: *Tree, role: Role) Allocator.Error!*Node {
        const node = try self.alloc.create(Node);
        errdefer self.alloc.destroy(node);

        var pane = self.spawnPane(role);
        // Wire the close-request no-op on terminal panes if we have a handler.
        if (pane == .terminal) {
            if (self.close_cb) |cb| {
                pane.terminal.connectCloseRequest(?*anyopaque, cb, self.close_data);
            }
        }

        const lb = labeledBox(role, pane.widget());
        node.* = .{ .leaf = .{ .role = role, .pane = pane, .box = lb.box, .label = lb.label } };
        // Focus-follows-mouse: focus this leaf when the pointer enters its box.
        attachFollowMouse(node, lb.box);
        return node;
    }

    /// Construct the pane content for a role.
    fn spawnPane(self: *Tree, role: Role) Pane {
        return switch (role) {
            // Agent runs the resolved agent command (e.g. `claude`) if we have
            // one; otherwise it falls back to the user's default shell (null).
            .agent => .{ .terminal = TerminalPane.initGhostty(.{
                .command = if (self.agent_cmd) |c| .{ .shell = c } else null,
                .cwd = self.cwd,
                .title = role.title(),
            }) },
            // Shell always runs the user's default shell.
            .shell => .{ .terminal = TerminalPane.initGhostty(.{
                .title = role.title(),
                .cwd = self.cwd,
            }) },
            .git => .{ .terminal = TerminalPane.initGhostty(.{
                .command = if (self.git_cmd) |c| .{ .shell = c } else null,
                .cwd = self.cwd,
                .title = role.title(),
            }) },
            .editor => .{ .terminal = TerminalPane.initGhostty(.{
                // $EDITOR via shell expansion, falling back to nvim then vi.
                .command = .{ .shell = "${EDITOR:-${VISUAL:-nvim}} || vi" },
                .cwd = self.cwd,
                .title = role.title(),
            }) },
            .scratchpad => .{ .scratchpad = ScratchpadPane.init() },
        };
    }

    /// Allocate a split node wrapping two existing child nodes in a gtk.Paned.
    fn makeSplit(
        self: *Tree,
        orientation: gtk.Orientation,
        start: *Node,
        end: *Node,
        ratio: f64,
    ) Allocator.Error!*Node {
        const node = try self.alloc.create(Node);
        const paned = gtk.Paned.new(orientation);
        paned.setStartChild(start.widget());
        paned.setEndChild(end.widget());
        paned.setResizeStartChild(1);
        paned.setResizeEndChild(1);
        paned.setWideHandle(1);
        node.* = .{ .split = .{
            .orientation = orientation,
            .paned = paned,
            .start = start,
            .end = end,
        } };
        // Apply the divider ratio once the paned has a real allocation.
        applyRatioOnAllocate(paned, ratio);
        return node;
    }

    // --- Lifecycle --------------------------------------------------------

    /// Set (or re-apply) the per-surface close-request handler used to keep a
    /// pane open when its child process exits. Applies to all CURRENT terminal
    /// panes and is remembered for panes created later.
    pub fn connectCloseRequests(
        self: *Tree,
        callback: *const fn (*Surface, ?*anyopaque) callconv(.c) void,
        data: ?*anyopaque,
    ) void {
        self.close_cb = callback;
        self.close_data = data;
        connectCloseWalk(self.root, callback, data);
    }

    fn connectCloseWalk(
        node: *Node,
        callback: *const fn (*Surface, ?*anyopaque) callconv(.c) void,
        data: ?*anyopaque,
    ) void {
        switch (node.*) {
            .leaf => |*l| {
                if (l.pane == .terminal) {
                    l.pane.terminal.connectCloseRequest(?*anyopaque, callback, data);
                }
            },
            .split => |*s| {
                connectCloseWalk(s.start, callback, data);
                connectCloseWalk(s.end, callback, data);
            },
        }
    }

    /// Free the whole tree's node allocations. Does NOT destroy widgets; the
    /// caller is expected to have already detached the root widget (e.g. via
    /// gtk.Window.setChild(other)), which finalizes the widget hierarchy. We
    /// also call destroy() on terminal panes so Ghostty tears down cleanly.
    pub fn deinit(self: *Tree) void {
        // Each `pane.destroy()` re-emits its surface close-request; flag the
        // teardown so the handler ignores them all (we're freeing the tree).
        self.tearing_down = true;
        self.destroyNode(self.root);
        self.* = undefined;
    }

    /// The leaf whose terminal pane wraps `surface`, or null. Used to map a
    /// surface close-request back to the node that should collapse.
    fn findLeafForSurface(self: *Tree, surface: *Surface) ?*Node {
        var found: ?*Node = null;
        surfaceLeafWalk(self.root, surface, &found);
        return found;
    }

    fn surfaceLeafWalk(node: *Node, surface: *Surface, out: *?*Node) void {
        switch (node.*) {
            .leaf => |*l| {
                if (l.pane == .terminal and l.pane.terminal.matchesSurface(surface)) {
                    out.* = node;
                }
            },
            .split => |*s| {
                surfaceLeafWalk(s.start, surface, out);
                surfaceLeafWalk(s.end, surface, out);
            },
        }
    }

    fn destroyNode(self: *Tree, node: *Node) void {
        switch (node.*) {
            .leaf => |*l| l.pane.destroy(),
            .split => |*s| {
                self.destroyNode(s.start);
                self.destroyNode(s.end);
            },
        }
        if (self.highlighted == node) self.highlighted = null;
        self.alloc.destroy(node);
    }

    // --- Focus ------------------------------------------------------------

    pub fn focusNode(self: *Tree, node: *Node) void {
        self.focused = node;
        node.leaf.pane.focus();
    }

    /// Focus the Nth (0-based) leaf in tree order (in-order traversal). Out of
    /// range focuses the last leaf. Roles are no longer unique, so callers use
    /// this for Alt+1..9.
    pub fn focusIndex(self: *Tree, idx: usize) void {
        var counter: usize = 0;
        var target: ?*Node = null;
        self.walkLeaves(self.root, &counter, idx, &target);
        if (target) |t| self.focusNode(t) else self.focusNode(lastLeaf(self.root));
    }

    fn walkLeaves(self: *Tree, node: *Node, counter: *usize, want: usize, out: *?*Node) void {
        switch (node.*) {
            .leaf => {
                if (counter.* == want and out.* == null) out.* = node;
                counter.* += 1;
            },
            .split => |*s| {
                self.walkLeaves(s.start, counter, want, out);
                self.walkLeaves(s.end, counter, want, out);
            },
        }
    }

    /// The pane that `dir` points at from the focused pane, Hyprland-style, or
    /// null at an edge. We lay the tree out into normalized [0,1]x[0,1]
    /// rectangles (using each split's LIVE divider ratio, so manual drags are
    /// respected), then among the panes whose center is past the focused pane's
    /// center in `dir`, choose the one with the most overlap on the perpendicular
    /// axis — tie-broken by nearest. This preserves the cross-axis position (e.g.
    /// moving right from the bottom-left pane lands on the bottom-right pane, not
    /// the top-right one). Shared by `moveFocus` and `swapFocused` so the two
    /// always agree on "the pane in that direction".
    fn findInDirection(self: *Tree, dir: Direction) ?*Node {
        const from = self.focused;
        if (from.* != .leaf) return null;
        const from_rect = rectOf(self.root, from, unit_rect) orelse return null;
        var search: FocusSearch = .{ .dir = dir, .from = from_rect, .from_node = from };
        searchDirection(self.root, unit_rect, &search);
        return search.best;
    }

    /// Move focus one step in `dir`. No-op at an edge (nothing in that direction).
    pub fn moveFocus(self: *Tree, dir: Direction) void {
        if (self.findInDirection(dir)) |target| self.focusNode(target);
    }

    /// Swap the focused pane with the pane in `dir` (the same one `moveFocus`
    /// would land on), then keep focus on the moved pane so it travels with you
    /// — exactly like Hyprland's "move window". No-op at an edge.
    pub fn swapFocused(self: *Tree, dir: Direction) void {
        const from = self.focused;
        if (from.* != .leaf) return;
        const target = self.findInDirection(dir) orelse return;
        self.swapNodes(from, target);
        self.focusNode(from);
    }

    /// Update `focused` to the leaf that ACTUALLY holds GTK keyboard focus right
    /// now (e.g. after a mouse click). Passive: it records focus, it does NOT
    /// grab it (so it won't loop with focus-in events). No-op if nothing in the
    /// tree is focused. Call this before any op that reads `focused`
    /// (split/add/close/move) so it targets the pane the user is really in,
    /// not the last one focused programmatically.
    pub fn syncFocusFromWindow(self: *Tree, window: *gtk.Window) void {
        const fw = window.getFocus() orelse return;
        var found: ?*Node = null;
        findFocusedLeaf(self.root, fw, &found);
        if (found) |n| self.focused = n;
    }

    // --- Active-pane indicator -------------------------------------------

    /// CSS class toggled on the focused leaf's box. Styled by the app-level CSS
    /// provider (see app.zig): every pane carries a faint `.roost-pane` border,
    /// and `.roost-active` brightens that border's color (no size change, so the
    /// terminal grid never reflows when focus moves).
    const active_css_class = "roost-active";

    /// Move the `.roost-active` highlight onto `node`'s box, clearing it from the
    /// previously highlighted leaf. No-op if `node` is already highlighted or is
    /// not a leaf. The highlight is purely visual; it does not change `focused`.
    pub fn highlightLeaf(self: *Tree, node: *Node) void {
        if (self.highlighted == node) return;
        if (self.highlighted) |old| {
            if (old.* == .leaf) old.leaf.box.as(gtk.Widget).removeCssClass(active_css_class);
        }
        self.highlighted = null;
        if (node.* != .leaf) return;
        node.leaf.box.as(gtk.Widget).addCssClass(active_css_class);
        self.highlighted = node;
    }

    /// Recompute the active-pane highlight from the window's live GTK focus
    /// widget: find the leaf that contains it and move `.roost-active` there.
    /// Driven by a window `notify::focus-widget` handler, so it tracks mouse
    /// clicks, keyboard nav, and programmatic focus alike. No-op when focus is
    /// outside any pane (e.g. a dialog) — the last pane stays highlighted, which
    /// reads better than a flicker to "nothing focused".
    pub fn updateHighlightFromWindow(self: *Tree, window: *gtk.Window) void {
        const fw = window.getFocus() orelse return;
        var found: ?*Node = null;
        findFocusedLeaf(self.root, fw, &found);
        if (found) |n| self.highlightLeaf(n);
    }

    // --- Cross-pane: send scratchpad text to the agent -------------------

    /// Phase 3a "Send to Agent": if the FOCUSED leaf is a scratchpad, take its
    /// text-to-send (selection, else current line) and inject it into a target
    /// terminal pane, then focus that terminal so the user sees it land.
    ///
    /// Target selection: the FIRST `agent`-role terminal leaf in tree order; if
    /// there is no agent pane, the first terminal leaf of ANY role; if there are
    /// no terminal panes at all, this is a no-op. If the focused leaf isn't a
    /// scratchpad, this is a no-op (logged at debug).
    ///
    /// Callers should `syncFocusFromWindow` first so `focused` reflects the pane
    /// the user is really in.
    pub fn sendFocusedScratchpadToAgent(self: *Tree) void {
        const leaf = self.focused;
        if (leaf.* != .leaf or leaf.leaf.pane != .scratchpad) {
            log.debug("send-to-agent: focused pane is not a scratchpad, ignoring", .{});
            return;
        }

        // Extract the text to send (glib-owned, NUL-terminated). Freed after the
        // send regardless of which path produced it.
        const text = leaf.leaf.pane.scratchpad.copyTextToSend() orelse {
            log.debug("send-to-agent: nothing to send (empty selection/line)", .{});
            return;
        };
        defer glib.free(text.ptr);

        // Choose the target: first agent terminal, else first terminal of any
        // role. No terminal panes -> no-op.
        const target = self.firstTerminalLeafPreferringRole(.agent) orelse {
            log.info("send-to-agent: no terminal pane to send to", .{});
            return;
        };

        target.leaf.pane.terminal.sendText(text);
        log.info("send-to-agent: sent {d} bytes to {s} pane", .{ text.len, target.leaf.role.title() });

        // Focus the target so the user sees the text land.
        self.focusNode(target);
    }

    /// First terminal leaf whose role == `role` (tree order); if none, the first
    /// terminal leaf of ANY role; null if there are no terminal panes.
    fn firstTerminalLeafPreferringRole(self: *Tree, role: Role) ?*Node {
        var preferred: ?*Node = null;
        var any: ?*Node = null;
        terminalLeafWalk(self.root, role, &preferred, &any);
        return preferred orelse any;
    }

    // --- Agent status badge ----------------------------------------------

    /// Update the FIRST agent-role leaf's header label to reflect `status`.
    /// No-op if there is no agent pane. Used by the IPC server when the agent
    /// reports progress (done / needs-input / working).
    pub fn setAgentStatus(self: *Tree, status: AgentStatus) void {
        const leaf = self.firstLeafOfRole(.agent) orelse return;
        leaf.leaf.label.setText(status.badge());
    }

    /// First leaf (tree order) whose role matches `role`, or null.
    fn firstLeafOfRole(self: *Tree, role: Role) ?*Node {
        var found: ?*Node = null;
        leafOfRoleWalk(self.root, role, &found);
        return found;
    }

    // --- Live-agent detection --------------------------------------------
    // Used to confirm before a destructive op (close-pane / reset) would kill a
    // running agent mid-task. Only an Agent-role pane whose child process is
    // still alive counts — shell/git/editor panes and the scratchpad never do.

    /// Whether `leaf` is an Agent pane with a still-running child (e.g. `claude`).
    fn leafIsLiveAgent(leaf: *Leaf) bool {
        if (leaf.role != .agent) return false;
        return switch (leaf.pane) {
            .terminal => |*t| t.hasLiveProcess(),
            .scratchpad => false,
        };
    }

    /// Whether the focused pane is a live agent (so close-pane would kill it).
    /// Callers should `syncFocusFromWindow` first if the user may have clicked
    /// into a different pane than the last programmatic focus.
    pub fn focusedIsLiveAgent(self: *Tree) bool {
        return self.focused.* == .leaf and leafIsLiveAgent(&self.focused.leaf);
    }

    /// Whether ANY pane holds a live agent (so a reset/rebuild that tears the
    /// whole tree down would kill it).
    pub fn hasLiveAgent(self: *Tree) bool {
        return nodeHasLiveAgent(self.root);
    }

    fn nodeHasLiveAgent(node: *Node) bool {
        return switch (node.*) {
            .leaf => |*l| leafIsLiveAgent(l),
            .split => |*s| nodeHasLiveAgent(s.start) or nodeHasLiveAgent(s.end),
        };
    }

    // --- Structural operations -------------------------------------------

    /// Split the focused leaf into two along `orientation`. The focused pane
    /// keeps its role and stays in the START child; a NEW pane (role
    /// `new_role`, default shell) goes in the END child. The new pane is
    /// focused. The new split takes the focused leaf's slot in its parent.
    pub fn splitFocused(self: *Tree, orientation: gtk.Orientation, new_role: Role) Allocator.Error!void {
        const leaf = self.focused;
        if (leaf.* != .leaf) return; // defensive; focused is always a leaf

        // Build the new sibling leaf.
        const new_leaf = try self.makeLeaf(new_role);

        // Detach the focused leaf's widget from its current parent (window or
        // a paned) so we can reparent it under a fresh paned. Hold a ref so
        // detaching doesn't finalize it.
        const leaf_widget = leaf.widget();
        const obj = leaf_widget.as(gobject.Object);
        _ = obj.ref();
        defer obj.unref();
        const slot = self.detach(leaf);

        // New paned: focused leaf (start) over/beside new leaf (end).
        const new_split = try self.makeSplit(orientation, leaf, new_leaf, 0.5);

        // Re-attach the new split into the slot the focused leaf used to hold.
        self.attach(slot, new_split);

        self.focusNode(new_leaf);
    }

    /// Split the focused pane's CONTAINING group (its parent column/row) as a
    /// unit: wrap that whole parent subtree in a fresh paned alongside a new
    /// `new_role` leaf, so the new pane spans the full extent of the group and
    /// gets its own divider — instead of nesting inside the focused leaf (which
    /// is what `splitFocused` does, and what produces a shared outer divider).
    ///
    /// Example: from a left column `V[agent, shell]`, splitting the group
    /// horizontally yields `H[ V[agent, shell] | new ]` — the column keeps its
    /// own independent vertical divider, and `new` is a full-height sibling.
    ///
    /// If the focused leaf has no parent (it's the only pane), there is no group
    /// to wrap, so this degenerates to a normal `splitFocused`. The new pane is
    /// focused.
    pub fn splitGroup(self: *Tree, orientation: gtk.Orientation, new_role: Role) Allocator.Error!void {
        const leaf = self.focused;
        if (leaf.* != .leaf) return; // defensive; focused is always a leaf
        const group = parentOf(self.root, leaf) orelse {
            // Only one pane in the tree — nothing to wrap; just split the leaf.
            return self.splitFocused(orientation, new_role);
        };

        // Build the new sibling leaf.
        const new_leaf = try self.makeLeaf(new_role);

        // Detach the whole group subtree's widget from its current slot so we can
        // reparent it under a fresh paned. Hold a ref so detaching (which drops
        // the parent paned's reference) doesn't finalize it.
        const group_widget = group.widget();
        const obj = group_widget.as(gobject.Object);
        _ = obj.ref();
        defer obj.unref();
        const slot = self.detach(group);

        // New paned: the existing group (start) beside/over the new leaf (end).
        const new_split = try self.makeSplit(orientation, group, new_leaf, 0.5);

        // Re-attach the new split into the slot the group used to hold.
        self.attach(slot, new_split);

        self.focusNode(new_leaf);
    }

    /// Resize the focused pane by nudging the nearest ancestor divider on `dir`'s
    /// axis IN the arrow's direction: Down/Right move the divider down/right
    /// (increase the paned position), Up/Left move it up/left. This is
    /// independent of which side the focused pane sits on — so e.g. Up always
    /// moves the divider up, growing a bottom pane and shrinking a top one, which
    /// is what "press the arrow to push the boundary that way" feels like. No-op
    /// if the focused pane already spans that axis (no ancestor split of that
    /// orientation). `setPosition` marks the divider user-set, so it persists.
    pub fn resizeFocused(self: *Tree, dir: Direction) void {
        const orientation: gtk.Orientation = switch (dir) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };
        const increase = switch (dir) { // move the divider toward the end (down/right)
            .right, .down => true,
            .left, .up => false,
        };
        var child = self.focused;
        if (child.* != .leaf) return;
        var parent = parentOf(self.root, child);
        while (parent) |p| {
            if (p.split.orientation == orientation) {
                const paned = p.split.paned;
                const max = panedIntProp(paned, "max-position");
                if (max <= 0) return;
                // Proportional step keeps the feel consistent across monitor sizes.
                const step: c_int = @max(@as(c_int, 24), @divTrunc(max, 10));
                const delta: c_int = if (increase) step else -step;
                paned.setPosition(std.math.clamp(paned.getPosition() + delta, 0, max));
                return;
            }
            child = p;
            parent = parentOf(self.root, p);
        }
        // No ancestor split of that orientation: the pane spans the axis already.
    }

    /// Close the focused leaf. Its sibling collapses up to replace the parent
    /// split. Returns `.closed_last` if this was the LAST pane (caller should
    /// quit), else `.collapsed`. Focus moves to a neighboring leaf.
    pub const CloseResult = enum { collapsed, closed_last };

    pub fn closeFocused(self: *Tree) CloseResult {
        return self.closeNode(self.focused);
    }

    /// Close the leaf whose terminal surface is `surface` (its child exited, or
    /// the user clicked the "process exited" Close button). Returns null if the
    /// surface isn't in this tree, else the same `CloseResult` as `closeFocused`.
    pub fn closeSurface(self: *Tree, surface: *Surface) ?CloseResult {
        const node = self.findLeafForSurface(surface) orelse return null;
        return self.closeNode(node);
    }

    /// Collapse `leaf` out of the tree: its sibling takes over the parent split's
    /// slot. Shared by `closeFocused` and `closeSurface`.
    fn closeNode(self: *Tree, leaf: *Node) CloseResult {
        if (leaf.* != .leaf) return .collapsed;

        const parent = parentOf(self.root, leaf) orelse {
            // This leaf IS the root: closing the last pane.
            return .closed_last;
        };

        const split = &parent.split;
        const sibling = if (split.start == leaf) split.end else split.start;

        // IMPORTANT ordering: capture WHERE `parent` sits in the grandparent
        // BEFORE we free anything, because `slotOf`/`parentOf` traverse the
        // tree and would otherwise dereference the freed `leaf` node.
        const parent_slot = self.slotOf(parent);

        // Hold a ref on the sibling widget so detaching it from the parent's
        // paned doesn't finalize it; we re-parent it below.
        const sib_widget = sibling.widget();
        const sib_obj = sib_widget.as(gobject.Object);
        _ = sib_obj.ref();
        defer sib_obj.unref();

        // Detach BOTH children from the parent paned. Now the paned is empty.
        split.paned.setStartChild(null);
        split.paned.setEndChild(null);

        // Tear down the leaf (process + node struct). Drop any dangling
        // highlight pointer first so the next notify never reads a freed node.
        // Guard the destroy: `pane.destroy()` re-emits this surface's
        // close-request, which must not re-enter and double-free this node.
        if (self.highlighted == leaf) self.highlighted = null;
        self.tearing_down = true;
        leaf.leaf.pane.destroy();
        self.tearing_down = false;
        self.alloc.destroy(leaf);

        // Remove the parent paned widget from wherever it lived (container for
        // the root slot, or the grandparent paned), then free the parent node.
        // The paned widget, now childless and unparented, is finalized by GTK.
        self.detachSlot(parent_slot);
        self.alloc.destroy(parent);

        // Promote the sibling into the slot the parent used to hold.
        self.attach(parent_slot, sibling);

        // Focus a leaf within the promoted sibling subtree.
        self.focusNode(firstLeaf(sibling));
        return .collapsed;
    }

    /// Identifies where a node is parented, so it can be detached + re-attached.
    const Slot = union(enum) {
        root, // the node is the tree root (in the container box)
        start: *Node, // start child of this split node
        end: *Node, // end child of this split node
    };

    /// Compute the logical slot of `node` WITHOUT mutating anything. Safe to
    /// call before any frees.
    fn slotOf(self: *Tree, node: *Node) Slot {
        const parent = parentOf(self.root, node) orelse return .root;
        return if (parent.split.start == node)
            .{ .start = parent }
        else
            .{ .end = parent };
    }

    /// Remove the widget currently occupying `slot` from its GTK parent.
    fn detachSlot(self: *Tree, slot: Slot) void {
        switch (slot) {
            .root => {
                // The root widget lives in `container`; remove it so a
                // replacement can be appended by `attach`/`setRoot`.
                if (self.has_root) {
                    self.container.remove(self.cur_root_widget);
                    self.has_root = false;
                }
            },
            .start => |parent| parent.split.paned.setStartChild(null),
            .end => |parent| parent.split.paned.setEndChild(null),
        }
    }

    /// Convenience: capture `node`'s slot and detach its widget. Returns the
    /// slot for a later `attach`. Only safe when no nodes have been freed.
    fn detach(self: *Tree, node: *Node) Slot {
        const slot = self.slotOf(node);
        self.detachSlot(slot);
        return slot;
    }

    /// Re-attach `node` into the given slot, updating both the GTK paned and
    /// our tree pointers.
    fn attach(self: *Tree, slot: Slot, node: *Node) void {
        switch (slot) {
            .root => self.setRoot(node),
            .start => |parent| {
                parent.split.start = node;
                parent.split.paned.setStartChild(node.widget());
            },
            .end => |parent| {
                parent.split.end = node;
                parent.split.paned.setEndChild(node.widget());
            },
        }
    }

    /// Swap two leaves' positions in the tree: exchange their GTK slots and the
    /// node pointers in their parent splits. Sizes travel WITH the panes — a
    /// short pane swapped above a long one stays short — by restoring each
    /// pane's pre-swap extent in its new slot (see `restoreGeo`). Both nodes
    /// must be non-root (always true when found via `findInDirection`, which
    /// only returns a target when there are ≥2 panes).
    fn swapNodes(self: *Tree, a: *Node, b: *Node) void {
        if (a == b) return;
        // Capture both slots and geometry BEFORE mutating — these walk the
        // live tree and read live widget allocations.
        const slot_a = self.slotOf(a);
        const slot_b = self.slotOf(b);
        const geo_a = self.captureGeo(a);
        const geo_b = self.captureGeo(b);
        // Hold a ref on each widget so detaching it from its paned (which drops
        // the paned's reference) doesn't finalize it before we re-attach.
        const a_obj = a.widget().as(gobject.Object);
        _ = a_obj.ref();
        defer a_obj.unref();
        const b_obj = b.widget().as(gobject.Object);
        _ = b_obj.ref();
        defer b_obj.unref();
        self.detachSlot(slot_a);
        self.detachSlot(slot_b);
        self.attach(slot_a, b);
        self.attach(slot_b, a);

        // Restore sizes so each pane keeps its own. When both panes share one
        // parent (a sibling swap) a single divider set is exact — the start
        // child's size fixes the end child's remainder — so drive it from the
        // start-slot pane only. Otherwise restore each within its own parent.
        const pa = parentOf(self.root, a);
        const pb = parentOf(self.root, b);
        if (pa != null and pa == pb) {
            if (pa.?.split.start == a) self.restoreGeo(a, geo_a) else self.restoreGeo(b, geo_b);
        } else {
            self.restoreGeo(a, geo_a);
            self.restoreGeo(b, geo_b);
        }
    }

    /// Pre-swap geometry of a leaf: its parent split's orientation (null if the
    /// node is the tree root) and its pixel extent. Captured before a swap so
    /// `restoreGeo` can make a pane's size follow it across the move.
    const LeafGeo = struct {
        parent_orientation: ?gtk.Orientation,
        w: c_int,
        h: c_int,
    };

    fn captureGeo(self: *Tree, node: *Node) LeafGeo {
        const wdg = node.widget();
        const parent = parentOf(self.root, node);
        return .{
            .parent_orientation = if (parent) |p| p.split.orientation else null,
            .w = wdg.getWidth(),
            .h = wdg.getHeight(),
        };
    }

    /// Set `node`'s new parent divider so the pane regains its captured extent.
    /// Restores ONLY along an orientation the pane keeps across the move (its
    /// old and new parent agree): that covers sibling swaps and same-axis
    /// neighbors, where the moved-into slot's size is exactly what changed.
    /// Cross-orientation moves fall back to slot sizing — "keep size" is
    /// ill-defined there and restoring would squish uninvolved bystanders.
    fn restoreGeo(self: *Tree, node: *Node, geo: LeafGeo) void {
        const parent = parentOf(self.root, node) orelse return;
        const split = &parent.split;
        const old_o = geo.parent_orientation orelse return;
        if (old_o != split.orientation) return;
        const o = split.orientation;
        const wdg = split.paned.as(gtk.Widget);
        const extent: c_int = if (o == .horizontal) wdg.getWidth() else wdg.getHeight();
        const size: c_int = if (o == .horizontal) geo.w else geo.h;
        if (extent <= 1 or size <= 0) return;
        // Divider position = the start child's size; the end child gets the
        // remainder (handle width ignored, matching liveRatio's pos/extent).
        const pos: c_int = if (split.start == node) size else extent - size;
        split.paned.setPosition(std.math.clamp(pos, 1, extent - 1));
    }

    // --- Persistence ------------------------------------------------------

    /// Serialize the live tree to JSON bytes (caller owns/frees). Reads each
    /// split's current divider proportion so the saved ratios match the UI.
    pub fn serialize(self: *Tree, alloc: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        try self.writeNode(&aw.writer, self.root);
        return aw.toOwnedSlice();
    }

    fn writeNode(self: *Tree, w: *std.Io.Writer, node: *Node) !void {
        switch (node.*) {
            .leaf => |l| {
                try w.print("{{\"type\":\"leaf\",\"role\":\"{s}\"}}", .{l.role.key()});
            },
            .split => |s| {
                const ratio = currentRatio(s.paned);
                // Compare rather than switch, so this is correct whether the
                // gtk.Orientation binding is exhaustive or not.
                const orient: []const u8 =
                    if (s.orientation == .vertical) "vertical" else "horizontal";
                try w.print(
                    "{{\"type\":\"split\",\"orientation\":\"{s}\",\"ratio\":{d:.4},\"start\":",
                    .{ orient, ratio },
                );
                try self.writeNode(w, s.start);
                try w.writeAll(",\"end\":");
                try self.writeNode(w, s.end);
                try w.writeAll("}");
            },
        }
    }
};

// --- Free functions -------------------------------------------------------

/// The parent split node of `target` within the subtree rooted at `node`, or
/// null if `target` is `node` itself (i.e. the tree root).
fn parentOf(node: *Node, target: *Node) ?*Node {
    switch (node.*) {
        .leaf => return null,
        .split => |*s| {
            if (s.start == target or s.end == target) return node;
            if (parentOf(s.start, target)) |p| return p;
            if (parentOf(s.end, target)) |p| return p;
            return null;
        },
    }
}

/// Find the leaf whose header box equals or contains the focused widget `fw`,
/// writing it to `out`. Used by `syncFocusFromWindow`: a pane's terminal/
/// textview is a descendant of its leaf box, so the box is `fw`'s ancestor.
fn findFocusedLeaf(node: *Node, fw: *gtk.Widget, out: *?*Node) void {
    if (out.* != null) return;
    switch (node.*) {
        .leaf => |*l| {
            const box = l.box.as(gtk.Widget);
            if (fw == box or fw.isAncestor(box) != 0) out.* = node;
        },
        .split => |*s| {
            findFocusedLeaf(s.start, fw, out);
            findFocusedLeaf(s.end, fw, out);
        },
    }
}

/// Walk the subtree in tree order, recording the first TERMINAL leaf whose role
/// matches `want` into `preferred`, and the first terminal leaf of ANY role into
/// `any`. Scratchpad leaves are skipped (they have no `sendText`).
fn terminalLeafWalk(node: *Node, want: Role, preferred: *?*Node, any: *?*Node) void {
    switch (node.*) {
        .leaf => |*l| {
            if (l.pane != .terminal) return;
            if (any.* == null) any.* = node;
            if (preferred.* == null and l.role == want) preferred.* = node;
        },
        .split => |*s| {
            terminalLeafWalk(s.start, want, preferred, any);
            terminalLeafWalk(s.end, want, preferred, any);
        },
    }
}

/// Walk in tree order, recording the first leaf whose role == `want` into `out`.
fn leafOfRoleWalk(node: *Node, want: Role, out: *?*Node) void {
    if (out.* != null) return;
    switch (node.*) {
        .leaf => |*l| {
            if (l.role == want) out.* = node;
        },
        .split => |*s| {
            leafOfRoleWalk(s.start, want, out);
            leafOfRoleWalk(s.end, want, out);
        },
    }
}

/// The first leaf in tree order within the subtree rooted at `node`.
fn firstLeaf(node: *Node) *Node {
    var cur = node;
    while (cur.* == .split) cur = cur.split.start;
    return cur;
}

/// The last leaf in tree order within the subtree rooted at `node`.
fn lastLeaf(node: *Node) *Node {
    var cur = node;
    while (cur.* == .split) cur = cur.split.end;
    return cur;
}

// --- Geometric (Hyprland-style) directional focus -------------------------

/// A normalized rectangle in [0,1]x[0,1] layout space (x right, y down).
const NRect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    fn cx(r: NRect) f64 {
        return r.x + r.w / 2.0;
    }
    fn cy(r: NRect) f64 {
        return r.y + r.h / 2.0;
    }
};

const unit_rect: NRect = .{ .x = 0, .y = 0, .w = 1, .h = 1 };

/// A split's live start-child proportion, read from its GtkPaned divider so
/// manual drags are honored. Falls back to 0.5 before the paned is allocated
/// (divider unset / zero extent), which still yields correct grid geometry.
fn liveRatio(split: *const Split) f64 {
    const w = split.paned.as(gtk.Widget);
    const extent: c_int = if (split.orientation == .horizontal) w.getWidth() else w.getHeight();
    if (extent <= 0) return 0.5;
    const pos = split.paned.getPosition();
    if (pos <= 0) return 0.5;
    const r = @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(extent));
    return std.math.clamp(r, 0.05, 0.95);
}

/// Split a parent rect into its (start, end) child rects along `orientation`
/// at `ratio` (start-child proportion). Horizontal splits divide along x.
fn childRects(orientation: gtk.Orientation, rect: NRect, ratio: f64) struct { NRect, NRect } {
    if (orientation == .horizontal) {
        const lw = rect.w * ratio;
        return .{
            .{ .x = rect.x, .y = rect.y, .w = lw, .h = rect.h },
            .{ .x = rect.x + lw, .y = rect.y, .w = rect.w - lw, .h = rect.h },
        };
    } else {
        const th = rect.h * ratio;
        return .{
            .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = th },
            .{ .x = rect.x, .y = rect.y + th, .w = rect.w, .h = rect.h - th },
        };
    }
}

/// Compute the normalized rect of `target` within the subtree rooted at `node`
/// (whose own rect is `rect`). Null if `target` isn't in this subtree.
fn rectOf(node: *Node, target: *Node, rect: NRect) ?NRect {
    if (node == target) return rect;
    switch (node.*) {
        .leaf => return null,
        .split => |*s| {
            const a, const b = childRects(s.orientation, rect, liveRatio(s));
            return rectOf(s.start, target, a) orelse rectOf(s.end, target, b);
        },
    }
}

/// Running state for the directional pick: the best candidate so far and the
/// scores that beat it (more perpendicular overlap wins, then nearer).
const FocusSearch = struct {
    dir: Direction,
    from: NRect,
    from_node: *Node,
    best: ?*Node = null,
    best_overlap: f64 = -1,
    best_axial: f64 = 0,
    best_perp: f64 = 0,
};

fn overlapLen(a0: f64, a1: f64, b0: f64, b1: f64) f64 {
    return @max(0.0, @min(a1, b1) - @max(a0, b0));
}

/// Walk every leaf, computing its rect, and let `consider` score it.
fn searchDirection(node: *Node, rect: NRect, s: *FocusSearch) void {
    switch (node.*) {
        .leaf => consider(node, rect, s),
        .split => |*sp| {
            const a, const b = childRects(sp.orientation, rect, liveRatio(sp));
            searchDirection(sp.start, a, s);
            searchDirection(sp.end, b, s);
        },
    }
}

/// Score one leaf rect `r` as a directional candidate, updating `s.best`.
fn consider(node: *Node, r: NRect, s: *FocusSearch) void {
    if (node == s.from_node) return;
    const f = s.from;
    const eps = 1e-6;

    var axial: f64 = undefined;
    var overlap: f64 = undefined;
    var perp: f64 = undefined;
    switch (s.dir) {
        .left, .right => {
            // Horizontal move: candidate must be ahead on x; overlap on y.
            if (s.dir == .right) {
                if (r.cx() <= f.cx() + eps) return;
                axial = r.cx() - f.cx();
            } else {
                if (r.cx() >= f.cx() - eps) return;
                axial = f.cx() - r.cx();
            }
            overlap = overlapLen(f.y, f.y + f.h, r.y, r.y + r.h);
            perp = @abs(r.cy() - f.cy());
        },
        .up, .down => {
            // Vertical move: candidate must be ahead on y; overlap on x.
            if (s.dir == .down) {
                if (r.cy() <= f.cy() + eps) return;
                axial = r.cy() - f.cy();
            } else {
                if (r.cy() >= f.cy() - eps) return;
                axial = f.cy() - r.cy();
            }
            overlap = overlapLen(f.x, f.x + f.w, r.x, r.x + r.w);
            perp = @abs(r.cx() - f.cx());
        },
    }

    // Prefer the most perpendicular overlap, then the nearest along the axis,
    // then the nearest perpendicular center.
    const better = if (s.best == null)
        true
    else if (overlap > s.best_overlap + eps)
        true
    else if (overlap < s.best_overlap - eps)
        false
    else if (axial < s.best_axial - eps)
        true
    else if (axial > s.best_axial + eps)
        false
    else
        perp < s.best_perp;

    if (better) {
        s.best = node;
        s.best_overlap = overlap;
        s.best_axial = axial;
        s.best_perp = perp;
    }
}

/// Parse layout JSON into an arena-allocated `SerNode`. Returns null on any
/// malformed/invalid input (caller falls back to the default layout). The
/// returned node lives in `arena`; the caller owns the arena.
pub fn parseSer(arena: Allocator, bytes: []const u8) ?*SerNode {
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        bytes,
        .{ .allocate = .alloc_if_needed },
    ) catch |err| {
        log.warn("layout parse failed err={}", .{err});
        return null;
    };
    return serFromValue(arena, value) catch |err| {
        log.warn("layout structure invalid err={}", .{err});
        return null;
    };
}

fn serFromValue(arena: Allocator, value: std.json.Value) !*SerNode {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.Invalid,
    };
    const type_val = obj.get("type") orelse return error.Invalid;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return error.Invalid,
    };

    const node = try arena.create(SerNode);
    if (std.mem.eql(u8, type_str, "leaf")) {
        const role_val = obj.get("role") orelse return error.Invalid;
        const role_str = switch (role_val) {
            .string => |s| s,
            else => return error.Invalid,
        };
        // Validate the role now so a bad role fails parse (-> default).
        _ = Role.fromKey(role_str) orelse return error.Invalid;
        node.* = .{ .leaf = .{ .role = try arena.dupe(u8, role_str) } };
        return node;
    } else if (std.mem.eql(u8, type_str, "split")) {
        const orient_val = obj.get("orientation") orelse return error.Invalid;
        const orient_str = switch (orient_val) {
            .string => |s| s,
            else => return error.Invalid,
        };
        if (!std.mem.eql(u8, orient_str, "horizontal") and
            !std.mem.eql(u8, orient_str, "vertical")) return error.Invalid;

        const ratio: f64 = switch (obj.get("ratio") orelse std.json.Value{ .float = 0.5 }) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 0.5,
        };

        const start = try serFromValue(arena, obj.get("start") orelse return error.Invalid);
        const end = try serFromValue(arena, obj.get("end") orelse return error.Invalid);
        node.* = .{ .split = .{
            .orientation = try arena.dupe(u8, orient_str),
            .ratio = ratio,
            .start = start,
            .end = end,
        } };
        return node;
    }
    return error.Invalid;
}

/// Read a gtk.Paned's current divider proportion (position / max-position),
/// clamped to a sane range. Falls back to 0.5 if not yet allocated.
fn currentRatio(paned: *gtk.Paned) f64 {
    const pos = paned.getPosition();
    const max = panedIntProp(paned, "max-position");
    if (max <= 0) return 0.5;
    const r = @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(max));
    return std.math.clamp(r, 0.05, 0.95);
}

/// Read an integer GObject property off a gtk.Paned via the generic Value API.
fn panedIntProp(paned: *gtk.Paned, name: [:0]const u8) c_int {
    var val = gobject.ext.Value.new(c_int);
    defer val.unset();
    gobject.Object.getProperty(paned.as(gobject.Object), name, &val);
    return gobject.ext.Value.get(&val, c_int);
}

/// Attach a motion controller to a leaf's `box` so the pointer entering it
/// focuses `node` (focus-follows-mouse, when `follow_mouse` is on). The
/// controller is owned by the widget, so it's torn down with the box on close —
/// which happens before the node is freed in every teardown path, so the `node`
/// passed here is always live when `onLeafEnter` fires.
fn attachFollowMouse(node: *Node, box: *gtk.Box) void {
    const motion = gtk.EventControllerMotion.new();
    _ = gtk.EventControllerMotion.signals.enter.connect(motion, *Node, onLeafEnter, node, .{});
    box.as(gtk.Widget).addController(motion.as(gtk.EventController));
}

fn onLeafEnter(_: *gtk.EventControllerMotion, _: f64, _: f64, node: *Node) callconv(.c) void {
    if (!follow_mouse) return;
    if (node.* != .leaf) return; // defensive; a leaf node never changes variant
    node.leaf.pane.focus();
}

/// Wrap a pane's content widget in a vertical box with a small role header.
/// Returns both the box (parented into the tree) and its header label (kept on
/// the Leaf so the Agent-pane status badge can be updated in place).
fn labeledBox(role: Role, content: *gtk.Widget) struct { box: *gtk.Box, label: *gtk.Label } {
    const box = gtk.Box.new(.vertical, 0);
    // Every pane carries a faint base border; the active pane brightens it (see
    // the app-level CSS provider). The border width is constant, so toggling the
    // active class only changes color and never reflows the terminal grid.
    box.as(gtk.Widget).addCssClass("roost-pane");

    const label = gtk.Label.new(role.title());
    label.setXalign(0.0);
    label.as(gtk.Widget).addCssClass("heading");
    label.as(gtk.Widget).setMarginStart(8);
    label.as(gtk.Widget).setMarginEnd(8);
    label.as(gtk.Widget).setMarginTop(4);
    label.as(gtk.Widget).setMarginBottom(4);

    content.setVexpand(1);
    content.setHexpand(1);

    box.append(label.as(gtk.Widget));
    box.append(content);
    return .{ .box = box, .label = label };
}

/// Arrange for `paned` to set its divider to `ratio` of its extent as soon as
/// GTK allocates it a real size. Mirrors layout.zig's centerOnAllocate but with
/// an arbitrary ratio (used to restore persisted proportions / default 0.5).
fn applyRatioOnAllocate(paned: *gtk.Paned, ratio: f64) void {
    // Stash the desired ratio as a small heap value the handler reads + frees.
    const slot = glib.ext.create(f64);
    slot.* = ratio;
    _ = gobject.Object.signals.notify.connect(
        paned,
        *f64,
        onMaxPositionRatio,
        slot,
        .{ .detail = "max-position" },
    );
}

fn onMaxPositionRatio(paned: *gtk.Paned, _: *gobject.ParamSpec, ratio_ptr: *f64) callconv(.c) void {
    // Only set the position once (until the user drags it themselves).
    if (panedIntProp(paned, "position-set") != 0) return;
    const max = panedIntProp(paned, "max-position");
    if (max <= 0) return; // not allocated yet
    const pos: c_int = @intFromFloat(@round(@as(f64, @floatFromInt(max)) * ratio_ptr.*));
    paned.setPosition(pos);
}
