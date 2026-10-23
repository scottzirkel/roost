# Roost roadmap

What's next for Roost, in order. Finished work lives in the git log, and how
things work lives in [docs/architecture.md](docs/architecture.md).

Last updated 2026-10-23.

## Now: make silent breakage loud

In 2026 two things broke quietly for months: the hooks never reported
"working", and Claude Code changed its spinner, so a busy agent looked idle.
This step makes that kind of breakage visible.

- [x] A GitHub Action runs the unit tests and `scripts/check-core.sh` on every
      push.
- [x] Settings shows whether the Claude Code hooks are installed and complete,
      with a button that adds missing ones after asking.
- [x] Roost warns once when installed hooks don't run: one hook stays silent
      while the others report, or the screen shows Claude finishing turns that
      no hook reported.
- [ ] Decide between debug and release builds for daily use. Debug builds are
      slower but log more; see
      [build modes](docs/development.md#build-modes).

The one gap left is a change in how an agent's screen looks. CI replays saved
screens, so it can't see a new Claude Code release; re-probe after updates (see
[probing an agent CLI](docs/development.md#probing-an-agent-cli)).

## Soon: keep the agent's conversation across a reload

Reload (`Ctrl+Shift+Q`) restarts every pane, so a running Claude Code session
ends, and you have to find it again with `/resume`.

- [ ] Remember each Agent pane's Claude session. Every hook payload carries a
      `session_id`, so `roost-notify` can send it along with the hook name
      (a new `ROOST_PROTOCOL` version), and Roost saves it with the layout.
- [ ] After a reload, start that pane's agent with `claude --resume <id>`, so
      the conversation picks up where it was.
- [ ] Do this only for reload. A new window, or reopening a project after
      quitting, still starts a fresh session.

## Next: a Waybar indicator

See every window's agent state from the bar, and jump to the window that needs
you.

- [ ] The socket answers requests, starting with `status`: the window's
      project, branch and agent state.
- [ ] `roost status --all` asks every running window.
- [ ] A Waybar module shows 🔔 and ● counts. Clicking it focuses the window
      that needs you.

This is the first slice of the control API below: the same socket and the same
message format.

## Then: the control API

A `roost` command that the agent, or you, can run inside a pane to drive its
window:

- `roost scratch read` and `roost scratch append "…"` read your notes and write
  back a plan or summary.
- `roost open path:line` jumps the Editor pane to a file and line.
- `roost run <action> --wait` runs one of your wired actions and returns its
  exit code. It can only run actions you defined, never arbitrary commands.
- `roost status` reports the window's project, branch and agent state.

The agent learns the commands from a short note in the project's `CLAUDE.md`.
The message format lives in `src/roost/core/`, so the Mac app can reuse it.

## Later: macOS

A native Mac Roost: a Swift/AppKit shell around libghostty and Roost's shared
core. GTK has no macOS path, so the shell has to be native; see
[macOS](docs/architecture.md#macos). The Linux and Mac installs stay
independent, with no session sync.

- [ ] Split `tree.zig` into a portable layout model in `core/` and the GTK
      widgets that show it.
- [ ] Wrap `core/` in a C library (`roost.h`), the way Ghostty packages its
      terminal as libghostty.
- [ ] Spike: one Mac window with a Ghostty terminal running Claude, plus hook
      notifications.
- [ ] Parity: splits and roles, the scratchpad, the worktree chooser, and
      actions.

This needs a Mac in the loop for building and testing, or a macOS CI runner.

## Known issues

- **Closing a pane can crash Roost on NVIDIA.** The crash happens while GTK
  frees a terminal's GL texture, inside the NVIDIA driver. Vanilla Ghostty
  crashes the same way
  ([ghostty discussion #14803](https://github.com/ghostty-org/ghostty/discussions/14803)).
  It started after the 2026-10-13 graphics-driver update, and hasn't recurred
  since the 2026-10-22 reboot. We're waiting on a GTK or driver fix and not
  reporting upstream for now. Details are in
  [development](docs/development.md#the-pane-close-crash).

## Not planned

- **Detached, remote or SSH sessions**, the way herdr does them. They need a
  server that streams terminal cells, while Roost's value is real in-process
  GPU terminals. You can't have both.
- **Features for several agents in one window.** Roost supports it, but the
  usual setup is one agent per window, so it isn't a priority.
