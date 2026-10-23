# Roost roadmap

What's next for Roost, in order. Finished work lives in the git log, and how
things work lives in [docs/architecture.md](docs/architecture.md).

Last updated 2026-10-23.

## Now: the control API

More `roost` commands that the agent, or you, can run inside a pane to drive
its window. They build on the socket and message format `roost status`
already uses.

- `roost scratch read` and `roost scratch append "…"` read your notes and write
  back a plan or summary.
- `roost open path:line` jumps the Editor pane to a file and line.
- `roost run <action> --wait` runs one of your wired actions and returns its
  exit code. It can only run actions you defined, never arbitrary commands.

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

- **A change in how an agent's screen looks goes unnoticed.** The hook
  checks catch hooks that stop running, and CI replays saved screens, so
  neither sees a new Claude Code release change its spinner or prompts.
  Re-probe after updates; see
  [probing an agent CLI](docs/development.md#probing-an-agent-cli).
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
