# How Roost works

Roost is a GTK4/libadwaita window full of real Ghostty terminals, arranged as
role-typed panes, with an agent-aware layer wired around them. This page
explains how it's built and why. For building and testing, see
[development.md](development.md).

## Built on Ghostty without forking it

Roost's code imports Ghostty internals directly, so it has to compile inside
Ghostty's source tree. But it never edits Ghostty's files. The build is an
overlay:

- `vendor/ghostty` is a git submodule pinned to vanilla Ghostty `v1.3.1`.
- `build.sh` symlinks `src/roost/` and `src/main_roost.zig` into that tree.
- `patches/build.zig.patch` adds one build step that registers the `roost`
  executable. It's the only change to Ghostty's tree.

**The gate:** `git -C vendor/ghostty diff --name-only v1.3.1` must list only
`build.zig`. The question that set this rule was "will this stay maintainable
when Ghostty updates?", not "can we make it work?". Edits scattered through
upstream code are how a soft fork becomes unmaintainable, so we measure the
diff instead of trusting a convention.

### Embedding a Ghostty terminal

A Ghostty `Surface` is a real GTK widget (it subclasses `adw.Bin`), so it can be
parented into any container. Roost stands it up like Ghostty's own app does:

1. Create the core `App` once per process: the shared font grid, mailbox and
   surface registry.
2. Create Ghostty's GObject `Application`. It must be the default GTK
   application, because surfaces call `Application.default()` everywhere.
3. Drive `core_app.tick()` from Roost's main loop.
4. Create each pane with `Surface.new()`. The surface spawns its PTY, renderer
   and IO threads when it's realized.

Only `terminal_pane.zig` names `Surface`. Everything else goes through the
`TerminalPane` interface, so the terminal backend could be swapped without
touching layout or app code.

### Things Roost does without patching Ghostty

- **App id.** Ghostty derives it only from its `class` config, so Roost appends
  `--class=dev.scottzirkel.Roost` to its own argv before Ghostty reads config.
  It never sets `class` in the shared Ghostty config, which would change real
  Ghostty too.
- **Keys and notifications.** The same trick unbinds Ghostty's default
  `ctrl+shift+q` (quit) and `ctrl+,`, so Roost can use them for reload and
  Settings. It also turns off Ghostty's own desktop notifications, so there
  aren't two popups per event.
- **No positional arguments.** Ghostty parses argv as config, so a bare
  argument pops up a config-error dialog. Roost takes its inputs from the
  environment (`ROOST_PROJECT`, `ROOST_AGENT`) or the working directory.
- **Per-pane environment.** `Surface.new()` has no env option, but a surface
  spawns its child with its own config's `env` entries. Each pane gets a
  private copy of the app config with `ROOST_PANE` added
  (`GhosttyTerminalPane.applyConfig`).
- **System libraries.** `build.sh` passes `-fsys=fontconfig`, `freetype`,
  `harfbuzz`, `libpng` and `zlib`. Ghostty otherwise bundles its own copies,
  while GTK loads the system ones; with two copies in one process, a font
  upgrade crashed Roost when objects made by one copy were freed by the other.

## Source map

