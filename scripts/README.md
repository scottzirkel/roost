# Roost agent integration scripts

These wire **Claude Code** into the Roost window so the Agent pane can raise a
native desktop notification and a status badge when the agent finishes or needs
you.

## How it works

1. When Roost starts it opens a Unix-domain socket and exports its path as the
   environment variable **`ROOST_SOCK`**. Every pane Roost spawns — including
   the Agent pane that runs `claude` — inherits this variable.
2. `roost-notify` connects to `$ROOST_SOCK` and writes one short line:
   `<event> [message]`, where `<event>` is one of `done`, `needs-input`,
   `working`.
3. Roost reacts: it shows a native notification (for `done` / `needs-input`)
   and updates the Agent pane's header badge.

If `ROOST_SOCK` is unset or the socket is gone, `roost-notify` does nothing
and exits 0 — it can never break your agent.

## Install

1. Make the helper executable (once):

   ```sh
   chmod +x /home/scott/projects/roost/scripts/roost-notify
   ```

2. Merge the `hooks` block from `claude-hooks.json` into your
   `~/.claude/settings.json`. **Roost does NOT edit that file for you.**

   - If you have no `hooks` key yet, copy the whole `"hooks": { ... }` object in.
   - If you already have a `hooks` key, merge by event: append our `Stop` and
     `Notification` entries into your existing arrays for those events.
   - Replace `/ABSOLUTE/PATH/TO/scripts` with the real absolute path, e.g.
     `/home/scott/projects/roost/scripts`.

   A minimal merged result looks like:

   ```json
   {
     "hooks": {
       "Stop": [
         { "hooks": [ { "type": "command", "command": "/home/scott/projects/roost/scripts/roost-notify done" } ] }
       ],
       "Notification": [
         { "hooks": [ { "type": "command", "command": "/home/scott/projects/roost/scripts/roost-notify needs-input" } ] }
       ]
     }
   }
   ```

   - **`Stop`** fires when Claude Code finishes a turn → `roost-notify done`
     → notification "Agent finished" + badge `✓ done`.
   - **`Notification`** fires when Claude Code wants your attention (permission
     prompt, idle input request) → `roost-notify needs-input`. The hook's JSON
     payload (delivered on stdin) carries a `message` field, which
     `roost-notify` forwards as the notification body → badge `🔔 needs you`.

## Manual test

With Roost running, from any pane inside it:

```sh
roost-notify needs-input "approve the migration?"
roost-notify done
```

(Use the full path to `roost-notify` if `scripts/` isn't on your `PATH`.)
