# Developing Roost

How to build, test and debug Roost. For how it's designed, see
[architecture.md](architecture.md).

## Toolchain

- **Zig 0.15.2 exactly.** Ghostty 1.3.1 needs the 0.15 line, and Arch's `zig`
  package is newer. Use the official 0.15.2 tarball.
- **Build tools:** `blueprint-compiler` and `gobject-introspection`, plus the
  GTK4 and libadwaita development files. The icon script needs `rsvg-convert`.
- **Arch linker workaround.** Arch's glibc ships an object file that Zig
  0.15.2's own linker rejects (Zig issue #31272). `scripts/patch-zig-linker.sh`
  patches your local Zig to use LLVM and LLD instead; it needs both, since LLD
  alone crashes the compiler. Re-run it after reinstalling Zig. It edits Zig,
  not Ghostty, so the gate stays clean.

## Build

```sh
./build.sh                                      # release build -> vendor/ghostty/zig-out/bin/roost
./build.sh -p /tmp/roost-test -Doptimize=Debug  # scratch debug build; leaves the main binary alone
```

`build.sh`:
1. checks the Ghostty submodule is at its pinned commit,
2. runs `scripts/check-core.sh`,
3. symlinks `src/roost/` and `src/main_roost.zig` into `vendor/ghostty/src/`,
4. resets and re-applies `patches/build.zig.patch`,
5. compiles the bundled icons into a GResource,
6. writes `src/roost/build_info.zig` with the clone's path, and
7. runs `zig build roost` with the system font and image libraries.

Edit source in the parent repo's `src/roost/`; the submodule only holds
symlinks. The submodule shows as dirty after a build, which is expected.

### Build modes

A plain `./build.sh` makes a **ReleaseSafe** build, for daily use. It's fast,
and a bug in Roost still stops with a panic and a stack trace instead of
quietly corrupting memory, which ReleaseFast would allow. It logs at info
level and above.

Pass `-Doptimize=Debug` for a **debug** build. It's noticeably slower, but it
prints `log.debug` lines to stderr, which most of the debugging below relies
on, so test instances use one. Any `-Doptimize=` you pass replaces the
default.

A window started from the desktop launcher sends its stderr to `/dev/null`,
so its logs are gone whatever the mode. Run the binary from a terminal to see
them.

### Picking up a new build

Running windows keep the code they started with. A rebuild replaces the file on
disk, and `Ctrl+Shift+Q` in a window reloads it into the new build, keeping the
layout. Claude Code picks up its conversation in each Agent pane, if Roost's
hooks are installed. Other pane processes and scrollback start fresh.

## Checks

Run these before committing:

```sh
scripts/test.sh                                  # core check + every unit test
git -C vendor/ghostty diff --name-only v1.3.1    # must print only build.zig
./build.sh -p /tmp/roost-test -Doptimize=Debug   # it still compiles
```

`scripts/test.sh` runs `check-core.sh`, then `zig test` on everything in
`src/roost/core/` and the other std-only files. A GitHub Action
(`.github/workflows/ci.yml`) runs the same script on every push, with stock
Zig 0.15.2 on Ubuntu. Stock Zig builds debug tests with its own x86_64 backend,
not LLVM; `zig test -fno-llvm -fno-lld <file>` reproduces that locally.

Only the std-only files have unit tests. Everything that touches GTK is checked
by building it and running it in an isolated instance.

## Isolated test instances

Never test in someone's live Roost windows, and never stop Roost by name
(`pkill roost`, `killall roost`). People run several windows at once, holding
real sessions, and an agent may itself be running inside one. Start your own
instance, track its PID, and stop only that PID.

A good isolated instance:

- **Runs under `dbus-run-session`,** so its app registration, notifications and
  portal traffic stay off the real session bus. To see notifications, run a
  small fake `org.freedesktop.Notifications` service on that private bus and
  log what it receives.
- **Uses scratch XDG directories:** `XDG_CONFIG_HOME`, `XDG_STATE_HOME` and
  `XDG_CACHE_HOME`.
- **Looks normal.** Symlink the real `~/.config/ghostty` into the scratch config
  directory. Without it, the window uses Ghostty's default colors and fonts,
  which is confusing next to real windows.
- **Skips first-run prompts** with an empty `<scratch config>/roost/first-run-done`.
- **Leaves real notes alone.** Set `scratchpad-path` and
  `scratchpad-autosave = false` in `<scratch config>/roost/config`.
- **Picks its project and agent** with `ROOST_PROJECT` and `ROOST_AGENT`, and
  unsets any inherited `ROOST_SOCK` and `ROOST_PANE`.
- **Stays out of the way.** On Hyprland, move the window to a hidden special
  workspace as soon as `hyprctl clients -j` lists its PID. Hyprland 0.56
  dispatches in Lua; the old `movetoworkspacesilent` form fails and leaves the
  window on screen:

  ```sh
  hyprctl dispatch 'hl.dsp.window.move({ workspace = "special:roosttest", follow = false, window = "pid:<pid>" })'
  ```

  Wait until the PID is listed, because an unmatched selector could act on the
  focused window. The window still shows for about a second before it moves.

