# Roost roadmap

What's next for Roost, in order. Finished work lives in the git log, and how
things work lives in [docs/architecture.md](docs/architecture.md).

Last updated 2026-11-17.

## Now: ideas from Solo

[Solo](https://soloterm.com) is a desktop app that runs coding agents next to
a project's dev servers. These ideas from it fit Roost's aim of wiring tools
into the agent. Each new `roost` command gets a line in the agent's note
(`agent_note` in `src/roost/core/control.zig`), and its message format goes in
`src/roost/core/`, so the Mac app can reuse it.

- **Hold text meant for a busy agent.** A failed action pastes its output into
  the Agent pane right away. If Claude is showing a permission prompt, Claude
  Code throws the paste away, so the failure never reaches the conversation.
  It can't answer the prompt, because Roost pastes with bracketed paste and
  the prompt ignores pastes (probed with Claude Code on 2026-11-17). When it
  does arrive, it sits in Claude's input box unsent, so Claude doesn't start
  on it until you press Enter. Hold the text until the agent is done or idle,
  then paste it and send Enter, and show in the header that it's waiting.
  Only send Enter when no prompt is showing: an Enter at a permission prompt
  picks "Yes". Never hold your own typing.
- **Services see your shell's PATH.** A service runs with the window's
  environment, so a command in a folder your shell's startup files add to
  PATH, like `~/bin`, isn't found unless you give its full path. Read your
  login shell's environment once (`$SHELL -lic env`, with a time limit) and
  start services with it, as Solo does.
- **Show what each agent is working on.** Claude Code names the task in its
  terminal title, such as "✳ Fix login redirect". Add that title to
  `roost status` and the bar widget's list, so you can tell several windows
  apart without opening each. Solo asks a model for a summary instead; the
  title costs nothing.
- **Suggest actions from the project's scripts.** When a project has no
  `actions.json`, list the scripts in its `composer.json`, `package.json`,
  `Makefile` or `justfile` in the action menu, ready to run or save.

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
  It started after the 2026-10-13 graphics-driver update and still happens:
  six times from 2026-10-14 to 2026-11-16. Closing the window no longer
  triggers it, because quitting now exits before GTK frees anything. Closing
  a single pane still can. We're waiting on a GTK or driver fix and not
  reporting upstream for now. Details are in
  [development](docs/development.md#the-pane-close-crash).

## Not planned

- **Detached, remote or SSH sessions**, the way herdr does them. They need a
  server that streams terminal cells, while Roost's value is real in-process
  GPU terminals. You can't have both.
- **Features for several agents in one window.** Roost supports it, but the
  usual setup is one agent per window, so it isn't a priority. That includes
  Solo's shared to-do lists, locks, and agents that start other agents.
- **Prompt templates,** as Solo has. Claude Code's own slash commands and
  skills already cover them.
