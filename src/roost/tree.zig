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

    fn orientation(self: Direction) gtk.Orientation {
        return switch (self) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };
    }

    /// Does this direction move toward the END child of a split on its axis?
    fn towardEnd(self: Direction) bool {
        return switch (self) {
            .right, .down => true,
            .left, .up => false,
        };
    }
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
                const start = try self.buildFromSer(s.start);
                const end = try self.buildFromSer(s.end);
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
        self.destroyNode(self.root);
        self.* = undefined;
    }

    fn destroyNode(self: *Tree, node: *Node) void {
        switch (node.*) {
            .leaf => |*l| l.pane.destroy(),
            .split => |*s| {
                self.destroyNode(s.start);
                self.destroyNode(s.end);
            },
        }
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

    /// Move focus one step in `dir`, walking the tree geometrically: ascend to
    /// the nearest ancestor split whose orientation matches the direction's
    /// axis and where the current subtree is on the "from" side, then descend
    /// into the sibling toward the boundary we crossed. No-op if at an edge.
    pub fn moveFocus(self: *Tree, dir: Direction) void {
        const want_axis = dir.orientation();
        const toward_end = dir.towardEnd();

        var child = self.focused;
        var parent = parentOf(self.root, child);
        while (parent) |p| {
            const split = &p.split;
            const on_start = split.start == child;
            // We can cross this split iff it's on the right axis AND moving in
            // `dir` would leave `child` for its sibling.
            if (split.orientation == want_axis and on_start == toward_end) {
                const sibling = if (on_start) split.end else split.start;
                // Descend into the sibling, entering from the boundary side:
                // moving toward end -> enter sibling from its start edge.
                const leaf = edgeLeaf(sibling, want_axis, !toward_end);
                self.focusNode(leaf);
                return;
            }
            child = p;
            parent = parentOf(self.root, p);
        }
        // At an edge in this direction; stay put.
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

    /// Close the focused leaf. Its sibling collapses up to replace the parent
    /// split. Returns `.closed_last` if this was the LAST pane (caller should
    /// quit), else `.collapsed`. Focus moves to a neighboring leaf.
    pub const CloseResult = enum { collapsed, closed_last };

    pub fn closeFocused(self: *Tree) CloseResult {
        const leaf = self.focused;
        if (leaf.* != .leaf) return .collapsed;

        const parent = parentOf(self.root, leaf) orelse {
            // Focused leaf IS the root: closing the last pane.
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

        // Tear down the focused leaf (process + node struct).
        leaf.leaf.pane.destroy();
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

/// The leaf reached by always taking the start (or end) child of splits on
/// `axis` (and the start child of off-axis splits, deterministically). Used to
/// descend into a sibling subtree when moving focus directionally.
fn edgeLeaf(node: *Node, axis: gtk.Orientation, want_end: bool) *Node {
    var cur = node;
    while (cur.* == .split) {
        const s = &cur.split;
        if (s.orientation == axis) {
            cur = if (want_end) s.end else s.start;
        } else {
            cur = s.start;
        }
    }
    return cur;
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

/// Wrap a pane's content widget in a vertical box with a small role header.
/// Returns both the box (parented into the tree) and its header label (kept on
/// the Leaf so the Agent-pane status badge can be updated in place).
fn labeledBox(role: Role, content: *gtk.Widget) struct { box: *gtk.Box, label: *gtk.Label } {
    const box = gtk.Box.new(.vertical, 0);

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
