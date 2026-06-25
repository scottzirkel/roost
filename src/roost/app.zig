//! roost application: boot, window construction, and the custom GLib main
//! loop. This evolves the original spike's proven boot/loop sequence:
//!
//!   state.init() -> App.create(alloc) -> apprt.App.init(app, .{})
//!   -> acquire default GLib MainContext
//!   -> gapp.register(...)        (fires startup -> setDefault; NO activate())
//!   -> build OUR window + 4-pane Workspace
//!   -> loop: glib.MainContext.iteration(ctx, 1); app.tick(&app_runtime)
//!      until `running` flips on window close.
//!
//! We do NOT call activate(), so Ghostty never opens a window of its own.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../apprt.zig");
const App = @import("../App.zig");
const state = &@import("../global.zig").state;

const Application = @import("../apprt/gtk/class/application.zig").Application;
const Surface = @import("../apprt/gtk/class/surface.zig").Surface;
const internal_os = @import("../os/main.zig");
const Config = @import("config.zig").Config;

const layout = @import("layout.zig");
const Workspace = layout.Workspace;
const tree = @import("tree.zig");
const project = @import("project.zig");
const Project = project.Project;
const ipc = @import("ipc.zig");
const git = @import("git.zig");

const log = std.log.scoped(.roost);

/// Process-lifetime context shared with GTK signal handlers (C callbacks). It
/// holds the few things the project picker needs to rebuild the workspace in a
/// new directory. It lives in `run`'s stack frame, which outlives the run loop,
/// so a pointer to it is valid for the lifetime of every handler we connect.
const AppContext = struct {
    alloc: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    /// Command the Git pane runs (lazygit or null=shell). Reused on rebuild.
    git_cmd: ?[:0]const u8,
    /// Command the Agent pane runs (claude/$ROOST_AGENT, or null=shell).
    /// Reused on rebuild so a re-opened project keeps the real agent.
    agent_cmd: ?[:0]const u8,
    /// Stable storage for the live workspace. Shortcut actions capture this
    /// pointer; rebuilds mutate `workspace.*` in place so they stay valid.
    workspace: *Workspace,
    /// User settings (audio, scratchpad persistence). Lives in the run frame;
    /// the settings UI mutates it in place and calls `Config.save`.
    config: *Config,
    /// The current project. Owns its path; replaced (old freed) on rebuild.
    current: Project,
    /// One-shot bypass for the quit confirmation: `onWindowCloseRequest` vetoes
    /// the first close and asks; the confirm handler sets this and re-issues the
    /// close, which then proceeds. Also set when closing the last pane (the user
    /// already acted on it), so Ctrl+W doesn't double-prompt.
    quit_confirmed: bool = false,
};

/// Whether our custom event loop should keep running. Module-level because the
/// GTK signal handlers / GActions are C callbacks and flipping a global is the
/// simplest clean-shutdown signal for the loop.
var running: bool = true;

/// Our dedicated GTK application id — the single source of truth for the
/// in-process `--class` injection below. The desktop file's StartupWMClass and
/// the notification ThemedIcon (ipc.zig) must match this exact string.
const app_id = "dev.scottzirkel.Roost";

/// Flags we force into our own argv before apprt parses config from it:
///   - `--class=<app_id>`: adopt our dedicated GTK app id instead of Ghostty's
///     default `com.mitchellh.ghostty[-debug]`.
///   - `--keybind=ctrl+shift+q=unbind`: drop Ghostty's built-in `ctrl+shift+q →
///     quit` so our window accelerator (`win.reload`) can claim that chord. The
///     terminal surface consumes keys it has bindings for before our GTK accels
///     fire, so without this, Ctrl+Shift+Q never reaches reload. Roost has its
///     own quit on Ctrl+Q, so removing Ghostty's is no loss — and this only
///     touches roost's argv, never the user's real Ghostty.
///   - `--keybind=ctrl+,=unbind`: drop Ghostty's built-in `ctrl+, → open_config`
///     so Ctrl+, opens Roost's own Settings dialog instead. Like ctrl+shift+q,
///     the terminal surface consumes the chord before our window accelerator, so
///     without this the keystroke opens Ghostty's config rather than Settings.
///     The trigger MUST be the unicode `,` (not the physical-key name `comma`,
///     which parses to a different trigger and would not match Ghostty's default
///     `.unicode=','` binding). (The gear header-bar button is action-based and
///     works regardless; this is only for the keyboard accelerator.)
///   - `--desktop-notifications=false`: suppress Ghostty's OSC 9 / OSC 777
///     desktop notifications. The agent (`claude`) emits such an escape on a
///     Stop/needs-input event AND our `roost-notify` Claude Code hook fires a
///     richer `gio.Notification` (custom title/body + themed icon, plus the
///     Agent-pane status badge) over `ROOST_SOCK`. Without this, an event pops
///     TWO native notifications; we keep Roost's and drop Ghostty's. The core
///     Surface honors this flag and drops the OSC before it reaches the apprt
///     (`Surface.zig` `desktop_notification` branch), so nothing renders.
const injected_flags = [_][:0]const u8{
    "--class=" ++ app_id,
    "--keybind=ctrl+shift+q=unbind",
    "--keybind=ctrl+,=unbind",
    "--desktop-notifications=false",
};

/// Append any `injected_flags` not already present to `std.os.argv` (idempotent,
/// so it's safe across a reload re-exec, which reuses the already-injected argv).
/// We reassign `std.os.argv` rather than edit Ghostty source (keeps the additive
/// gate clean). Best-effort: on alloc failure argv is left untouched.
fn injectArgs(alloc: std.mem.Allocator) void {
    const old = std.os.argv;
    var missing: [injected_flags.len]bool = undefined;
    var n: usize = 0;
    for (injected_flags, 0..) |flag, i| {
        missing[i] = for (old) |a| {
            if (std.mem.eql(u8, std.mem.span(a), flag)) break false;
        } else true;
        if (missing[i]) n += 1;
    }
    if (n == 0) return;
    const new = alloc.alloc([*:0]u8, old.len + n) catch return;
    @memcpy(new[0..old.len], old);
    var idx = old.len;
    for (injected_flags, 0..) |flag, i| {
        if (missing[i]) {
            new[idx] = @constCast(flag.ptr);
            idx += 1;
        }
    }
    std.os.argv = new;
}