| File | What it does |
| --- | --- |
| `src/main_roost.zig` | Entry point: runs a `roost` command, or starts the window. |
| `src/roost/cli.zig` | The `roost` commands (`status`, `scratch`, `output`, `run`, `open`): find the window's socket, ask, and print. |
| `src/roost/app.zig` | Startup, the window, the main loop, actions, dialogs, settings, and the wired-actions runner. |
| `src/roost/tree.zig` | The pane tree: split, add, close, swap, resize, focus, persistence, agent polling. |
| `src/roost/layout.zig` | `Workspace`, the thin layer between the app and the tree. |
| `src/roost/terminal_pane.zig` | The `TerminalPane` interface and its Ghostty backend. |
| `src/roost/scratchpad_pane.zig` | The Markdown scratchpad: live styling and autosave. |
| `src/roost/ipc.zig` | The socket (hook messages and requests) and desktop notifications. |
| `src/roost/services.zig` | Services: starting, watching and stopping them, picking them up after a reload, and the header's Services menu. |
| `src/roost/editor_remote.zig` | `roost open`: moves the Editor pane's Neovim through `nvim --server`. |
| `src/roost/config.zig` | `~/.config/roost/config`, a `key = value` file. |
| `src/roost/project.zig` | Project resolution, recent projects, and layout files. |
| `src/roost/git.zig` | Git helpers for worktrees and branch names. |
| `src/roost/proc.zig` | Run a command and capture its output. |
| `src/roost/actions.zig` | The wired-actions data model and JSON loading. |
| `src/roost/md.zig` | The Markdown scanner behind scratchpad styling. |
| `src/roost/ansi.zig` | Strips escape sequences from action output. |
| `src/roost/core/agent_detect.zig` | Agent-state detection from screen and title. |
| `src/roost/core/hook_msg.zig` | Parses the hook socket's messages. |
| `src/roost/core/control.zig` | Requests a client sends a window, the replies, and the agent's note on them. |
| `src/roost/core/backups.zig` | The Scratchpad copies saved before a replace or clear. |
| `src/roost/hypr.zig` | Hyprland: each Roost window's workspace, and the rules and moves that put reopened windows back. |
| `src/roost/core/services.zig` | Services' approvals, log paths, restart backoff, and what a reload hands over. |
| `src/roost/core/resume.zig` | Starting an Agent pane with its saved conversation (resume, or ask first), and the list `roost close --all` saves. |
| `src/roost/core/nvim.zig` | The Editor pane's Neovim: its listen address and the expression that opens a file at a line. |
| `src/roost/core/git_head.zig` | Reads the checked-out branch from `.git/HEAD`, without running git. |
| `src/roost/core/claude_hooks.zig` | Checks and adds Claude Code hooks in `settings.json`, and tracks which ones run. |
| `integrations/omarchy/` | The Omarchy bar widget: a QML plugin that reads `roost status --all --watch`. |
| `src/roost/build_info.zig` | Generated by `build.sh`: where the clone lives, so Settings can point hooks at its `roost-notify`. |

`actions.zig`, `md.zig`, `ansi.zig`, `cli.zig`, `hypr.zig` and everything in `core/` use
only Zig's standard library, so they have standalone unit tests.

## The portable core

`src/roost/core/` holds logic that doesn't need a UI toolkit. Nothing in it may
import GTK, libadwaita, GLib or Ghostty; `scripts/check-core.sh` enforces that
on every build. The reason is macOS: a Mac Roost needs a native shell, but it
shouldn't need a second copy of the logic. Anything that works on plain data
belongs in `core/`; anything that touches a widget stays outside it.

## Panes and layout

- **A binary tree of `GtkPaned` splits.** Each leaf is a role-typed pane: Agent,
  Shell, Git, Editor, Files or Scratchpad. Git runs lazygit and Files runs
  yazi when they're on PATH, else the shell. The default is a 2×2 of Agent, Git, Shell
  and Scratchpad.
- **Group splits.** A tree's outer divider is shared by everything on each
  side, so "split this whole column or row" (`Ctrl+Shift+Alt+R`/`D`) is what
  lets you build grids with independent dividers.
- **Per-project layouts.** Each project directory gets
  `~/.config/roost/layouts/<hash of path>.json`, with split sizes. Switching
  projects saves the old layout and restores the new one. An optional
  `default-layout.json` replaces the built-in 2×2.
- **Spatial focus.** Directional focus and swap lay the tree out as rectangles
  from each split's live ratio, then pick the pane with the most overlap in
  that direction. Swapping keeps each pane's size.
