# Roost scripts

| Script | What it's for |
| --- | --- |
| [`roost-notify`](#roost-notify--agent-hooks) | Lets Claude Code's hooks tell Roost what the agent is doing. |
| [`claude-hooks.json`](#roost-notify--agent-hooks) | The hook snippet to merge into `~/.claude/settings.json`. |
| [`roost-launch`](#roost-launch--the-cli-launcher) | The `roost` command: starts Roost detached from the terminal. |
| [`roost.desktop`](#roostdesktop--the-desktop-launcher) | The desktop launcher entry. |
| [`install-icon.sh`](#install-iconsh--the-app-icon) | Installs the app icon. |
| [`check-core.sh`](#check-coresh--the-core-purity-check) | Fails the build if `src/roost/core/` imports a UI toolkit. |
| [`patch-zig-linker.sh`](#patch-zig-linkersh--arch-linker-workaround) | Works around an Arch + Zig 0.15.2 linker bug. |

Paths below use `/path/to/roost` for your clone.

## `roost-notify` — agent hooks

Wires **Claude Code** into the Roost window, so the Agent pane raises a native
desktop notification and a status badge when the agent finishes or needs you.

### How it works

1. When Roost starts it opens a Unix-domain socket and exports its path as
   **`ROOST_SOCK`**. Every pane Roost spawns inherits it. Each pane also gets
   its own **`ROOST_PANE`**, a number that names that pane.
2. `roost-notify` connects to `$ROOST_SOCK` and writes one short line:
   `[pane=<id>] <event> [message]`, where `<event>` is `done`, `needs-input`
   or `working`, and `<id>` is `$ROOST_PANE`.
3. Roost shows a native notification (for `done` and `needs-input`) and updates
   the badge of the Agent pane the agent runs in. A line without `pane=` goes
   to the first Agent pane.

If `ROOST_SOCK` is unset or the socket is gone, `roost-notify` does nothing and
exits 0, so it can never break your agent.

### Install

1. Make the helper executable (once):

   ```sh
   chmod +x /path/to/roost/scripts/roost-notify
   ```

2. Merge the `hooks` block from `claude-hooks.json` into your
   `~/.claude/settings.json`. **Roost doesn't edit that file for you.**

   - With no `hooks` key yet, copy the whole `"hooks": { ... }` object in.
   - With an existing `hooks` key, merge by event: append our `Stop`,
     `Notification`, `UserPromptSubmit` and `PostToolBatch` entries to your
     arrays for those events.
   - Replace `/ABSOLUTE/PATH/TO/scripts` with the real path.

   A minimal merged result:

   ```json
   {
     "hooks": {
       "Stop": [
         { "hooks": [ { "type": "command", "command": "/path/to/roost/scripts/roost-notify done" } ] }
       ],
       "Notification": [
         { "hooks": [ { "type": "command", "command": "/path/to/roost/scripts/roost-notify needs-input" } ] }
       ],
       "UserPromptSubmit": [
         { "hooks": [ { "type": "command", "command": "/path/to/roost/scripts/roost-notify working", "async": true } ] }
       ],
       "PostToolBatch": [
         { "hooks": [ { "type": "command", "command": "/path/to/roost/scripts/roost-notify working", "async": true } ] }
       ]
     }
   }
   ```

   - **`Stop`** fires when Claude Code finishes a turn: notification "Agent
     finished" and badge `✓ done`.
   - **`Notification`** fires when Claude Code wants your attention, such as a
     permission prompt. The hook's `message` becomes the notification body, and
     the badge shows `🔔 needs you`.
   - **`UserPromptSubmit`** (you send a prompt) and **`PostToolBatch`** (a batch
     of tool calls finished, including one you just approved) set the badge to
     `● working`, with no notification. Roost stops reading a pane's screen once
     a hook has reported, so without these the badge would stay on `✓ done`
     during the next run, and `🔔` would stay up after you answer. `async`
     keeps them from slowing the agent down.

### Manual test

With Roost running, from any pane inside it:

```sh
/path/to/roost/scripts/roost-notify needs-input "approve the migration?"
/path/to/roost/scripts/roost-notify done
```

## `roost-launch` — the CLI launcher

Makes the `roost` command a pure launcher. It starts Roost in its own session
(`setsid`) so it outlives the terminal, keeps the current directory (so
`cd project && roost` still picks that project), and then closes the launching
terminal.

```sh
ln -sfn /path/to/roost/scripts/roost-launch ~/.local/bin/roost
```

Output and startup errors go to `${XDG_STATE_HOME:-~/.local/state}/roost.log`.
If the binary is missing, the wrapper fails before closing the terminal, so a
broken launch is never hidden. To launch without closing the terminal, run the
binary directly: `vendor/ghostty/zig-out/bin/roost`.

## `roost.desktop` — the desktop launcher

Copy it to `~/.local/share/applications/` after pointing `Exec=` at your clone.
It runs the binary directly, not `roost-launch`. The installed copy doesn't
update itself, so copy it again when the repo's version changes.

## `install-icon.sh` — the app icon

Installs the Roost icon (`dev.scottzirkel.Roost`) into your hicolor icon theme,
so the launcher, taskbar, Alt-Tab and notifications show it. It renders
`src/roost/icons/scalable/apps/dev.scottzirkel.Roost.svg`, the square version of
the logo, to PNGs at the standard sizes, under
`${XDG_DATA_HOME:-~/.local/share}/icons/hicolor`.

```sh
/path/to/roost/scripts/install-icon.sh
```

Safe to re-run after editing the SVG. Needs `rsvg-convert` (librsvg).

## `check-core.sh` — the core purity check

Fails if anything in `src/roost/core/` imports GTK, libadwaita, GLib or
Ghostty. `build.sh` runs it on every build. See
[the portable core](../docs/architecture.md#the-portable-core).

## `patch-zig-linker.sh` — Arch linker workaround

Patches your local Zig 0.15.2 to link with LLVM and LLD, working around Zig
issue #31272 on Arch. Safe to re-run; re-run it after reinstalling Zig. See
[Toolchain](../docs/development.md#toolchain).