pub fn run() !void {
    // 1. Global process-level state (mirrors main_ghostty.zig).
    state.init() catch |err| {
        log.err("failed to initialize global state err={}", .{err});
        posix.exit(1);
    };
    defer state.deinit();
    const alloc = state.alloc;

    // 1b. Inject our forced flags (see injectArgs): `--class` for the app id and
    //     `--keybind=ctrl+shift+q=unbind` so reload can use Ctrl+Shift+Q. Must
    //     run BEFORE apprt init loads config from argv.
    injectArgs(alloc);

    if (comptime builtin.mode == .Debug) {
        log.warn("This is a debug build. Performance will be very poor.", .{});
    }

    // 2. Core (libghostty) App + GTK runtime App. The runtime init instantiates
    //    the GObject `Application` (loads config, registers GResources for the
    //    Surface Blueprint templates).
    const app: *App = try App.create(alloc);
    defer app.destroy();

    var app_runtime: apprt.App = undefined;
    try app_runtime.init(app, .{});
    defer app_runtime.terminate();

    const gapp: *Application = app_runtime.app;

    // 3. Acquire the default GLib main context for this thread.
    const ctx = glib.MainContext.default();
    if (glib.MainContext.acquire(ctx) == 0) return error.ContextAcquireFailed;
    defer {
        gio.Settings.sync();
        while (glib.MainContext.iteration(ctx, 0) != 0) {}
        glib.MainContext.release(ctx);
    }

    // 4. Register the GApplication. Fires `startup` (which calls setDefault so
    //    Application.default() works and Surfaces can pull config). We do NOT
    //    call activate(), which is what would open Ghostty's own window.
    var err_: ?*glib.Error = null;
    if (gapp.as(gio.Application).register(null, &err_) == 0) {
        if (err_) |e| {
            defer e.free();
            log.err("error registering application: {s}", .{e.f_message orelse "(unknown)"});
        }
        return error.ApplicationRegisterFailed;
    }
    std.debug.assert(err_ == null);

    // 4b. Single-instance forwarding. If another roost already holds the app
    //     ID we are the REMOTE process (only possible when single-instance is on,
    //     i.e. a desktop launch). Ask the primary to show its project chooser via
    //     an app-level GAction (forwarded over D-Bus), flush so the message is
    //     actually sent, then exit WITHOUT building a window. We deliberately do
    //     NOT use activate(): Ghostty's Application overrides it to open a window.
    if (gapp.as(gio.Application).getIsRemote() != 0) {
        log.info("remote instance: asking primary to present the chooser, then exiting", .{});
        gapp.as(gio.Application).as(gio.ActionGroup).activateAction("present-chooser", null);
        if (gapp.as(gio.Application).getDbusConnection()) |conn| {
            _ = conn.flushSync(null, null);
        }
        return;
    }

    // 5. Build our window.
    const window = gobject.ext.newInstance(gtk.ApplicationWindow, .{
        .application = gapp.as(gtk.Application),
    });
    window.as(gtk.Window).setTitle("Roost");
    // A generous default size so all four quadrants are usable on first launch
    // (the Git/lazygit pane in particular needs real height, or lazygit prints
    // "Not enough space to render panels"). We also maximize on present below
    // so the very first frame uses the whole monitor where the WM allows it.
    window.as(gtk.Window).setDefaultSize(1600, 1000);

    // Load Roost's user settings (agent, audio, scratchpad persistence). Lives
    // in this frame for the whole run; the settings UI mutates it via `&cfg` and
    // saves. Loaded BEFORE the agent command so `agent` can feed resolveAgentCmd.
    var cfg = Config.load(alloc);
    defer cfg.deinit();
    // Apply the persisted focus-follows-mouse preference before any pane is
    // built, so the initial state (and the stateful action below) match config.
    tree.setFollowMouse(cfg.focus_follows_mouse);

    // 6. Build the role-typed 4-pane workspace. Git pane runs lazygit if it's
    //    on PATH, else the user's shell (so the demo shows no error cards).
    const git_cmd: ?[:0]const u8 = if (lazygitAvailable()) "lazygit" else null;
    if (git_cmd != null) {
        log.info("git pane: lazygit found on PATH", .{});
    } else {
        log.info("git pane: lazygit not found, falling back to shell", .{});
    }

    // Resolve the Agent pane command: prefer $ROOST_AGENT, else the configured
    // `agent` (default `claude`); run it only if it's on PATH, otherwise fall
    // back to the user's shell (null). Snapshotted into a process-lifetime copy
    // so a later Settings edit to `cfg.agent` can't dangle the spawned panes.
    const agent_cmd: ?[:0]const u8 = resolveAgentCmd(alloc, cfg.agent);
    if (agent_cmd) |c| {
        log.info("agent pane: running '{s}'", .{c});
    } else {
        log.info("agent pane: no agent command on PATH, falling back to shell", .{});
    }

    // Resolve the project directory: ROOST_PROJECT env var (if it's a real
    // directory) -> the process cwd (where `roost` was launched) -> null
    // (panes inherit Ghostty's default). We use an env var rather than a
    // positional CLI arg because Ghostty's own config loader parses argv and
    // would reject a bare path as an invalid config field. All terminal panes,
    // including the Git/lazygit pane, launch here, so lazygit sees the repo.
    // `Surface.new` dupes the cwd string, so the Project may move/free freely
    // afterward.
    // A desktop relaunch while another roost is already running opens the
    // project CHOOSER (each window picks its own project) instead of auto-
    // opening the last project. A first launch (no sibling) still opens the
    // last project directly. CLI launches (ROOST_PROJECT/cwd) are unaffected.
    const open_chooser_on_start = blk: {
        const has_env = if (std.posix.getenv("ROOST_PROJECT")) |v| v.len > 0 else false;
        break :blk internal_os.launchedFromDesktop() and !has_env and ipc.liveSiblingExists();
    };
    const project_dir: ?Project = if (open_chooser_on_start) null else resolveInitialProject(alloc);

    const pane_cwd: ?[:0]const u8 = if (project_dir) |p| p.path else null;
    if (project_dir) |p| project.recordRecent(alloc, p.path);

    // Reflect the project in the window title.
    setWindowTitle(alloc, window, project_dir);

    // Load any saved layout. Parsed into an arena that must outlive
    // Workspace.init (which reads the SerNode tree); we free it right after.
    // A missing/malformed file yields `null` -> the default 2x2.
    var layout_arena = std.heap.ArenaAllocator.init(alloc);
    const saved: ?*const tree.SerNode = blk: {
        const bytes = project.readLayout(alloc, pane_cwd orelse "") orelse break :blk null;
        defer alloc.free(bytes);
        break :blk tree.parseSer(layout_arena.allocator(), bytes);
    };
    if (saved != null) log.info("restoring saved layout", .{});

    // 6b. roost IPC socket. Create + listen BEFORE building the workspace so
    //     ROOST_SOCK is exported into the environment that every spawned pane
    //     (including the `claude` Agent pane) inherits. The server runs on the
    //     default GLib main context our loop already pumps — no extra thread.
    //
    //     `workspace` is declared undefined here and filled just below; the
    //     server only dereferences `&workspace` when an event fires, which can
    //     only happen once we're in the run loop (after the assignment). The
    //     stack address of `workspace` is stable for the whole run.
    var workspace: Workspace = undefined;
    var server: ipc.Server = undefined;
    var have_server = false;
    if (server.init(alloc, gapp, &workspace)) {
        have_server = true;
    } else |err| {
        log.warn("ipc socket unavailable (agent notifications disabled) err={}", .{err});
    }
    defer if (have_server) server.deinit();

    workspace = Workspace.init(alloc, git_cmd, agent_cmd, pane_cwd, saved);
    layout_arena.deinit(); // SerNode no longer needed once the tree is built
    workspace.window = window.as(gtk.Window); // for live-focus sync on ops
    window.as(gtk.Window).setChild(workspace.root);

    // Shared context for handlers that need to rebuild the workspace (the
    // project picker). Lives in this frame for the whole run loop. It owns the
    // resolved Project; a sentinel-pathed empty Project stands in if resolution
    // failed so the field is always a valid (freeable) value.
    var app_ctx: AppContext = .{
        .alloc = alloc,
        .window = window,
        .git_cmd = git_cmd,
        .agent_cmd = agent_cmd,
        .workspace = &workspace,
        .config = &cfg,
        .current = project_dir orelse .{ .alloc = alloc, .path = "" },
    };
    defer if (app_ctx.current.path.len > 0) app_ctx.current.deinit();

    // 7. Wire close affordances so nothing is dead.
    //
    //    (a) A `win.close` GAction on the window. GTK windows expose the `win`
    //        action group automatically, so `win.close` is reachable from any
    //        accelerator/menu wired to it. Activating it closes the window.
    const close_action = gio.SimpleAction.new("close", null);
    defer close_action.unref();
    _ = gio.SimpleAction.signals.activate.connect(
        close_action,
        *gtk.Window,
        onCloseAction,
        window.as(gtk.Window),
        .{},
    );
    window.as(gio.ActionMap).addAction(close_action.as(gio.Action));

    //    (b) The window's own close-request (title-bar close, cmd/ctrl-driven
    //        close, Ctrl+Q via win.close) saves the layout, flips our run loop
    //        off, and lets GTK destroy the window.
    _ = gtk.Window.signals.close_request.connect(
        window.as(gtk.Window),
        *AppContext,
        onWindowCloseRequest,
        &app_ctx,
        .{},
    );

    //    (b2) The window's focus widget changing drives the active-pane
    //         indicator. One handler covers every path that moves GTK focus —
    //         mouse clicks, keyboard nav actions, and programmatic grabs (split/
    //         close all route through `pane.focus()` -> `grabFocus`). `&workspace`
    //         is updated in place across project rebuilds, so it always reflects
    //         the live tree.
    _ = gobject.Object.signals.notify.connect(
        window,
        *Workspace,
        onWindowFocusChanged,
        &workspace,
        .{ .detail = "focus-widget" },
    );

    //    (c) Each terminal surface's `close-request`: a pane's child process
    //        exiting (or the user clicking the "process exited" Close button)
    //        auto-closes just that pane (`onSurfaceCloseRequest`), collapsing its
    //        sibling up. Closing the last pane quits. The stable `&app_ctx` is
    //        passed through so the handler can map the surface back to its pane.
    workspace.connectCloseRequests(onSurfaceCloseRequest, &app_ctx);

    // 7b. Keyboard shortcuts. We mirror Ghostty's own approach (see
    //     application.zig `syncActionAccelerator`): register `gio.SimpleAction`s
    //     on the window's `win` action group, then bind accelerators to their
    //     detailed `win.<name>` action strings via the GtkApplication. The
    //     SimpleActions are owned by the window's ActionMap after `addAction`.
    const gtk_app = gapp.as(gtk.Application);
    setupShortcuts(window, gtk_app, &workspace, &app_ctx);

    // Header bar (set after shortcuts so its buttons' actions exist). It's the
    // window titlebar, so it persists across workspace rebuilds. Register our
    // bundled icons first so the bar's split buttons can resolve them.
    registerBundledIcons(window);
    installHeaderBar(window);

    // 8. Present and focus the first leaf (the default 2x2 makes that the Agent
    //    pane; a restored layout focuses whatever leaf comes first in tree
    //    order). We do NOT force-maximize: on a tiling WM (Hyprland) the window
    //    is tiled to the user's own layout/rules anyway, and on a floating WM it
    //    opens at the generous setDefaultSize above. Divider positions are
    //    restored/centered by the tree once GTK has allocated each Paned (see
    //    tree.zig applyRatioOnAllocate).
    window.as(gtk.Window).present();
    installPaneCss(window);
    workspace.focusIndex(0);
    workspace.updateHighlight();

    // Desktop launch that resolved no last project (e.g. first-ever run): pop the
    // chooser so the user can pick a recent or open/create one.
    if (project_dir == null and internal_os.launchedFromDesktop()) {
        presentChooser(&app_ctx);
    }

    // 9. Run our own loop, ticking the core app each iteration.
    log.debug("entering roost runloop", .{});
    while (running) {
        _ = glib.MainContext.iteration(ctx, 1);
        try app.tick(&app_runtime);
    }
    log.debug("exiting roost runloop", .{});
}

/// Returns true if `lazygit` is found (and executable) on PATH. Reuses
/// Ghostty's PATH-resolution helper; any error or miss returns false.
fn lazygitAvailable() bool {
    return commandOnPath("lazygit");
}

/// Returns true if `cmd` resolves to an executable on PATH. Reuses Ghostty's
/// PATH-resolution helper; any error or miss returns false.
fn commandOnPath(cmd: [:0]const u8) bool {
    const alloc = state.alloc;
    const found = internal_os.path.expand(alloc, cmd) catch return false;
    if (found) |p| {
        alloc.free(p);
        return true;
    }
    return false;
}

/// Resolve the Agent pane command: `$ROOST_AGENT` if set, else `configured`
/// (the `agent` setting, default `claude`). The resolved command is used ONLY if
/// it is found on PATH; otherwise we return null so the Agent pane falls back to
/// the user's shell. Returns a process-lifetime copy (owned by `alloc`, never
/// freed): `configured` is owned by the live Config and may be replaced when the
/// user edits the agent in Settings, but the panes were spawned with this value,
/// so we keep a stable snapshot.
fn resolveAgentCmd(alloc: std.mem.Allocator, configured: [:0]const u8) ?[:0]const u8 {
    const cmd: [:0]const u8 = std.posix.getenv("ROOST_AGENT") orelse configured;
    if (cmd.len == 0) return null;
    if (!commandOnPath(cmd)) return null;
    return alloc.dupeZ(u8, cmd) catch cmd;
}

/// Resolve the project to open on launch.
///   - `ROOST_PROJECT` set, or a terminal launch → `Project.resolve`
///     (env var → cwd), i.e. open the directory we were launched in.
///   - A desktop launch with NO explicit project → the most-recent *existing*
///     project from the recents list (the "last project"); null if none, in
///     which case `run` pops the chooser.
fn resolveInitialProject(alloc: std.mem.Allocator) ?Project {
    const has_env = if (std.posix.getenv("ROOST_PROJECT")) |v| v.len > 0 else false;

    if (!has_env and internal_os.launchedFromDesktop()) {
        const recents = project.readRecents(alloc) catch return null;
        defer {
            for (recents) |r| alloc.free(r);
            alloc.free(recents);
        }
        for (recents) |r| {
            if (Project.fromPath(alloc, r)) |p| return p else |_| {}
        }
        return null;
    }

    return Project.resolve(alloc) catch |err| {
        log.warn("could not resolve project dir, panes inherit default cwd err={}", .{err});
        return null;
    };
}

/// `win.close` GAction handler: ask the window to close.
fn onCloseAction(_: *gio.SimpleAction, _: ?*glib.Variant, window: *gtk.Window) callconv(.c) void {
    window.close();
}

/// Window `notify::focus-widget` handler: the GTK focus moved, so re-point the
/// active-pane highlight at whichever pane now holds focus. Covers mouse clicks,
/// keyboard nav, and programmatic grabs alike (all change the window's focus
/// widget). `ws` is `&workspace`, updated in place across rebuilds.
fn onWindowFocusChanged(_: *gtk.ApplicationWindow, _: *gobject.ParamSpec, ws: *Workspace) callconv(.c) void {
    ws.updateHighlight();
}