Synthetic key presses (`hl.dsp.send_key_state`) didn't reach a parked window
in testing. Drive behavior another way:
- a fake agent on `ROOST_AGENT`, a script that prints terminal titles with
  `\e]0;<title>\a` and calls `scripts/roost-notify`. Name it `claude` to get
  Claude's detection rules;
- writing to the instance's socket directly
  (`$XDG_RUNTIME_DIR/roost-<pid>.sock`);
- the accessibility API, which works on a parked window. Python's
  `gi.repository.Atspi` can walk the widget tree, read labels and click buttons
  (GTK's role name is `button`). The registry normally starts through systemd,
  which a private bus can't do, so start `/usr/lib/at-spi-bus-launcher
  --launch-immediately` and then `/usr/lib/at-spi2-registryd` inside the
  session before Roost;
- reading its debug log from stderr.

Unix socket paths are limited to 108 bytes, and scratch directories are often
longer. Put test sockets in `$XDG_RUNTIME_DIR`, and don't name them
`roost-*.sock`: Roost sweeps those at startup.

## Probing an agent CLI

Detection rules must match what a tool really shows. To probe one, run it in a
fixed-size tmux pane, for example 120×32, and read back what Roost would see:
`tmux capture-pane -p` for the screen and `#{pane_title}` for the title. Turn
real captures into "captured …" tests in `core/agent_detect.zig`. Re-probe
whenever a tool updates; Claude Code 2.1.308 changed its spinner without
notice.

Nothing automatic catches that kind of change. CI replays saved screens, so
it keeps passing after a tool's look changes, and the hook checks only watch
hooks. After a Claude Code update, check that an un-hooked Agent pane's badge
still changes, or re-probe.

## Debugging crashes

- `coredumpctl list roost` and `coredumpctl info <pid>` give the stack. If a
  system library was replaced on disk since the crash, symbols may not
  resolve; read the stack memory instead (`x/12000gx $sp` and `info symbol`
  in gdb).
- Match the crash time against `/var/log/pacman.log`. Both 2026 crash bugs lined
  up with system updates.

### The pane-close crash

Open as of 2026-10-23; see the [roadmap](../ROADMAP.md#known-issues).

- **Stack:** `Tree.closeNode` → `gtk_paned_set_start_child(null)` →
  `GtkGLArea` unrealize → `delete_one_texture` → `gdk_gl_texture_release` →
  `gdk_memory_texture_from_texture` → `gdk_gl_context_download`
  (`glGetTexImage`), which faults inside the NVIDIA driver.
- **Seen with:** driver 610.57.04 and GTK 4.22.4. Vanilla Ghostty hits the same
  stack on driver 615.78.08 and GTK 4.24.1 (ghostty discussion #14803).
- **Ruled out:** deferring the close to an idle callback, as Ghostty does.
  Ghostty's idle rebuild also unrealizes, and Ghostty still crashes.
- **Untested ideas:** hide panes for a few frames before unparenting them, or
  avoid reparenting the pane that survives.

## Gotchas

- **GTK accelerators with Shift need the uppercase key:** `<Ctrl><Shift>Q`, not
  `<Ctrl><Shift>q`. Shift plus a digit never matches at all, so Roost's
  shortcuts use letters.
- **Ghostty claims keys first.** A terminal surface handles a chord before the
  window's accelerator sees it, so a chord Ghostty binds by default has to be
  unbound (see the injected flags in `app.zig`).
- **Sync focus before tree operations.** `Tree.focused` only follows
  programmatic focus, so structural operations call
  `tree.syncFocusFromWindow()` first to catch mouse clicks.
- **zig-gobject's stream-read binding** types the buffer as `*[*]u8`. Pass
  `@ptrCast(&buf)` of a pointer-aligned buffer.
- **Ghostty's path expansion** returns any string containing `/` unchanged,
  without checking it exists. The agent-command check is a convenience, not a
  guarantee.
- **Theme colors:** use libadwaita's `StyleManager` for the accent color.
  `GtkStyleContext.lookupColor` returns black for libadwaita's colors.
- **Hyprland tiles the window,** so default sizes and maximize calls do
  nothing. With no title bar, the window title is invisible inside the window,
  so in-app context belongs in pane headers.

## Conventions

- **Commits:** `area: outcome`, lowercase, such as
  `ipc: send each agent's hook events to the pane it runs in`. The body says
  what changed and why, and how it was tested.
- **Docs:** README is for users, `docs/` explains the code, and
  [ROADMAP.md](../ROADMAP.md) holds plans and known issues. History belongs in
  commit messages, not in docs.
- **Comments** explain why. The code already says what.