- **Panes close when their process exits.** Closing the last pane quits.
- **Ctrl+Z in an Agent pane is Claude Code's undo.** Ctrl+Z would suspend
  `claude` with no shell to resume it. A capture-phase key handler sends byte
  `0x1F` (Claude's undo) instead. Other panes keep normal suspend.

## Windows and processes

- **Every window is its own process,** so a hang or crash in one can't take
  down the others. The recent-projects file is the only shared state.
- **From a terminal,** `cd project && roost` opens that directory.
- **From the desktop launcher,** Roost opens the last project. If another Roost
  is already running, it opens the project chooser instead, so each window
  picks its own project.
- **New windows from inside Roost** are detached child processes.
- **Quitting exits without tearing the window down.** After the confirmation,
  Roost stops running actions, saves the layout and any pending scratchpad
  edit, removes its socket, and calls `_exit`. Letting GTK destroy the
  terminals sometimes crashes inside the NVIDIA driver (see
  [the close crash](development.md#the-pane-close-crash)), and the process is
  ending anyway. The processes in the panes end as their terminals close.
- **Reload** (`Ctrl+Shift+Q`) saves the layout and re-execs the binary in
  place, so a fresh build takes over the same window. It re-execs `argv[0]`,
  not `/proc/self/exe`, because after a rebuild that link points to the
  deleted old file.
- **Reload keeps the agent's conversation.** Each Agent pane remembers the
  Claude session its hooks last reported. The SessionStart hook reports it as
  soon as a conversation starts or is resumed; without it, a reload before the
  first prompt would have no session to resume. Reload passes the sessions to the
  new image in `ROOST_RESUME_SESSIONS`, one per Agent pane in tree order. The
  restored panes then start `claude --resume <id> || claude`, so a session
  Claude can't find falls back to a fresh one instead of closing the pane. The
  variable is cleared at startup, so new windows and later panes start fresh.
- **The layout file keeps each Agent pane's session too,** as `"session"` on
  its leaf, so a quit or a crash doesn't lose it. A hook reporting a new
  session marks the tree (`sessions_changed`), and the agent-poll tick saves
  the layout within 600 ms. Opening the project then builds the Agent pane
  with a shell command that asks `Resume your last conversation in this pane?
  [Y/n]` before starting `claude` (`core/resume.zig`). A question in the pane,
  not a dialog, because the pane's command is fixed when the tree is built.
  Sessions in the user's default layout are dropped: they belong to another
  project.
- **Which start a pane gets:** a reload's queued session resumes at once; so
  does `roost reopen`, which sets `ROOST_RESUME_SAVED` and queues the saved
  layout's sessions the same way. Otherwise a saved session is asked about,
  and no session starts fresh.
- **`roost close --all`** asks every window for `close`. The window answers,
  then quits 150 ms later through the normal quit path minus its question, so
  it saves the layout with its sessions. The CLI first writes the projects to
  `$XDG_STATE_HOME/roost/closed-windows.json`, with each window's Hyprland
  workspace from `hyprctl clients -j`, and closes its own window last,
  since that ends the CLI too. It waits for each pid to exit, and names any
  window that didn't, such as one on an older build.
- **`roost reopen`** starts a detached window per saved project that has none
  open (`setsid`, like "open in a new window"), then removes the list so a
  second run doesn't double up.
- **The window and the bar run the CLI** for both, so there's one
  implementation. Close All Windows (`Ctrl+Shift+Alt+Q`, the window menu)
  lists the windows from `roost status --all --json`, run asynchronously,
  since the window answers that request too and its loop must keep running.
  On confirm it starts `roost close --all --yes`, detached with `setsid`, so
  it outlives the window; it inherits our `ROOST_SOCK`, so it closes this
  window last. The Quit dialog's Close All Windows does the same without the
  list. Reopen (the window menu, the chooser) starts `roost reopen`. They run
  argv[0], since `/proc/self/exe` points at a deleted file after a rebuild.
- **A desktop launch with no Roost running reopens the closed windows** when
  there's a saved list: the process starts `roost reopen` and exits before
  building a window of its own. Once reopened, the list is gone, so the next
  launch opens the last project as before.
- **`roost status --all --json` adds `"closed": N`** while windows are saved
  for reopening. The bar widget stays visible on it, shows ↺ N, and offers
  Reopen; its Close all needs a second click.
- **Reopened windows go back to their workspaces** on Hyprland (`hypr.zig`).
  Before starting each window, `reopen` turns on a named rule
  (`roost-reopen-<n>`) matching its first title, `Roost — <project>`, plus
  ` · <branch>` in a repo. The rule sends the window to its workspace
  silently, without focus. A rule set at open avoids the flash of moving it after it shows.
  Once the windows answer on their sockets, it moves any that landed
  elsewhere by pid, then turns the rules off. Without Hyprland it skips all
  of this.

## Agent awareness

Roost tracks each Agent pane's state: working (●), needs you (🔔), done (✓) or
idle. The window title starts with whichever state most wants you, so the
taskbar shows it too. State comes from two sources. Hooks always win; screen
reading only fills the gaps.

### Hooks

- Each process listens on `$XDG_RUNTIME_DIR/roost-<pid>.sock` and exports the
  path as `ROOST_SOCK`. Each terminal pane also gets its own `ROOST_PANE`
  number.
- Claude Code hooks run `scripts/roost-notify`, which sends one line:
  `[pane=<id>] [hook=<Event>] [session=<id>] <event> [message]`. Events are
  `working`, `needs-input`, `done` and `session`, which only records the
  session; `core/hook_msg.zig` parses them.
  `hook=` names the Claude Code hook that ran, and `session=` the Claude
  session, for reload. Roost exports `ROOST_PROTOCOL=3` to say which fields it
  understands, because an older Roost drops a line with a field it doesn't
  know.
- The event updates that pane's badge. An unknown pane, or a non-Agent pane,
  changes no badge but still gets its popup. A line with no pane id goes to the
  first Agent pane.
- `needs-input` and `done` raise a desktop notification titled with the
  project, such as "roost — Agent needs you". An optional sound plays through
  `canberra-gtk-play`, since gio notifications are silent.
- Agent popups show the Claude logo (`src/roost/icons/notify/claude.png`),
  and Roost's own popups (action results, hook warnings) show the Roost logo.
  Roost sends each as a file path in the clone, not an icon-theme name, so
  they don't depend on another app installing its icon. A popup whose icon
  the daemon can't find shows as a "?" tile in the Omarchy shell.
- Once a pane reports through a hook, Roost stops reading its screen for good.
  That's why the `working` hooks matter: without them a pane stays on ✓ through
  its next run.
- Reads are asynchronous, so a client that connects and stalls can't freeze
  the window. Sockets left behind by dead processes are swept at startup.
- Every popup uses the same notification id, but ids are tracked per process,
  so one window's popup never replaces another's.

### Requests: status and the Scratchpad

The same socket answers requests (`core/control.zig`). A client sends one
line: a request word, then for some requests a JSON object with the argument.
The window replies with one line of JSON and closes.

- **`status`** returns the window's pid, project, branch and most urgent agent
  state. `roost status --all` finds every window by its
  `roost-<pid>.sock` file and asks each one; `--watch` asks again every
  second and prints only when something changed, so a bar runs one process
  instead of one per poll.
- **The branch comes from `.git/HEAD`,** not from running git. Requests are
  answered on the main loop, and a bar asks every second.
- **The reply is written asynchronously,** like the read, so a client that
  asks and never reads can't stall the window.
- **Request words never collide with hook events.** An older Roost reads a
  request as an unknown event and closes without a reply, so clients list it
  with only its pid.
- **`scratch-read`, `scratch-append` and `scratch-replace`** are
  `roost scratch`. They act on the window's first Scratchpad pane. An append
  adds a new paragraph at the end; a replace swaps the whole text, and
  `roost scratch clear` is a replace with none. Each is one undo step, and
  autosave writes it like typing. The text travels as JSON, so its newlines
  stay inside the one line.
- **The agent may remove what you wrote, but only when you ask.** It reads,
  makes the change, and sends the whole text back. The agent note says so;
  the window can't tell who asked. A replace loses anything typed between the
  read and the write, and `Ctrl+Z` brings that back too.
- **A replace saves the old notes to disk first** (`core/backups.zig`), in
  `<stem>-backups/` next to the notes file, keeping the newest 10. GTK keeps
  undo history only while the window is open, and autosave writes the new text
  within a second, so after a reload the copy is the only way back. If the copy
  can't be written, the replace doesn't happen. The reply names the copy, and
  the CLI prints it, so the agent can restore it.
- **A line ends at a newline, or when the client closes.** Requests send a
  newline so they can wait for the answer; `roost-notify` just closes. Reads
  continue until the line is complete, up to 512 KB. Hook lines are still cut
  at 1 KB.
- **`output`, `actions`, `run` and `open` need more than the workspace,** so
  the server hands them to a `Host` (`onControlRequest` in `app.zig`) with a
  `Pending` reply. The host finishes it once, now or later. The connection
  stays open until then, which is how a waited `run` answers when the action
  ends and `open` answers when Neovim has moved. The request's strings live
  only for the call, so the host copies what it keeps.
- **`output` reads a pane or an action.** A number counts panes in tree
  order, like Alt+1…9. A role name reads the first pane with that role. Any
  other word is an action label, matched without case: a running action's
  output so far, else its last run's. Each action's last output is kept
  (its last 1 MB), and forgotten when a project switch reloads the actions.
- **`run` only runs actions,** found by label, never a command. Without
  `wait` it starts the action like the menu does and answers at once. With
  `wait`, the result goes back to the caller and the routes are skipped, since
  the caller is usually the agent the routes would reach. No modal opens for
  a waited run.
- **`open` steers Neovim, and only Neovim.** When `$EDITOR` (else `$VISUAL`,
  else `nvim`) is Neovim, an Editor pane starts it with `--listen
  $XDG_RUNTIME_DIR/roost-nvim-<pid>-<pane>-<random>`; the random part keeps a
  reload's new Neovim from meeting the old socket. `open` runs `nvim --server
  <addr> --remote-expr <expr>`, where the expression is Lua through
  `luaeval` (`nvim_exec_lua` isn't callable from an expression). It skips
  `:edit` when the file is already showing, which would refuse a modified
  buffer. The run is asynchronous with a 5-second limit, so a Neovim stuck on
  a prompt never blocks the window. It doesn't focus the Editor pane, since
  you may be typing to the agent. Other editors have no such door, so `open`
  says it needs Neovim.
- **The agent learns the commands when its conversation starts.** The
  SessionStart hook runs `roost-notify session`, which asks the window for
  `agent-note` and prints the reply. Claude Code adds a SessionStart hook's
  output to the conversation. The note comes from the window, so it names only
  what that build supports, and an older window gives none.
- **Commands run in the window's binary.** `main` checks for a command word
  before Ghostty reads argv as config. Ghostty flags start with `-` or `+`, so
  a bare word can't be mistaken for one. `scripts/roost-launch` passes
  commands straight through, because otherwise it would open a window and
  hang up its caller.
- **The Omarchy bar widget** (`integrations/omarchy/`) runs one
  `roost status --all --watch` under `setpriv --pdeathsig`, so the watcher
  dies with the shell, and restarts it if it exits. It focuses a window with
  `hl.dsp.focus({ window = "pid:<pid>" })`. It's installed by copying, not
  linking, because Omarchy refuses symlinks in a plugin folder.

### Knowing the hooks work

A missing or dead hook fails silently: the badge falls back to reading the
screen, and notifications just stop. So Roost checks both halves.

- **Installed.** Settings reads the user's and the project's Claude Code
  settings files and shows each required hook as installed, missing, or broken
  (its `roost-notify` path doesn't exist). It can add missing hooks after
  asking. The file is re-written in Claude Code's own format, with a backup,
  in one rename, and through a symlink if it is one.
- **Running.** Installed isn't enough: a Claude Code update can rename or drop
  an event, and the file still looks right. The hooks that do run are the
  evidence for the ones that don't. `claude_hooks.Liveness` counts runs per
  hook name, and flags UserPromptSubmit when three turns finished without one,
  or Stop when five prompts arrived without a finished turn.
- **Reaching Roost at all.** When the screen shows Claude finish two turns in a
  pane no hook has reported for, and the Stop hook is installed, the hooks
  aren't getting through.

Either finding raises one notification per window. These catch hooks that
stop running. They can't catch Claude Code changing how its screen looks;
only re-probing does (see
[development.md](development.md#probing-an-agent-cli)).

### Screen reading

Every 600 ms, Roost reads each unhooked Agent pane's visible screen and
terminal title, and classifies them with that agent's ruleset
(`core/agent_detect.zig`). There are rulesets for `claude`, `codex`,
`opencode` and `gemini`, plus a generic fallback. Lessons from probing the real
tools:

- **The title is the best signal; the footer is the worst.** Claude Code
  animates a spinner in the title while working and shows `✳` at rest.
- **Spinner glyphs change without notice.** Claude Code's title spinner was
  Braille until 2.1.308 switched to ◐◑. Re-probe when an agent updates; the
  "captured" tests hold real screens and titles.
- **A blocked agent can look idle in its title,** so screen-based "blocked"
  rules outrank title-based "idle" rules.
- **The generic fallback has no idle rule.** For an unknown tool nothing is
  safe to match, and a wrong idle would fake "done" notifications.
- **"Done" is a transition, not a picture.** The tracker reports done when an
  agent goes from working (or blocked) to idle.

Rules were written from what each tool shows on screen, not copied from herdr,
which is Apache-2.0 while Roost is MIT.

## Wired actions

Actions are commands you define that run in the background and send their
output somewhere: to the Agent, Shell or Scratchpad pane, to a notification,
or nowhere. The route can depend on the exit code, so failing tests can go to
the agent while passing tests just notify.

- Definitions come from `~/.config/roost/actions.json` and
  `<project>/.roost/actions.json`. Project entries replace global ones with the
  same label.
- Commands run on a background thread, so a long test suite never blocks the
  window. Output streams into a progress view, and a Stop button kills the
  command's process group.
- Result popups are titled with the project the action ran in.

## Services

Services are wired actions with `"service": true` that keep running
(`services.zig`, with the portable parts in `core/services.zig`).

- **Where they come from.** `loadActions` splits the actions files into
  one-shot actions, for the action menu, and services. `actions.load` sets
  `from_project` on each action from the file it came from, after parsing, so
  a project's file can't claim to be the user's own.
- **Approval.** A project's service starts on its own only once approved, for
  that exact command; approvals live in
  `~/.config/roost/approved-services.json`. Until then the Services menu
  shows the command and "Approve and Start". No dialog: one would pop up on
  whatever the user is typing in.
- **Starting.** fork and exec, not std's `Child`: the output goes straight to
  the log file, and the child resets every signal to its default and clears
  the mask before exec. Ghostty ignores SIGPIPE, and an ignored signal stays
  ignored through exec, where a shell can't even trap it. The service leads
  its own process group, so a signal reaches everything it started.
- **Watching.** A thread per service blocks in `waitpid` and posts the end to
  the main loop. A service that ends on its own restarts after a backoff
  (1 s doubling to 60 s, back to 1 s after a run of a minute or more).
- **Stopping.** SIGINT to the group, like Ctrl+C in a terminal, then SIGTERM
  after 5 s and SIGKILL after 3 more. Quitting does the same, blocking for up
  to 7 s before `_exit`, so `roost close --all` waits up to 15 s per window.
- **Reload.** The log file, not a pipe, is what lets a service outlive a
  reload: the exec closes every pipe. The service stays our child through the
  exec (same pid), so the new build waits on it again. `doReload` passes the
  running services (label, command, pid) and the hand-stopped ones in
  `ROOST_SERVICES`; startup takes it out of the environment before any pane
  starts, adopts each pid only if `/proc` says it's our child, and stops one
  whose definition changed.
- **One copy at a time.** A crash or a kill doesn't stop services: they're in
  their own process group, not on the window's terminals. So each running
  service has a pid file beside its log: pid, start time from `/proc`, the
  owning window's pid, and the command. Before starting a service, a window
  reads it. A live process with the same start time (so not a reused pid)
  whose owner window is gone is taken over: the window watches it by polling,
  since it's no longer our child, and can still signal its group. If the
  owner is a live Roost window (its socket answers), this window leaves the
  service to it. A copy running an old command is stopped, and the new one
  started.
- **Project switch.** The old project's services are stopped and retired, and
  freed once they exit; the new project's start.
- **Logs** are `~/.local/state/roost/services/<hash of project>/<label>.log`.
  A fresh start keeps the last run as `.log.1`; a restart appends after a
  `--- roost: restarted after exit N ---` line, so a crash stays readable.
  `roost output <service>` and the menu's Output read the end of it.

## Scratchpad

- A `GtkTextView` with Typora-style live Markdown. `md.zig` turns the text into
  spans, and Roost applies text tags. The text itself is never changed, so
  saves and "send to agent" always see the raw Markdown.
- Markdown markers are hidden except on the cursor's line, where they show
  dimmed so they stay editable.
- Colors follow the theme: the text color from the widget, and the accent from
  libadwaita's style manager. Styling refreshes when the accent or light/dark
  mode changes. Don't use `GtkStyleContext.lookupColor("accent_color")`: with
  current libadwaita it reports success and returns black.
- Each project's notes autosave to `<project>/.roost/scratchpad.md`, at most a
  second after a change, and again when the pane closes.

## macOS

Decided 2026-07-29. Roost isn't tied to Wayland, only to GTK4/libadwaita, and
GTK has no macOS path: Ghostty's own Mac app is built in Xcode against
libghostty. So a Mac Roost would be a Swift/AppKit shell, plus libghostty, plus
`core/` compiled as a static library behind a C header. Ghostty already ships
that pattern (`include/ghostty.h` and a module map).

Measured in July: about half the code can be shared. Roughly 1,700 lines were
already portable, about 600 more need light surgery, `tree.zig` can split into a
model and its widgets, and about 4,000 lines are genuinely platform shell. The
plan is in the [roadmap](../ROADMAP.md#later-macos).

## Accepted limitations

A full code audit in June 2026 fixed 28 findings. These five were left on
purpose:

- **One read per hook message.** The socket assumes a message arrives in one
  read. The only sender writes one short line to a local socket, so framing
  would be over-engineering.
- **A live PID counts as a live Roost.** Sibling detection trusts that the PID
  in `roost-<pid>.sock` is still Roost. A recycled PID at worst opens the
  chooser when it didn't need to, or leaves one stale socket file.
- **Config files over 64 KiB are rejected.** The file holds about eight
  settings; an oversized one is logged and defaults are used.
- **The build patch isn't idempotent by itself.** `build.sh` resets
  `build.zig` before re-applying it, and fails loudly if that breaks.
- **The submodule looks dirty after a build.** The symlinks and the patched
  `build.zig` are the build step. The pinned commit, which is what the gate
  checks, stays clean.