/// Bytes of the GResource holding Roost's bundled symbolic icons, compiled by
/// build.sh (glib-compile-resources) and embedded so the binary is self-
/// contained — Roost never depends on the user's installed icon theme.
const bundled_icons = @embedFile("icons.gresource");

/// Register the bundled icons so the icon theme resolves them by name (with the
/// usual symbolic recoloring). Call once, before building the header bar.
fn registerBundledIcons(window: *gtk.ApplicationWindow) void {
    const data = glib.Bytes.new(bundled_icons.ptr, bundled_icons.len);
    defer data.unref();
    var gerr: ?*glib.Error = null;
    const resource = gio.Resource.newFromData(data, &gerr) orelse {
        if (gerr) |e| {
            log.warn("could not load bundled icons: {s}", .{e.f_message orelse "(unknown)"});
            e.free();
        }
        return;
    };
    gio.resourcesRegister(resource);
    const theme = gtk.IconTheme.getForDisplay(window.as(gtk.Widget).getDisplay());
    theme.addResourcePath("/dev/scottzirkel/roost/icons");
}

/// Build the window's header bar: split-right/down on the left, then Help + a
/// Settings (cog) button on the right, each wired to its `win.*` action. Set as
/// the window titlebar so it persists across workspace rebuilds (which only swap
/// the child). Focus-follows-mouse lives in Settings now (and Ctrl+Shift+M), so
/// it no longer needs its own header button.
fn installHeaderBar(window: *gtk.ApplicationWindow) void {
    const bar = gtk.HeaderBar.new();
    // Hide the CSD min/max/close controls: on a tiling WM the WM + Ctrl+Q manage
    // the window, and it keeps the bar minimal.
    bar.setShowTitleButtons(0);

    // Layout actions on the LEFT: split the focused pane right / down. The arrow
    // points where the new pane lands. (Yaru/Adwaita lack a clean split glyph, so
    // we use reliable directional arrows + tooltips.)
    const split_r = gtk.Button.new();
    split_r.setIconName("roost-split-right-symbolic");
    split_r.as(gtk.Widget).setTooltipText("Add pane right (Ctrl+Shift+R)");
    split_r.as(gtk.Actionable).setActionName("win.split-h");
    bar.packStart(split_r.as(gtk.Widget));

    const split_d = gtk.Button.new();
    split_d.setIconName("roost-split-down-symbolic");
    split_d.as(gtk.Widget).setTooltipText("Add pane down (Ctrl+Shift+D)");
    split_d.as(gtk.Actionable).setActionName("win.split-v");
    bar.packStart(split_d.as(gtk.Widget));

    // Right side: Help then Settings (cog). packEnd stacks right-to-left, so to
    // read "Help, cog" left-to-right we pack the cog first (rightmost), then Help.
    const settings = gtk.Button.new();
    settings.setIconName("roost-settings-symbolic");
    settings.as(gtk.Widget).setTooltipText("Settings (Ctrl+,)");
    settings.as(gtk.Actionable).setActionName("win.show-settings");
    bar.packEnd(settings.as(gtk.Widget));

    const help = gtk.Button.new();
    help.setIconName("roost-help-symbolic");
    help.as(gtk.Widget).setTooltipText("Keyboard shortcuts (Ctrl+Shift+/)");
    help.as(gtk.Actionable).setActionName("win.show-help");
    bar.packEnd(help.as(gtk.Widget));

    window.as(gtk.Window).setTitlebar(bar.as(gtk.Widget));
}

/// Install the app-level CSS for the pane frames + active-pane indicator. Every
/// leaf box carries `.roost-pane` (a faint, constant-width border); the focused
/// pane also carries `.roost-active`, which only brightens the border color — no
/// size change, so the terminal grid never reflows when focus moves. Registered
/// once on the window's display; GTK keeps a single provider per display.
fn installPaneCss(window: *gtk.ApplicationWindow) void {
    const css =
        \\.roost-pane { border: 1px solid rgba(255, 255, 255, 0.06); }
        \\.roost-pane.roost-active { border-color: rgba(255, 255, 255, 0.26); }
    ;
    const provider = gtk.CssProvider.new();
    defer provider.unref(); // the display takes its own ref in addProviderForDisplay
    const bytes = glib.Bytes.new(css.ptr, css.len);
    defer bytes.unref();
    provider.loadFromBytes(bytes);
    gtk.StyleContext.addProviderForDisplay(
        window.as(gtk.Widget).getDisplay(),
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 10,
    );
}

/// Window `close-request` handler. Both Ctrl+Q (`win.close`) and the WM close
/// button funnel through here, so it's the one place to gate quitting. We veto
/// the first request and show an unconditional confirmation; on confirm,
/// `doQuit` sets `quit_confirmed` and re-issues the close, which lands back here
/// and proceeds: save the layout, flip the loop off, and return false (0) so the
/// default handler destroys the window. The deferred MainContext drain in `run`
/// lets renderer/IO threads exit cleanly.
fn onWindowCloseRequest(_: *gtk.Window, app_ctx: *AppContext) callconv(.c) c_int {
    if (!app_ctx.quit_confirmed) {
        confirmDestructive(
            app_ctx,
            "Quit Roost?",
            "This closes the window and ends everything running in it.",
            "Quit",
            doQuit,
            true, // Quit is the default → Ctrl+Q then Enter quits.
        );
        return @intFromBool(true); // veto: keep the window open behind the dialog
    }
    saveLayout(app_ctx);
    running = false;
    return @intFromBool(false);
}

/// Accept handler for the quit confirmation: authorize the close and re-issue
/// it. The re-issued close-request sees `quit_confirmed` and tears down.
fn doQuit(a: *AppContext) void {
    a.quit_confirmed = true;
    a.window.as(gtk.Window).close();
}

/// `win.reload` (Ctrl+Shift+Q): restart into the latest built binary. Native code
/// can't hot-swap, so "reload" = RE-EXEC in place: persist the layout, then
/// `execve` our own freshly-built exe (which `./build.sh` overwrites in place),
/// reusing our LIVE argv so the single-instance mode and injected `--class`
/// carry over verbatim. Re-exec keeps our PID — no second process to race, no
/// flag string to corrupt, no spawn-then-quit timing, no single-instance
/// forwarding (all of which made the earlier spawn-a-new-window approach flaky).
/// The new image reads the layout we just wrote, so the arrangement (roles,
/// splits, sizes) is restored; pane child processes die as their PTYs close on
/// exec — unavoidable across a restart, and the point of a "reload". On exec
/// failure we log and stay put rather than leave the user with nothing.
fn onReload(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    // Reload ends everything running in this window's panes, so confirm first.
    // Cancel is the default (Esc/Enter cancels) — a stray Ctrl+Shift+Q must not
    // nuke a live session by reflex.
    confirmDestructive(
        a,
        "Reload Roost?",
        "Restarts this window into the latest build. Panes reopen from the saved layout, but anything running in them (shells, the agent) ends.",
        "Reload",
        doReload,
        false,
    );
}

/// Confirmed reload: persist the layout, then re-exec into the latest build.
fn doReload(a: *AppContext) void {
    saveLayout(a);
    log.info("reloading roost (re-exec into latest build)", .{});
    reExecSelf(a) catch |err| {
        log.warn("reload failed; staying put err={}", .{err});
        return;
    };
    // execve does not return on success — anything past here means it failed.
}

/// Replace this process image with our freshly-built exe (see `onReload`).
/// Returns only on failure; on success `execve` never returns.
fn reExecSelf(a: *AppContext) !void {
    const alloc = a.alloc;
    // Keep the same project across the swap (mirrors openProjectNewWindow's env).
    if (a.current.path.len > 0) _ = internal_os.setenv("ROOST_PROJECT", a.current.path);

    // Re-exec the path we were LAUNCHED from (argv[0]), reusing our live argv so
    // the single-instance mode + injected `--class` carry over verbatim. We must
    // NOT use /proc/self/exe (std.fs.selfExePath): once `./build.sh` replaces the
    // binary, that link resolves to the deleted old inode ("… (deleted)") and
    // execve fails with FileNotFound. argv[0] is a plain path string, so it still
    // points at the freshly-built file at that location.
    const argc = std.os.argv.len;
    const argv = try alloc.allocSentinel(?[*:0]const u8, argc, null);
    defer alloc.free(argv);
    var i: usize = 0;
    while (i < argc) : (i += 1) argv[i] = std.os.argv[i];

    return std.posix.execvpeZ(std.os.argv[0], argv.ptr, std.c.environ);
}

/// Serialize the current workspace tree to the layout file keyed by the current
/// project path (per-worktree persistence). Best-effort.
fn saveLayout(app_ctx: *AppContext) void {
    const bytes = app_ctx.workspace.serialize(app_ctx.alloc) catch |err| {
        log.warn("could not serialize layout err={}", .{err});
        return;
    };
    defer app_ctx.alloc.free(bytes);
    project.writeLayout(app_ctx.alloc, app_ctx.current.path, bytes);
}

/// Surface `close-request` handler: auto-close the pane when its child process
/// exits (Ghostty emits this after the child dies), and when the user clicks the
/// "process exited" overlay's Close button (same signal). The pane collapses and
/// its sibling fills the space.
///
/// Our OWN teardown (`TerminalPane.destroy` → `surface.close()`) re-emits this
/// signal too; `isTearingDown` is set during those so we ignore them and never
/// double-free. `data` is the stable `*AppContext`.
fn onSurfaceCloseRequest(surface: *Surface, data: ?*anyopaque) callconv(.c) void {
    const a: *AppContext = @ptrCast(@alignCast(data orelse return));
    if (a.workspace.isTearingDown()) return;
    const result = a.workspace.closeSurface(surface) orelse return;
    switch (result) {
        .closed_last => {
            // The only pane's process exited — nothing left to show. Quit
            // without the confirmation (the user didn't ask; the process ended).
            a.quit_confirmed = true;
            a.window.as(gtk.Window).close();
        },
        .collapsed => saveLayout(a),
    }
}

// --- Keyboard shortcuts ---------------------------------------------------
//
// FULL KEYBINDING LIST (all `win.*` GActions + accelerators):
//
//   Focus:
//     Alt+1 .. Alt+9            focus the Nth leaf in tree order (roles are no
//                               longer unique, so we index by position)
//     Ctrl+Alt+Left/Right/Up/Down   directional focus (spatial, Hyprland-style)
//     Ctrl+Shift+Alt+Left/Right/Up/Down  swap focused pane with that neighbor
//                               (focus follows the moved pane)
//     Ctrl+Shift+Left/Right/Up/Down  resize focused pane by nudging the nearest
//                               same-orientation divider IN the arrow direction
//                               (Up grows a bottom pane / shrinks a top one);
//                               no-op if the pane spans that axis. Not persisted
//                               per-keystroke (like a manual divider drag).
//     NOTE: every directional binding above also accepts vim hjkl in place of
//     the arrow (h=Left, j=Down, k=Up, l=Right), same modifiers.
//
//   Tree ops:
//     Ctrl+Shift+R              split focused pane horizontally (new pane to
//                               the Right; new pane = shell)
//     Ctrl+Shift+D              split focused pane vertically  (new pane Down;
//                               new pane = shell)
//     Ctrl+Shift+Alt+R          split the focused pane's whole COLUMN/ROW as a
//                               unit, new pane to the Right (independent divider)
//     Ctrl+Shift+Alt+D          same, vertically (new full-width row Down)
//     Ctrl+W                    close focused pane (sibling collapses up); if
//                               it was the last pane, quit cleanly. Confirms
//                               first if the focused pane is a running agent.
//
//   Add a pane by role (each adds a new pane below the focused one):
//     Ctrl+Shift+A              add Agent
//     Ctrl+Shift+S              add Shell
//     Ctrl+Shift+G              add Git
//     Ctrl+Shift+E              add Editor
//     Ctrl+Shift+N              add scratchpad (Notes)
//
//   Cross-pane:
//     Ctrl+Return               send-to-agent: from a focused SCRATCHPAD, send
//                               the selection (else the current line) into the
//                               first Agent terminal pane (fallback: first
//                               terminal of any role), then focus it. No trailing
//                               newline is added (review/submit in the agent).
//
//   Git/worktree:
//     Ctrl+Shift+B              create a new branch + worktree (sibling dir
//                               <repo>.worktrees/<branch>) and switch into it
//
//   App:
//     Ctrl+Alt+R                reset layout to the default 2x2 (current
//                               project); confirms first if any pane is a
//                               running agent
//     Ctrl+O                    open the project/worktree chooser (recents +
//                               worktrees + open/create); pick a row → confirm
//                               (Switch / Open in New Window / Cancel)
//     Ctrl+Q                    quit (confirms first, Quit is the default so
//                               Enter quits; saves layout)
//     Ctrl+Shift+/  (Ctrl+?)    show the keyboard cheat-sheet (this list, as a
//                               modal grouped by section)
//     Ctrl+Shift+M              toggle focus-follows-mouse (on by default: the
//                               pointer entering a pane focuses it)
//
// Collision notes: Ctrl+Shift+{R,D,A,S,G,E,N,W,B} and Ctrl+Alt+arrows avoid the
// common shell/vim/lazygit single-key and Ctrl-only bindings. Ctrl+W is the
// conventional "close pane" and is intercepted by us before the terminal.

/// Register all window-level shortcuts. Mechanism (unchanged): one
/// `gio.SimpleAction` per command on the window's `win` group, each bound to an
/// accelerator via `gtk.Application.setAccelsForAction("win.<name>", accels)`.
fn setupShortcuts(
    window: *gtk.ApplicationWindow,
    gtk_app: *gtk.Application,
    _: *Workspace,
    app_ctx: *AppContext,
) void {
    const map = window.as(gio.ActionMap);

    // Focus by leaf index: Alt+1..9.
    inline for (.{
        .{ "focus-1", onFocus1 }, .{ "focus-2", onFocus2 },
        .{ "focus-3", onFocus3 }, .{ "focus-4", onFocus4 },
        .{ "focus-5", onFocus5 }, .{ "focus-6", onFocus6 },
        .{ "focus-7", onFocus7 }, .{ "focus-8", onFocus8 },
        .{ "focus-9", onFocus9 },
    }) |pair| addAction(map, pair[0], pair[1], app_ctx);

    // Directional focus movement: Ctrl+Alt+Arrow.
    addAction(map, "focus-left", onFocusLeft, app_ctx);
    addAction(map, "focus-right", onFocusRight, app_ctx);
    addAction(map, "focus-up", onFocusUp, app_ctx);
    addAction(map, "focus-down", onFocusDown, app_ctx);

    // Swap the focused pane with its neighbor: Ctrl+Shift+Alt+Arrow.
    addAction(map, "swap-left", onSwapLeft, app_ctx);
    addAction(map, "swap-right", onSwapRight, app_ctx);
    addAction(map, "swap-up", onSwapUp, app_ctx);
    addAction(map, "swap-down", onSwapDown, app_ctx);

    // Resize the focused pane: Ctrl+Shift+Arrow (mini-Hyprland keymap).
    addAction(map, "resize-left", onResizeLeft, app_ctx);
    addAction(map, "resize-right", onResizeRight, app_ctx);
    addAction(map, "resize-up", onResizeUp, app_ctx);
    addAction(map, "resize-down", onResizeDown, app_ctx);

    // Splits + close.
    addAction(map, "split-h", onSplitH, app_ctx);
    addAction(map, "split-v", onSplitV, app_ctx);
    // Group splits: split the focused pane's whole column/row as a unit.
    addAction(map, "split-group-h", onSplitGroupH, app_ctx);
    addAction(map, "split-group-v", onSplitGroupV, app_ctx);
    addAction(map, "close-pane", onClosePane, app_ctx);

    // Add a pane by role.
    addAction(map, "add-agent", onAddAgent, app_ctx);
    addAction(map, "add-shell", onAddShell, app_ctx);
    addAction(map, "add-git", onAddGit, app_ctx);
    addAction(map, "add-editor", onAddEditor, app_ctx);
    addAction(map, "add-scratchpad", onAddScratchpad, app_ctx);

    // Reset the whole layout to the default 2x2.
    addAction(map, "reset-layout", onResetLayout, app_ctx);

    // Reload: restart into the latest built binary (Ctrl+Shift+Q).
    addAction(map, "reload", onReload, app_ctx);

    // Open the project/worktree chooser (Ctrl+O). App-level (on the GApplication,
    // not the window) so a remote second desktop launch can forward to it.
    addAction(gtk_app.as(gio.Application).as(gio.ActionMap), "present-chooser", onPresentChooser, app_ctx);

    // Create a new worktree+branch and switch into it (Ctrl+Shift+B).
    addAction(map, "create-worktree", onCreateWorktree, app_ctx);

    // Cross-pane: send scratchpad text to the agent (Ctrl+Return).
    addAction(map, "send-to-agent", onSendToAgent, app_ctx);

    // Keyboard cheat-sheet (Ctrl+Shift+/).
    addAction(map, "show-help", onShowHelp, app_ctx);

    // Settings dialog (Ctrl+,).
    addAction(map, "show-settings", onShowSettings, app_ctx);

    // Toggle focus-follows-mouse (Ctrl+Shift+M). STATEFUL boolean action so the
    // header-bar toggle button and the accelerator share one source of truth.
    {
        const ffm = gio.SimpleAction.newStateful(
            "toggle-follow-mouse",
            null,
            glib.Variant.newBoolean(@intFromBool(tree.followMouseEnabled())),
        );
        defer ffm.unref();
        _ = gio.SimpleAction.signals.activate.connect(ffm, *AppContext, onToggleFollowMouse, app_ctx, .{});
        map.addAction(ffm.as(gio.Action));
    }

    // Accelerators.
    setAccel(gtk_app, "win.focus-1", "<Alt>1");
    setAccel(gtk_app, "win.focus-2", "<Alt>2");
    setAccel(gtk_app, "win.focus-3", "<Alt>3");
    setAccel(gtk_app, "win.focus-4", "<Alt>4");
    setAccel(gtk_app, "win.focus-5", "<Alt>5");
    setAccel(gtk_app, "win.focus-6", "<Alt>6");
    setAccel(gtk_app, "win.focus-7", "<Alt>7");
    setAccel(gtk_app, "win.focus-8", "<Alt>8");
    setAccel(gtk_app, "win.focus-9", "<Alt>9");
    // Directional ops each get an arrow + its vim hjkl alias (h=left, j=down,
    // k=up, l=right). No-shift combos use lowercase letters; shift combos use
    // uppercase (matching the keyval that arrives when Shift is held).
    setAccel2(gtk_app, "win.focus-left", "<Ctrl><Alt>Left", "<Ctrl><Alt>h");
    setAccel2(gtk_app, "win.focus-right", "<Ctrl><Alt>Right", "<Ctrl><Alt>l");
    setAccel2(gtk_app, "win.focus-up", "<Ctrl><Alt>Up", "<Ctrl><Alt>k");
    setAccel2(gtk_app, "win.focus-down", "<Ctrl><Alt>Down", "<Ctrl><Alt>j");
    setAccel2(gtk_app, "win.swap-left", "<Ctrl><Shift><Alt>Left", "<Ctrl><Shift><Alt>H");
    setAccel2(gtk_app, "win.swap-right", "<Ctrl><Shift><Alt>Right", "<Ctrl><Shift><Alt>L");
    setAccel2(gtk_app, "win.swap-up", "<Ctrl><Shift><Alt>Up", "<Ctrl><Shift><Alt>K");
    setAccel2(gtk_app, "win.swap-down", "<Ctrl><Shift><Alt>Down", "<Ctrl><Shift><Alt>J");
    setAccel2(gtk_app, "win.resize-left", "<Ctrl><Shift>Left", "<Ctrl><Shift>H");
    setAccel2(gtk_app, "win.resize-right", "<Ctrl><Shift>Right", "<Ctrl><Shift>L");
    setAccel2(gtk_app, "win.resize-up", "<Ctrl><Shift>Up", "<Ctrl><Shift>K");
    setAccel2(gtk_app, "win.resize-down", "<Ctrl><Shift>Down", "<Ctrl><Shift>J");
    setAccel(gtk_app, "win.split-h", "<Ctrl><Shift>R");
    setAccel(gtk_app, "win.split-v", "<Ctrl><Shift>D");
    setAccel(gtk_app, "win.split-group-h", "<Ctrl><Shift><Alt>R");
    setAccel(gtk_app, "win.split-group-v", "<Ctrl><Shift><Alt>D");
    setAccel(gtk_app, "win.close-pane", "<Ctrl>w");
    setAccel(gtk_app, "win.add-agent", "<Ctrl><Shift>A");
    setAccel(gtk_app, "win.add-shell", "<Ctrl><Shift>S");
    setAccel(gtk_app, "win.add-git", "<Ctrl><Shift>G");
    setAccel(gtk_app, "win.add-editor", "<Ctrl><Shift>E");
    setAccel(gtk_app, "win.add-scratchpad", "<Ctrl><Shift>N");
    setAccel(gtk_app, "win.reset-layout", "<Ctrl><Alt>r");
    setAccel(gtk_app, "app.present-chooser", "<Ctrl>o");
    setAccel(gtk_app, "win.create-worktree", "<Ctrl><Shift>b");
    setAccel(gtk_app, "win.send-to-agent", "<Ctrl>Return");
    setAccel(gtk_app, "win.show-help", "<Ctrl>question");
    setAccel(gtk_app, "win.show-settings", "<Ctrl>comma");
    setAccel(gtk_app, "win.toggle-follow-mouse", "<Ctrl><Shift>M");

    // Reload: Ctrl+Shift+Q. UPPERCASE Q — GTK delivers the uppercase keyval when
    // Shift is held, so lowercase `q` here would silently never match (see the
    // shift-combo convention above). Ghostty also binds ctrl+shift+q to `quit`,
    // but our window accelerator wins over the terminal surface (same as the
    // add-pane chords). Run ./build.sh first; reload only swaps the process.
    setAccel(gtk_app, "win.reload", "<Ctrl><Shift>Q");

    // Quit: Ctrl+Q reuses the existing `win.close` action (clean shutdown +
    // layout save, both via onWindowCloseRequest).
    setAccel(gtk_app, "win.close", "<Ctrl>q");
}

/// Create a `gio.SimpleAction` named `name`, connect `cb` (passed the shared
/// AppContext), and add it to the window's action map.
fn addAction(
    map: *gio.ActionMap,
    name: [:0]const u8,
    cb: *const fn (*gio.SimpleAction, ?*glib.Variant, *AppContext) callconv(.c) void,
    app_ctx: *AppContext,
) void {
    const action = gio.SimpleAction.new(name, null);
    defer action.unref();
    _ = gio.SimpleAction.signals.activate.connect(action, *AppContext, cb, app_ctx, .{});
    map.addAction(action.as(gio.Action));
}

/// Bind a single accelerator string to a detailed action name.
fn setAccel(gtk_app: *gtk.Application, action: [:0]const u8, accel: [*:0]const u8) void {
    const accels = [_:null]?[*:0]const u8{accel};
    gtk_app.setAccelsForAction(action, &accels);
}

/// Bind two accelerators to one action (an arrow key + its vim hjkl alias). GTK
/// matches either. Shift-bearing combos use the uppercase letter (e.g. `<Shift>H`),
/// no-shift combos use lowercase (`h`), mirroring how the keyval arrives.
fn setAccel2(gtk_app: *gtk.Application, action: [:0]const u8, a1: [*:0]const u8, a2: [*:0]const u8) void {
    const accels = [_:null]?[*:0]const u8{ a1, a2 };
    gtk_app.setAccelsForAction(action, &accels);
}

// --- Focus handlers --------------------------------------------------------

fn focusN(app_ctx: *AppContext, idx: usize) void {
    app_ctx.workspace.focusIndex(idx);
}
fn onFocus1(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    focusN(a, 0);
}
fn onFocus2(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    focusN(a, 1);
}
fn onFocus3(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    focusN(a, 2);
}
fn onFocus4(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    focusN(a, 3);
}
fn onFocus5(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    focusN(a, 4);
}
fn onFocus6(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    focusN(a, 5);
}
fn onFocus7(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    focusN(a, 6);
}
fn onFocus8(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    focusN(a, 7);
}
fn onFocus9(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    focusN(a, 8);
}
fn onFocusLeft(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.moveFocus(.left);
}
fn onFocusRight(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.moveFocus(.right);
}
fn onFocusUp(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.moveFocus(.up);
}
fn onFocusDown(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.moveFocus(.down);
}

// Swap the focused pane with its neighbor in a direction (Ctrl+Shift+Alt+Arrow).
// Persist the new arrangement so it survives a reopen.
fn onSwapLeft(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.swapPane(.left);
    saveLayout(a);
}
fn onSwapRight(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.swapPane(.right);
    saveLayout(a);
}
fn onSwapUp(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.swapPane(.up);
    saveLayout(a);
}
fn onSwapDown(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.swapPane(.down);
    saveLayout(a);
}

// Resize the focused pane (Ctrl+Shift+Arrow). Like a manual divider drag, we do
// NOT persist per-keystroke (it would write the layout file on every key-repeat
// tick); the live position is captured on the next save / clean window close.
fn onResizeLeft(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.resizePane(.left);
}
fn onResizeRight(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.resizePane(.right);
}
fn onResizeUp(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.resizePane(.up);
}
fn onResizeDown(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.resizePane(.down);
}

// --- Structural handlers ---------------------------------------------------

fn onSplitH(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.split(.horizontal);
    saveLayout(a);
}
fn onSplitV(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.split(.vertical);
    saveLayout(a);
}
fn onSplitGroupH(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.splitGroup(.horizontal);
    saveLayout(a);
}
fn onSplitGroupV(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.splitGroup(.vertical);
    saveLayout(a);
}
fn onClosePane(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    // Don't silently end a running agent: confirm first, then close. The
    // focused pane is captured by `Tree.focused` (synced inside the check), and
    // closing later acts on that same pane, so the dialog stealing focus is fine.
    if (a.workspace.focusedIsLiveAgent()) {
        confirmDestructive(
            a,
            "Close this agent pane?",
            "An agent is still running here. Closing the pane ends it.",
            "Close pane",
            doClosePane,
            false,
        );
        return;
    }
    doClosePane(a);
}

/// Actually close the focused pane. Closing the last pane quits the app via the
/// clean window-close path (which also saves the layout); otherwise save the
/// collapsed layout.
fn doClosePane(a: *AppContext) void {
    if (a.workspace.closeFocused()) {
        // The user explicitly closed the last pane (and already confirmed it if
        // it was an agent), so don't make them re-answer the quit prompt.
        a.quit_confirmed = true;
        a.window.as(gtk.Window).close();
    } else {
        saveLayout(a);
    }
}

/// `win.reset-layout` (Ctrl+Shift+0): discard the current arrangement and
/// rebuild the DEFAULT 2x2 in the current project dir. Useful after closing
/// panes down to one (or otherwise wanting a clean slate). Mirrors the
/// rebuildWorkspace swap, but with `saved=null` (-> default) and same project.
fn onResetLayout(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    // Reset tears down EVERY pane, so confirm if any of them is a live agent.
    if (a.workspace.hasLiveAgent()) {
        confirmDestructive(
            a,
            "Reset the layout?",
            "An agent is still running. Resetting to the default 2×2 ends every pane, including the agent.",
            "Reset layout",
            doResetLayout,
            false,
        );
        return;
    }
    doResetLayout(a);
}

fn doResetLayout(a: *AppContext) void {
    log.info("reset-layout: rebuilding default 2x2", .{});
    const cwd: ?[:0]const u8 = if (a.current.path.len > 0) a.current.path else null;
    var new_ws = Workspace.init(a.alloc, a.git_cmd, a.agent_cmd, cwd, null); // null => default 2x2
    new_ws.window = a.window.as(gtk.Window);
    new_ws.connectCloseRequests(onSurfaceCloseRequest, a);
    a.window.as(gtk.Window).setChild(new_ws.root);
    a.workspace.deinit();
    a.workspace.* = new_ws;
    a.workspace.focusIndex(0);
    saveLayout(a);
}
fn onAddAgent(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.addRole(.agent);
    saveLayout(a);
}
fn onAddShell(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.addRole(.shell);
    saveLayout(a);
}
fn onAddGit(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.addRole(.git);
    saveLayout(a);
}
fn onAddEditor(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.addRole(.editor);
    saveLayout(a);
}
fn onAddScratchpad(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.addRole(.scratchpad);
    saveLayout(a);
}

/// `win.send-to-agent` (Ctrl+Return): send the focused scratchpad's selection
/// (or current line) into the agent terminal. Pure cross-pane data flow — no
/// structural change, so no layout save.
fn onSendToAgent(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    a.workspace.sendToAgent();
}

// --- Project directory + picker -------------------------------------------

/// Set the window title to `Roost — <project name>` (basename, falling back to
/// the full path), or plain `roost` if there is no project. `p` is borrowed.
fn setWindowTitle(alloc: std.mem.Allocator, window: *gtk.ApplicationWindow, p: ?Project) void {
    const win = window.as(gtk.Window);
    const proj = p orelse {
        win.setTitle("Roost");
        return;
    };
    const name = proj.displayName();

    // Append the checked-out git branch when the project is a repo, e.g.
    // "Roost — roost · main". Resolved statically here (at open/switch); the
    // branch slice is owned by `alloc` and freed once setTitle has copied.
    const branch: ?[]u8 = git.currentBranch(alloc, proj.path);
    defer if (branch) |b| alloc.free(b);

    // Build a NUL-terminated title on the stack. setTitle copies.
    var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const title = if (branch) |b|
        std.fmt.bufPrintZ(&buf, "Roost — {s} · {s}", .{ name, b }) catch null
    else
        std.fmt.bufPrintZ(&buf, "Roost — {s}", .{name}) catch null;
    win.setTitle(title orelse "Roost");
}

/// Open a GTK directory chooser (the chooser's "Open Folder…" action). When the
/// user picks a folder, `onFolderChosen` rebuilds the workspace there.
fn presentFolderPicker(app_ctx: *AppContext) void {
    const dialog = gtk.FileDialog.new();
    // The dialog holds its own ref during the async op; we drop ours here.
    defer dialog.unref();
    dialog.setTitle("Open Project");
    dialog.setModal(1);

    // Pre-seed at the current project dir if we have one.
    if (app_ctx.current.path.len > 0) {
        const file = gio.File.newForPath(app_ctx.current.path);
        defer file.unref();
        dialog.setInitialFolder(file);
    }

    dialog.selectFolder(
        app_ctx.window.as(gtk.Window),
        null, // no cancellable
        onFolderChosen,
        app_ctx,
    );
}

/// `gio.AsyncReadyCallback` for `FileDialog.selectFolder`. Switches THIS window to
/// the chosen folder (matching the chooser default). Cancel / error => no-op.
fn onFolderChosen(
    source: ?*gobject.Object,
    res: *gio.AsyncResult,
    data: ?*anyopaque,
) callconv(.c) void {
    const app_ctx: *AppContext = @ptrCast(@alignCast(data orelse return));
    const dialog = gobject.ext.cast(gtk.FileDialog, source orelse return) orelse return;

    var err: ?*glib.Error = null;
    defer if (err) |e| e.free();

    const file = dialog.selectFolderFinish(res, &err) orelse {
        // Most commonly this is the user dismissing the dialog (cancel).
        if (err) |e| log.debug("folder selection cancelled/failed: {s}", .{e.f_message orelse "(unknown)"});
        return;
    };
    defer file.unref();

    const path = file.getPath() orelse {
        log.warn("chosen folder has no local path", .{});
        return;
    };
    defer glib.free(path);

    confirmSwitch(app_ctx, std.mem.span(path));
}

/// Tear down the live workspace and build a fresh one rooted at `new_path`.
///
/// Mechanism: build a new `Workspace`, swap it in as the window's child (which
/// unparents + finalizes the old surface widgets, so Ghostty tears down their
/// CoreSurfaces cleanly), then mutate `app_ctx.workspace.*` in place so the
/// focus shortcuts that captured that pointer keep working. We rewire the
/// per-surface close-request no-op handler on the new panes.
fn rebuildWorkspace(app_ctx: *AppContext, new_path: []const u8) void {
    const alloc = app_ctx.alloc;

    // Validate + canonicalize the chosen directory.
    const new_project = Project.fromPath(alloc, new_path) catch |err| {
        log.warn("cannot open project '{s}' err={}", .{ new_path, err });
        return;
    };

    log.info("opening project: {s}", .{new_project.path});

    // Per-worktree layout: first persist the OUTGOING workspace under the
    // current project's key (so returning here later restores this exact
    // arrangement), then build the replacement from the TARGET project's own
    // saved layout — falling back to the default 2x2 if it has none/invalid.
    // (app_ctx.workspace + app_ctx.current are still the OLD values here, which
    // is exactly what saveLayout keys on.)
    saveLayout(app_ctx);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const saved: ?*const tree.SerNode = blk: {
        const bytes = project.readLayout(alloc, new_project.path) orelse break :blk null;
        defer alloc.free(bytes);
        break :blk tree.parseSer(arena.allocator(), bytes);
    };

    var new_ws = Workspace.init(alloc, app_ctx.git_cmd, app_ctx.agent_cmd, new_project.path, saved);
    new_ws.window = app_ctx.window.as(gtk.Window); // for live-focus sync on ops
    new_ws.connectCloseRequests(onSurfaceCloseRequest, app_ctx);

    // Swap the window child to the new workspace container. This unparents the
    // old workspace's widget tree (finalized once we drop its refs below).
    app_ctx.window.as(gtk.Window).setChild(new_ws.root);

    // Tear down the OLD tree: closes old surfaces (clean Ghostty teardown) and
    // frees the old node allocations. Must come after the setChild above.
    app_ctx.workspace.deinit();

    // Replace the live workspace storage in place. Shortcut actions hold a
    // pointer to `*Workspace`, which is unchanged; only its contents move.
    app_ctx.workspace.* = new_ws;

    // Swap the owned project (free the previous one) and record the recent.
    if (app_ctx.current.path.len > 0) app_ctx.current.deinit();
    app_ctx.current = new_project;
    project.recordRecent(alloc, new_project.path);

    setWindowTitle(alloc, app_ctx.window, new_project);
    app_ctx.workspace.focusIndex(0);
    app_ctx.workspace.updateHighlight();
}

/// Heap state for the async switch confirmation. `path` is an owned copy: the
/// caller's path (a chooser row, a freed dialog buffer) won't outlive the async
/// dialog, so we dup it and free it in the response callback.
const SwitchReq = struct {
    a: *AppContext,
    path: [:0]u8,
};

/// Confirm before switching THIS window to `new_path` (which tears down the
/// current workspace and anything running in it), then `rebuildWorkspace`. Used
/// by the pure-switch entry points (chooser row, Open Folder…). The worktree
/// CREATE flow keeps its own "Create" dialog as the gate and switches directly.
fn confirmSwitch(a: *AppContext, new_path: []const u8) void {
    // Fresh window with no project yet (e.g. the startup relaunch chooser):
    // nothing to lose, so open the picked project directly — no confirm prompt.
    if (a.current.path.len == 0) {
        rebuildWorkspace(a, new_path);
        return;
    }
    const path = a.alloc.dupeZ(u8, new_path) catch return;
    const req = a.alloc.create(SwitchReq) catch {
        a.alloc.free(path);
        return;
    };
    req.* = .{ .a = a, .path = path };

    const dialog = adw.AlertDialog.new("Switch project?", "Replace this window with the project, or open it in a new window.");
    // Order shown: Switch, Open in New Window, Cancel. Only "switch" is
    // destructive (it tears down this workspace); "newwin" leaves it untouched.
    dialog.addResponse("switch", "Switch");
    dialog.addResponse("newwin", "Open in New Window");
    dialog.addResponse("cancel", "Cancel");
    dialog.setResponseAppearance("switch", .destructive);
    dialog.setDefaultResponse("cancel");
    dialog.setCloseResponse("cancel");
    dialog.choose(a.window.as(gtk.Widget), null, onSwitchResponse, req);
}

/// `gio.AsyncReadyCallback` for `confirmSwitch`. "switch" replaces this window;
/// "newwin" opens the target in a detached window (this one untouched); "cancel"
/// or dismiss does nothing. Frees the request in every path.
fn onSwitchResponse(
    source: ?*gobject.Object,
    res: *gio.AsyncResult,
    data: ?*anyopaque,
) callconv(.c) void {
    const req: *SwitchReq = @ptrCast(@alignCast(data orelse return));
    const a = req.a;
    defer {
        a.alloc.free(req.path);
        a.alloc.destroy(req);
    }

    const dialog = gobject.ext.cast(adw.AlertDialog, source orelse return) orelse return;
    const response = dialog.chooseFinish(res);
    if (std.mem.orderZ(u8, "switch", response) == .eq) {
        rebuildWorkspace(a, req.path);
    } else if (std.mem.orderZ(u8, "newwin", response) == .eq) {
        openProjectNewWindow(a, req.path);
    }
}

// --- Git worktree command center (Phase 3c) -------------------------------

/// Heap-allocated state threaded through the async branch-name dialog. The
/// `entry` is owned by the dialog (still alive when `onWorktreeResponse` reads
/// it); `repo_root` and this struct itself are freed in the response callback.
const WorktreeReq = struct {
    app_ctx: *AppContext,
    entry: *gtk.Entry,
    repo_root: []u8,
};

/// `win.create-worktree` (Ctrl+Shift+B): prompt for a branch name, then create
/// `<repo>/../<repo-name>.worktrees/<branch>` as a new worktree+branch and
/// switch the whole workspace into it (reusing `rebuildWorkspace`).
fn onCreateWorktree(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    beginCreateWorktree(a);
}

/// Prompt for a branch name, then create `<repo>.worktrees/<branch>` and switch
/// into it. Shared by the Ctrl+Shift+B action and the chooser's "New…" action.
fn beginCreateWorktree(a: *AppContext) void {
    if (!commandOnPath("git")) {
        errorAlert(a.window, "Git not found", "`git` is not on your PATH.");
        return;
    }
    if (a.current.path.len == 0) {
        errorAlert(a.window, "No project", "Open a project directory first (Ctrl+O).");
        return;
    }
    // repo_root is owned; it transfers into the heap req (freed in the callback).
    const repo_root = git.repoRoot(a.alloc, a.current.path) orelse {
        errorAlert(a.window, "Not a git repository", "The current project is not inside a git repository.");
        return;
    };
    const req = a.alloc.create(WorktreeReq) catch {
        a.alloc.free(repo_root);
        return;
    };

    const entry = gobject.ext.newInstance(gtk.Entry, .{});
    entry.setPlaceholderText("branch-name");
    entry.setActivatesDefault(1); // Enter in the entry triggers the default response

    req.* = .{ .app_ctx = a, .entry = entry, .repo_root = repo_root };

    const dialog = adw.AlertDialog.new("New worktree", "Create a new branch + worktree and switch to it.");
    dialog.setExtraChild(entry.as(gtk.Widget));
    dialog.addResponse("cancel", "Cancel");
    dialog.addResponse("create", "Create");
    dialog.setResponseAppearance("create", .suggested);
    dialog.setDefaultResponse("create");
    dialog.setCloseResponse("cancel");
    dialog.choose(a.window.as(gtk.Widget), null, onWorktreeResponse, req);
}

/// `gio.AsyncReadyCallback` for the branch-name dialog. On "create": compute the
/// sibling worktree path, create the worktree, and switch into it. Frees the
/// request in every path.
fn onWorktreeResponse(
    source: ?*gobject.Object,
    res: *gio.AsyncResult,
    data: ?*anyopaque,
) callconv(.c) void {
    const req: *WorktreeReq = @ptrCast(@alignCast(data orelse return));
    const a = req.app_ctx;
    defer {
        a.alloc.free(req.repo_root);
        a.alloc.destroy(req);
    }

    const dialog = gobject.ext.cast(adw.AlertDialog, source orelse return) orelse return;
    const response = dialog.chooseFinish(res);
    if (std.mem.orderZ(u8, "create", response) != .eq) return;

    const raw = std.mem.span(req.entry.getBuffer().getText());
    const branch = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (branch.len == 0) return;

    // dest = <dirname(repo_root)>/<basename(repo_root)>.worktrees/<branch>
    const parent = std.fs.path.dirname(req.repo_root) orelse "/";
    const name = std.fs.path.basename(req.repo_root);
    const wt_dir = std.fmt.allocPrint(a.alloc, "{s}/{s}.worktrees", .{ parent, name }) catch return;
    defer a.alloc.free(wt_dir);
    const dest = std.fs.path.join(a.alloc, &.{ wt_dir, branch }) catch return;
    defer a.alloc.free(dest);

    // Ensure the parent of `dest` exists; git creates the leaf worktree dir.
    if (std.fs.path.dirname(dest)) |d| {
        std.fs.cwd().makePath(d) catch |err| {
            log.warn("could not create worktrees dir '{s}' err={}", .{ d, err });
        };
    }

    if (git.addWorktree(a.alloc, req.repo_root, dest, branch)) |err_msg| {
        defer a.alloc.free(err_msg);
        // Friendlier wording for the common case; fall back to git's stderr.
        if (std.mem.indexOf(u8, err_msg, "already exists") != null) {
            var buf: [512]u8 = undefined;
            const friendly: []const u8 = std.fmt.bufPrint(
                &buf,
                "A branch or worktree named '{s}' already exists. Choose a different name.",
                .{branch},
            ) catch "That branch or worktree already exists. Choose a different name.";
            errorAlert(a.window, "Name already in use", friendly);
        } else {
            errorAlert(a.window, "Could not create worktree", err_msg);
        }
        return;
    }

    rebuildWorkspace(a, dest);
}

// --- Destructive-action confirmation --------------------------------------
// Guard close/reset so they never silently kill a running agent mid-task.

/// Heap state threaded through the async confirm dialog. `on_confirm` runs only
/// if the user accepts; the struct is freed in the response callback either way.
const ConfirmReq = struct {
    a: *AppContext,
    on_confirm: *const fn (*AppContext) void,
};

/// Present a modal "are you sure?" with a destructive accept button. On accept,
/// `on_confirm(a)` runs. `default_accept` controls which response Enter triggers:
/// false (close/reset) makes Cancel the default so a reflexive Enter is safe;
/// true (quit) makes the accept the default so Ctrl+Q → Enter quits. Esc always
/// cancels. If we can't even allocate the request we fail safe by doing nothing.
fn confirmDestructive(
    a: *AppContext,
    heading: [*:0]const u8,
    body: [*:0]const u8,
    accept_label: [*:0]const u8,
    on_confirm: *const fn (*AppContext) void,
    default_accept: bool,
) void {
    const req = a.alloc.create(ConfirmReq) catch return;
    req.* = .{ .a = a, .on_confirm = on_confirm };

    const dialog = adw.AlertDialog.new(heading, body);
    dialog.addResponse("cancel", "Cancel");
    dialog.addResponse("accept", accept_label);
    dialog.setResponseAppearance("accept", .destructive);
    dialog.setDefaultResponse(if (default_accept) "accept" else "cancel");
    dialog.setCloseResponse("cancel"); // Esc always cancels.
    dialog.choose(a.window.as(gtk.Widget), null, onConfirmResponse, req);
}

/// `gio.AsyncReadyCallback` for `confirmDestructive`. Runs `on_confirm` only on
/// the "accept" response; frees the request in every path.
fn onConfirmResponse(
    source: ?*gobject.Object,
    res: *gio.AsyncResult,
    data: ?*anyopaque,
) callconv(.c) void {
    const req: *ConfirmReq = @ptrCast(@alignCast(data orelse return));
    const a = req.a;
    const on_confirm = req.on_confirm;
    a.alloc.destroy(req);

    const dialog = gobject.ext.cast(adw.AlertDialog, source orelse return) orelse return;
    const response = dialog.chooseFinish(res);
    if (std.mem.orderZ(u8, "accept", response) != .eq) return;
    on_confirm(a);
}

// --- Keyboard cheat-sheet --------------------------------------------------

/// One line of the cheat-sheet. A null `keys` marks a section header (its
/// `text` is the heading); otherwise it's a `keys` → `text` shortcut row.
const HelpRow = struct {
    keys: ?[:0]const u8 = null,
    text: [:0]const u8,
};

const help_rows = [_]HelpRow{
    .{ .text = "Focus" },
    .{ .keys = "Alt+1 … Alt+9", .text = "Focus pane N by position" },
    .{ .keys = "Ctrl+Alt+←↓↑→  ·  hjkl", .text = "Focus pane in a direction" },
    .{ .text = "Move & resize" },
    .{ .keys = "Ctrl+Shift+Alt+←↓↑→  ·  HJKL", .text = "Swap pane with that neighbor" },
    .{ .keys = "Ctrl+Shift+←↓↑→  ·  HJKL", .text = "Resize focused pane (push divider)" },
    .{ .text = "Split & arrange" },
    .{ .keys = "Ctrl+Shift+R  /  D", .text = "Split pane → right / down" },
    .{ .keys = "Ctrl+Shift+Alt+R  /  D", .text = "Split whole column / row as a unit" },
    .{ .keys = "Ctrl+Shift+A S G E N", .text = "Add Agent / Shell / Git / Editor / Notes" },
    .{ .keys = "Ctrl+W", .text = "Close focused pane" },
    .{ .keys = "Ctrl+Alt+R", .text = "Reset layout to default 2×2" },
    .{ .text = "Project & worktree" },
    .{ .keys = "Ctrl+O", .text = "Open project / worktree chooser" },
    .{ .keys = "Ctrl+Shift+B", .text = "New branch + worktree" },
    .{ .text = "Other" },
    .{ .keys = "Ctrl+Enter", .text = "Send scratchpad selection → agent" },
    .{ .keys = "Ctrl+Shift+M", .text = "Toggle focus-follows-mouse (on by default)" },
    .{ .keys = "Ctrl+Shift+/", .text = "Show this cheat-sheet" },
    .{ .keys = "Ctrl+Shift+Q", .text = "Reload — restart into the latest build" },
    .{ .keys = "Ctrl+Q", .text = "Quit Roost" },
};

/// `win.show-help` (Ctrl+Shift+/): a modal cheat-sheet of every keybinding,
/// grouped by section. Built fresh each time; closes on Esc or the Close button.
fn presentShortcuts(a: *AppContext) void {
    const grid = gtk.Grid.new();
    grid.setRowSpacing(6);
    grid.setColumnSpacing(28);
    const gw = grid.as(gtk.Widget);
    gw.setMarginTop(4);
    gw.setMarginBottom(4);
    gw.setMarginStart(4);
    gw.setMarginEnd(4);

    var r: c_int = 0;
    for (help_rows) |row| {
        if (row.keys) |keys| {
            var buf: [256]u8 = undefined;
            const markup = std.fmt.bufPrintZ(&buf, "<tt>{s}</tt>", .{keys}) catch keys;
            const kl = gtk.Label.new(null);
            kl.setMarkup(markup);
            kl.setXalign(0.0);
            kl.as(gtk.Widget).setHalign(.start);
            grid.attach(kl.as(gtk.Widget), 0, r, 1, 1);

            const dl = gtk.Label.new(row.text);
            dl.setXalign(0.0);
            dl.as(gtk.Widget).setHalign(.start);
            grid.attach(dl.as(gtk.Widget), 1, r, 1, 1);
        } else {
            var buf: [128]u8 = undefined;
            const markup = std.fmt.bufPrintZ(&buf, "<b>{s}</b>", .{row.text}) catch row.text;
            const hl = gtk.Label.new(null);
            hl.setMarkup(markup);
            hl.setXalign(0.0);
            hl.as(gtk.Widget).setHalign(.start);
            if (r != 0) hl.as(gtk.Widget).setMarginTop(10);
            grid.attach(hl.as(gtk.Widget), 0, r, 2, 1);
        }
        r += 1;
    }

    const scroller = gtk.ScrolledWindow.new();
    scroller.setPolicy(.never, .automatic);
    scroller.setMaxContentHeight(560);
    scroller.setPropagateNaturalHeight(1);
    scroller.setPropagateNaturalWidth(1);
    scroller.setChild(grid.as(gtk.Widget));

    const dialog = adw.AlertDialog.new("Keyboard Shortcuts", null);
    dialog.setExtraChild(scroller.as(gtk.Widget));
    dialog.addResponse("close", "Close");
    dialog.setDefaultResponse("close");
    dialog.setCloseResponse("close");
    dialog.choose(a.window.as(gtk.Widget), null, null, null);
}

fn onShowHelp(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    presentShortcuts(a);
}

/// Present the Settings dialog (Ctrl+, / gear button): an `adw.PreferencesDialog`
/// with instant-apply rows for the Roost-level settings. Each row writes its
/// value back into `app_ctx.config` and persists via `Config.save` the moment it
/// changes — no Save/Cancel button (the libadwaita convention). Initial values
/// are set BEFORE connecting the change signals so seeding the rows doesn't
/// trigger a spurious save.
fn presentSettings(a: *AppContext) void {
    const dialog = adw.PreferencesDialog.new();
    const page = adw.PreferencesPage.new();

    // Panes group.
    const panes_group = adw.PreferencesGroup.new();
    panes_group.setTitle("Panes");

    // Focus-follows-mouse. Shares state with Ctrl+Shift+M and the header-bar
    // toggle button (via the `win.toggle-follow-mouse` stateful action).
    const ffm = adw.SwitchRow.new();
    ffm.as(adw.PreferencesRow).setTitle("Focus follows mouse");
    ffm.as(adw.ActionRow).setSubtitle("Focus a pane when the pointer enters it");
    ffm.setActive(@intFromBool(tree.followMouseEnabled()));
    _ = gobject.Object.signals.notify.connect(ffm, *AppContext, onFfmToggled, a, .{ .detail = "active" });
    panes_group.add(ffm.as(gtk.Widget));

    const group = adw.PreferencesGroup.new();
    group.setTitle("Agent");

    // Agent command. EntryRow emits `apply` on a deliberate edit (Enter / apply
    // button). Takes effect for panes spawned afterward (reopen / new window /
    // reload); $ROOST_AGENT still overrides it at launch.
    const agent_row = adw.EntryRow.new();
    agent_row.as(adw.PreferencesRow).setTitle("Command");
    // Show the apply (✓) affordance so Enter / the button emits `apply` (without
    // this, Enter emits `entry-activated` instead and the value never saves).
    agent_row.setShowApplyButton(1);
    var abuf: [256]u8 = undefined;
    const agent_z = std.fmt.bufPrintZ(&abuf, "{s}", .{a.config.agent}) catch "claude";
    agent_row.as(gtk.Editable).setText(agent_z);
    _ = adw.EntryRow.signals.apply.connect(agent_row, *AppContext, onAgentApplied, a, .{});
    group.add(agent_row.as(gtk.Widget));

    // Audio notifications toggle.
    const audio = adw.SwitchRow.new();
    audio.as(adw.PreferencesRow).setTitle("Audio notifications");
    audio.as(adw.ActionRow).setSubtitle("Play a sound on agent events");
    audio.setActive(@intFromBool(a.config.audio_notifications));
    _ = gobject.Object.signals.notify.connect(audio, *AppContext, onAudioToggled, a, .{ .detail = "active" });
    group.add(audio.as(gtk.Widget));

    const scratch_group = adw.PreferencesGroup.new();
    scratch_group.setTitle("Scratchpad");

    // Autosave toggle.
    const autosave = adw.SwitchRow.new();
    autosave.as(adw.PreferencesRow).setTitle("Autosave");
    autosave.as(adw.ActionRow).setSubtitle("Save the scratchpad to a file as you type");
    autosave.setActive(@intFromBool(a.config.scratchpad_autosave));
    _ = gobject.Object.signals.notify.connect(autosave, *AppContext, onAutosaveToggled, a, .{ .detail = "active" });
    scratch_group.add(autosave.as(gtk.Widget));

    // Scratchpad file path. EntryRow emits `apply` when the user confirms (Enter
    // or the apply button), so we persist only on a deliberate edit.
    const path_row = adw.EntryRow.new();
    path_row.as(adw.PreferencesRow).setTitle("File");
    path_row.setShowApplyButton(1);
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pbuf, "{s}", .{a.config.scratchpad_path}) catch "";
    path_row.as(gtk.Editable).setText(path_z);
    _ = adw.EntryRow.signals.apply.connect(path_row, *AppContext, onScratchpadPathApplied, a, .{});
    scratch_group.add(path_row.as(gtk.Widget));

    page.add(panes_group);
    page.add(group);
    page.add(scratch_group);
    dialog.add(page);
    dialog.as(adw.Dialog).present(a.window.as(gtk.Widget));
}

fn onShowSettings(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    presentSettings(a);
}

fn onAudioToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, a: *AppContext) callconv(.c) void {
    a.config.audio_notifications = row.getActive() != 0;
    a.config.save();
}

fn onAutosaveToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, a: *AppContext) callconv(.c) void {
    a.config.scratchpad_autosave = row.getActive() != 0;
    a.config.save();
}

fn onScratchpadPathApplied(row: *adw.EntryRow, a: *AppContext) callconv(.c) void {
    const text = row.as(gtk.Editable).getText();
    a.config.setScratchpadPath(std.mem.span(text));
    a.config.save();
}

fn onAgentApplied(row: *adw.EntryRow, a: *AppContext) callconv(.c) void {
    const text = row.as(gtk.Editable).getText();
    a.config.setAgent(std.mem.span(text));
    a.config.save();
}

fn onFfmToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, a: *AppContext) callconv(.c) void {
    const on = row.getActive() != 0;
    tree.setFollowMouse(on);
    a.config.focus_follows_mouse = on;
    a.config.save();
    // Keep the Ctrl+Shift+M accelerator + header-bar toggle button in sync by
    // updating the shared stateful action's state (does not re-fire its handler).
    if (a.window.as(gio.ActionMap).lookupAction("toggle-follow-mouse")) |act| {
        if (gobject.ext.cast(gio.SimpleAction, act)) |sa| {
            sa.setState(glib.Variant.newBoolean(@intFromBool(on)));
        }
    }
}

fn onToggleFollowMouse(action: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    const on = tree.toggleFollowMouse();
    // Reflect the new state so the header-bar toggle button updates with us.
    action.setState(glib.Variant.newBoolean(@intFromBool(on)));
    // Persist so the preference sticks across launches (it now lives in config).
    a.config.focus_follows_mouse = on;
    a.config.save();
    log.info("focus-follows-mouse {s}", .{if (on) "on" else "off"});
}

/// Show a simple modal error alert with a single OK button. Best-effort: a
/// non-NUL-terminated `body` (e.g. trimmed git stderr) is copied to a stack
/// buffer; overlong messages fall back to a short notice.
fn errorAlert(window: *gtk.ApplicationWindow, heading: [*:0]const u8, body: []const u8) void {
    var buf: [1024]u8 = undefined;
    const body_z: [:0]const u8 = std.fmt.bufPrintZ(&buf, "{s}", .{body}) catch "(error message too long)";
    const dialog = adw.AlertDialog.new(heading, body_z);
    dialog.addResponse("ok", "OK");
    dialog.setDefaultResponse("ok");
    dialog.setCloseResponse("ok");
    dialog.choose(window.as(gtk.Widget), null, null, null);
}

// --- Project / worktree chooser (Phase 3d) --------------------------------

/// `app.present-chooser` (Ctrl+O, and the action a remote desktop launch
/// forwards): open the chooser over the current window.
fn onPresentChooser(_: *gio.SimpleAction, _: ?*glib.Variant, a: *AppContext) callconv(.c) void {
    presentChooser(a);
}

/// State threaded through the chooser dialog. `paths` (each sentinel-terminated)
/// and this struct are freed when the dialog closes (in `onChooserResponse`).
const ChooserState = struct {
    app_ctx: *AppContext,
    paths: [][:0]u8,
    dialog: *adw.AlertDialog,
    /// The row list, so the "Switch This Window" response can read the selection.
    list_box: *gtk.ListBox,
    /// Wall-clock ms when the dialog was presented; used to ignore the phantom
    /// row activation that fires as the dialog opens under the pointer.
    shown_ms: i64 = 0,
};

/// Open `path` in a brand-new, independent roost window: spawn a DETACHED child
/// process (its own session via `setsid`, stdio to /dev/null, and
/// `--gtk-single-instance=false` so it gets its own window instead of forwarding
/// to us). No controlling terminal is attached, so nothing is left "stray".
/// `ROOST_PROJECT` carries the target dir; the desktop-launch marker is dropped
/// so the child resolves the project from that env, not recents.
fn openProjectNewWindow(a: *AppContext, path: []const u8) void {
    const alloc = a.alloc;
    const exe = std.fs.selfExePathAlloc(alloc) catch |err| {
        log.warn("cannot resolve own exe path err={}", .{err});
        return;
    };
    defer alloc.free(exe);

    var env = std.process.getEnvMap(alloc) catch return;
    defer env.deinit();
    env.put("ROOST_PROJECT", path) catch return;
    env.remove("GIO_LAUNCHED_DESKTOP_FILE_PID");

    // sh backgrounds a setsid'd child and exits immediately, so the new window
    // reparents to init (fully detached) and we never block or leave a zombie.
    var child = std.process.Child.init(&.{
        "/bin/sh", "-c",
        "setsid \"$1\" --gtk-single-instance=false </dev/null >/dev/null 2>&1 &",
        "sh",      exe,
    }, alloc);
    child.env_map = &env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch |err| {
        log.warn("could not spawn new roost window err={}", .{err});
        return;
    };
    log.info("opened new window for {s}", .{path});
}

/// Build + present the project/worktree chooser: a scrollable list of recent
/// projects + the current repo's worktrees (activate a row to switch the current
/// window into it), plus "Open Folder…" and "New Branch + Worktree…" actions.
/// Doubles as the launcher "already-running" prompt and the in-window switcher.
fn presentChooser(a: *AppContext) void {
    const alloc = a.alloc;
    const cur = a.current.path; // "" when no project is open

    // Gather candidate paths (recents first, then this repo's worktrees),
    // skipping the current project and de-duping. Owned, sentinel-terminated.
    var paths: std.ArrayListUnmanaged([:0]u8) = .empty;
    var moved = false;
    defer if (!moved) {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    };

    if (project.readRecents(alloc)) |recents| {
        defer {
            for (recents) |r| alloc.free(r);
            alloc.free(recents);
        }
        for (recents) |r| {
            if (cur.len > 0 and std.mem.eql(u8, r, cur)) continue;
            if (pathListContains(paths.items, r)) continue;
            const dup = alloc.dupeZ(u8, r) catch return;
            paths.append(alloc, dup) catch {
                alloc.free(dup);
                return;
            };
        }
    } else |_| {}

    if (cur.len > 0 and commandOnPath("git")) {
        if (git.repoRoot(alloc, cur)) |root| {
            defer alloc.free(root);
            if (git.worktreeList(alloc, root)) |wts| {
                defer {
                    for (wts) |w| alloc.free(w);
                    alloc.free(wts);
                }
                for (wts) |w| {
                    if (cur.len > 0 and std.mem.eql(u8, w, cur)) continue;
                    if (pathListContains(paths.items, w)) continue;
                    const dup = alloc.dupeZ(u8, w) catch return;
                    paths.append(alloc, dup) catch {
                        alloc.free(dup);
                        return;
                    };
                }
            }
        }
    }

    const cs = alloc.create(ChooserState) catch return;
    const owned = paths.toOwnedSlice(alloc) catch {
        alloc.destroy(cs);
        return;
    };
    moved = true; // `owned` now holds the paths; `paths` is empty

    // Build the UI: a scrolled ListBox of the candidate paths. AdwAlertDialog can
    // pop open under the pointer (focus-follows-mouse) and emit a phantom row
    // activation immediately; onChooserRow guards against that by time.
    const list_box = gtk.ListBox.new();
    list_box.setSelectionMode(.single);
    // Single-click SELECTS (so the "New Window" response can act on the
    // selection); double-click / Enter activates a row (-> switch THIS window).
    list_box.setActivateOnSingleClick(0);
    for (owned) |p| {
        const label = gtk.Label.new(p.ptr);
        label.setXalign(0.0);
        label.as(gtk.Widget).setMarginStart(8);
        label.as(gtk.Widget).setMarginEnd(8);
        label.as(gtk.Widget).setMarginTop(6);
        label.as(gtk.Widget).setMarginBottom(6);
        list_box.append(label.as(gtk.Widget));
    }

    const scroller = gtk.ScrolledWindow.new();
    scroller.setMinContentHeight(260);
    scroller.setPropagateNaturalHeight(1);
    scroller.setChild(list_box.as(gtk.Widget));

    const dialog = adw.AlertDialog.new(
        "Open Project",
        "Double-click or Enter opens in this window. Select a row, then New Window to open it separately.",
    );
    dialog.setExtraChild(scroller.as(gtk.Widget));
    dialog.addResponse("newwin", "New Window");
    dialog.addResponse("open", "Open Folder…");
    dialog.addResponse("new", "New Worktree…");
    dialog.addResponse("cancel", "Cancel");
    dialog.setCloseResponse("cancel");

    cs.* = .{ .app_ctx = a, .paths = owned, .dialog = dialog, .list_box = list_box, .shown_ms = std.time.milliTimestamp() };

    _ = gtk.ListBox.signals.row_activated.connect(
        list_box,
        *ChooserState,
        onChooserRow,
        cs,
        .{},
    );
    dialog.choose(a.window.as(gtk.Widget), null, onChooserResponse, cs);

    // Focus the top (most-recent) project row so Enter opens it, rather than the
    // dialog landing on Cancel. Done after `choose` presents the dialog so the
    // row widget is realized and can take focus.
    if (owned.len > 0) {
        if (list_box.getRowAtIndex(0)) |row0| {
            list_box.selectRow(row0);
            _ = row0.as(gtk.Widget).grabFocus();
        }
    }
}

/// True if `needle` already appears in `haystack`.
fn pathListContains(haystack: []const [:0]u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// A chooser row was activated (double-click / Enter): switch THIS window to that
/// project, then close the dialog (the close fires `onChooserResponse`, which
/// frees the state). Opening in a NEW window is the explicit "New Window" response.
fn onChooserRow(_: *gtk.ListBox, row: *gtk.ListBoxRow, st: *ChooserState) callconv(.c) void {
    const idx = row.getIndex();
    if (idx < 0) return;
    const i: usize = @intCast(idx);
    if (i >= st.paths.len) return;
    // Ignore the phantom activation that fires as the dialog opens under the
    // pointer; a deliberate activation always comes well after the open.
    if (std.time.milliTimestamp() - st.shown_ms < 400) {
        log.debug("ignoring early (phantom) chooser row activation idx={d}", .{i});
        return;
    }
    // Default action: replace THIS window with the picked project (after a
    // confirm). `confirmSwitch` dups the path before we free the chooser state.
    confirmSwitch(st.app_ctx, st.paths[i]);
    _ = st.dialog.as(adw.Dialog).close();
}

/// `chooseFinish` callback for the chooser. Dispatches the footer actions
/// ("newwin"/"open"/"new"); row activations close with the close-response and were
/// already handled in `onChooserRow`. Always frees the chooser state.
fn onChooserResponse(
    source: ?*gobject.Object,
    res: *gio.AsyncResult,
    data: ?*anyopaque,
) callconv(.c) void {
    const st: *ChooserState = @ptrCast(@alignCast(data orelse return));
    const a = st.app_ctx;
    defer {
        for (st.paths) |p| a.alloc.free(p);
        a.alloc.free(st.paths);
        a.alloc.destroy(st);
    }

    const dialog = gobject.ext.cast(adw.AlertDialog, source orelse return) orelse return;
    const resp = dialog.chooseFinish(res);
    if (std.mem.orderZ(u8, "newwin", resp) == .eq) {
        // Open the currently-selected row's project in a NEW window.
        if (st.list_box.getSelectedRow()) |row| {
            const idx = row.getIndex();
            if (idx >= 0 and @as(usize, @intCast(idx)) < st.paths.len) {
                openProjectNewWindow(a, st.paths[@intCast(idx)]);
            }
        }
    } else if (std.mem.orderZ(u8, "open", resp) == .eq) {
        presentFolderPicker(a);
    } else if (std.mem.orderZ(u8, "new", resp) == .eq) {
        beginCreateWorktree(a);
    }
}
