# Roost — TODO / Handoff

**Resume point (2026-10-23):** a maintenance pass after three months away. Hook badges now track each pane, screen reading understands Claude Code 2.1.308's new spinner, and action popups name their project; see the first Status entry. One open issue: closing a pane can crash Roost, through a GTK + NVIDIA driver bug that vanilla Ghostty hits too; see Open issues. Finished work older than the Status entries lives in `git log`, not here.

**Repo:** https://github.com/scottzirkel/roost (public, branch `main`). Now a supacode-style structure: this project root is the git repo; **Ghostty is a pinned vanilla submodule** at `vendor/ghostty` (`v1.3.1`); our additive source lives in the PARENT (`src/roost/`, `src/main_roost.zig`) + `patches/build.zig.patch` (the one additive build step). `./build.sh` symlinks our src into the submodule, applies the patch, and runs `zig build roost`. The old `roost` branch inside the submodule (commit `c59ce87`) is a local backstop — safe to delete now. This file (`TODO.md`, renamed from `HANDOFF.md`) is now tracked in the repo; `.claude/settings.local.json` stays gitignored (local-only).

Roost is a GTK4 "agent command center" for Omarchy/Hyprland — a focused clone of supacode, built as an **additive soft-fork of Ghostty v1.3.1**. (Working title was "myterm".) Full background + every decision is in Claude **memory** (auto-loaded each session): `roost-app-name`, `roost-repo-structure`, `roost-project-overview`, `roost-product-thesis`, `roost-launch-ux-preference`, `roost-agent-ctrlz-suspend-todo`, `ghostty-surface-embedding-recipe`, `ghostty-build-zig-sframe-workaround`, `gate-on-maintainability-not-feasibility`.


## Status — DONE & verified

### ▶ Maintenance pass (2026-10-23 — built, unit-tested and isolated-tested; NOT yet committed or user-verified)
- **Hook badges no longer stick on ✓.** Once a hook reports, Roost stops reading that pane's screen. Only `Stop` and `Notification` were wired, so nothing ever said "working" again. Added `UserPromptSubmit` and `PostToolBatch` hooks (`roost-notify working`, `async: true` so they never slow the agent) to `~/.claude/settings.json`, `scripts/claude-hooks.json` and both READMEs. Confirmed firing live.
- **Hook events reach the right pane.** Every terminal pane gets its own `ROOST_PANE` (`Leaf.id`, from a process-wide counter), and `roost-notify` sends `pane=<id> <event> …`. `Tree.setAgentStatus` updates only that pane's badge. An unknown or non-Agent pane changes no badge but still gets its popup. A line with no id falls back to the first Agent pane, as before. Without this, a second agent's frequent `working` wiped the first one's 🔔.
  - No Ghostty patch: `GhosttyTerminalPane.applyConfig` gives each surface its own copy of the app config with an extra `env` entry, and Ghostty applies a surface's `env` when it spawns the child.
  - Parsing lives in the portable core, `src/roost/core/hook_msg.zig` (4 tests).
  - Windows still running an older build keep working with the new script: their panes have no `ROOST_PANE`, so it sends the old format.
  - Isolated test: own pane `needs-input` → 🔔 and a popup; unknown pane's `working` → 🔔 kept, no popup; no pane `done` → ✓ and a popup.
- **Claude Code 2.1.308 spinner.** Its title spinner is now ◐/◑ (U+25D0–25D3), not Braille, so a working agent read as idle. `startsWithSpinner` accepts the half-filled circles, with regression tests from a real capture (39 tests). Isolated test with a replayed title sequence: ● then ✓ on the window title.
- **Action popups name the project** ("roost — tests: failed"), captured when the run starts. Formatting is `actions.popupTitle` (5 tests).
- **Checked, not a bug:** the shared "roost-agent" notification id can't replace another window's popup. GLib's freedesktop backend tracks ids per process, and each window is its own process. On GLib 2.90 the second process's first popup went out with `replaces_id=0`.
- **Isolated testing on Hyprland 0.56:** dispatch is Lua now. Park a test window with `hyprctl dispatch 'hl.dsp.window.move({ workspace = "special:roosttest", follow = false, window = "pid:<pid>" })'`, and only once `hyprctl clients -j` lists that pid. The old `movetoworkspacesilent` form fails, and the window then stays on screen. Synthetic keys (`hl.dsp.send_key_state`) did not open the action palette in a parked window, so test logic through unit tests or the IPC socket instead.

### ▶ Crash on font upgrades fixed — link system font libraries (2026-10-13 — built, isolated-tested, installed, committed; NOT yet user-verified)
A system update that upgraded font packages crashed three Roost windows
(15:02–15:04, all SIGSEGV → abort). Every stack was the same: GTK's settings
listener saw the portal's `org.gnome.fontconfig serial` change and called
`FcInitReinitialize` → `FcConfigDestroy` → `FcFontSetDestroy` →
`FcPatternDestroy`, which read freed memory.

**Cause:** Ghostty's build bundles its own fontconfig (2.14.2), FreeType,
HarfBuzz, libpng and zlib unless told otherwise. GTK and Pango still load the
system copies (fontconfig 2.18.3), so Roost carried two copies of each. The
linker exported the 27 bundled `Fc*` functions that GTK/Pango call, so those
calls went to the bundled copy while every other `Fc*` call went to the system
one. Font objects made by one copy were freed by the other. The bundled 2.14
also can't parse the system's 2.18 config files: 630 "invalid constant"
warnings in a 30-second run.

**Fix:** `build.sh` now passes `-fsys=fontconfig -fsys=freetype -fsys=harfbuzz
-fsys=libpng -fsys=zlib`, matching Arch's own `ghostty` package. It's a build
flag, so `vendor/ghostty` stays zero-diff. The README requirements mention the
five libraries.

**Verified (isolated test instance):** private D-Bus session + a fake
Settings portal, private font dir/cache/config, window parked on a hidden
Hyprland special workspace. Each round replaced the fonts on disk, ran
`fc-cache -f` and sent `SettingChanged`. New build: 5/5 rounds survived, and an
`LD_PRELOAD` shim confirmed 5/5 `FcInitReinitialize` calls ran and succeeded.
Bundled `Fc*`/`FT_*`/`hb_*` symbols: 0 (were 160 FreeType, 518 HarfBuzz).
Same font faces load as before.

**Not reproduced:** the old build also survived the same 5 rounds in a fresh
instance. That fits the cause: the mixed copies drift only after hours of
normal font use, which is why the long-running windows crashed and a window
opened at 15:03 did not. So "fixed" rests on the stack trace plus removing the
duplicate libraries, not on a failing-then-passing test. Running windows keep
the old code until relaunched.

### ▶ Project name in agent notifications (2026-07-29 — user-verified, committed)
With several Roost windows open, the notification popup was the one place Roost
spoke with no window attached: the title was a fixed `Agent needs you` /
`Agent finished`, the body was the agent's own message, and nothing said WHICH
project. The sound doesn't disambiguate either — it encodes the event
(`message` for needs-input, `complete` for done), not the window.

`ipc.Server` gained `project: ?*const Project` + a `title_buf`, and `notify`
now composes `"<project> — <title>"` via `titled()`. Notes:
- **A pointer to `AppContext.current`, not a copied name.** `rebuildWorkspace`
  reassigns that field in place, so a project switch re-points notifications
  for free. (Verified by construction — app.zig ~1528 deinit-then-assign — not
  by a live switch.)
- **Wired in `run` after the AppContext is built, not at `Server.init`** — the
  server is created ~25 lines earlier, before the AppContext exists. Hence
  optional, defaulting null → unprefixed title.
- **`title_buf` is a Server field, not a local** — `titled` returns a slice of
  it, which would dangle from a stack buffer. Main-loop-only, so one shared
  buffer is safe. Overflow and the empty-path sentinel Project both fall back
  to the bare title.
- **Verified live via `dbus-monitor`** against a throwaway instance in a project
  named `acme-checkout`: `Notify` carried `"acme-checkout — Agent needs you"` /
  `"acme-checkout — Agent finished"`. User confirmed the popup looked good.

**Both follow-ups closed 2026-10-23** (see the Maintenance pass entry): the
fixed `roost-agent` id turned out NOT to cross windows (gio tracks ids per
process, and each window is its own process), and the wired-actions popup now
names the project too.

### ▶ Agent-state detection + portable core (2026-07-29 — built, live-verified, committed `501d4df`)
Prompted by a comparison against **herdr** (`github.com/ogulcancelik/herdr`, Rust
TUI agent multiplexer, Apache-2.0) — the two ideas worth taking were its
hook-or-scrape agent detection and its control API. Detection is done; the
control API is not started.

- **`src/roost/core/agent_detect.zig` (NEW, ~640 lines incl. 24 tests).** Pure
  std-only classifier: `Manifest` (per-agent ruleset) → `Rule` (priority,
  `Region` of title/bottom-N-lines/screen, `Match` of any/all/same_line_all/
  spinner) → `classify()` → `Verdict`. Highest priority wins, ties to the earlier
  rule, nothing matched → `.unknown` (caller holds previous state). `Tracker`
  layers the lifecycle on top: synthesizes `.done` on working→idle AND
  blocked→idle (both end a run), keeps `.done` sticky until work resumes, and
  `report()` marks a pane hook-driven so scraping defers to it **permanently**.
  Built-ins: claude / codex / opencode / gemini + a `generic` fallback (spinner
  + y/n only) so an unknown agent still gets a live badge. Allocation-free on
  the hot path (fixed `Lines` window of borrowed slices). Braille-spinner check
  is a 3-byte UTF-8 test, no decoder. Rules were written from observable chrome,
  NOT copied from herdr's manifests — herdr is Apache-2.0, we're MIT.
- **`scripts/check-core.sh` (NEW) + build.sh step 1.5.** Fails the build if
  anything under `src/roost/core/` imports gtk/adw/gdk/gio/glib/gobject or
  climbs into the Ghostty tree (`@import("../../`). Verified in both directions
  with a throwaway probe file. This is the seam for a macOS shell — see below.
- **`terminal_pane.zig`:** added `captureScreen()` (visible rows only, via
  `Selection.init(pages.getTopLeft(.active), pages.getBottomRight(.active))` →
  `selectionString`) and `title()` (`Surface.getTitle()`). `captureScreen` exists
  separately from `captureText` on purpose: detection polls it, so cost must
  track window size, not scrollback depth.
- **`tree.zig`:** `Leaf` gained `agent: detect.Tracker` + `manifest` — **per-leaf,
  so N agent panes each track independently**. `manifest` is chosen at spawn from
  the launch command (`detect.manifestFor(agent_cmd)`). New `pollAgents()` walk
  (skips non-agent leaves, hooked panes, and dead children), `agentAttention()`
  max-rollup, and `AgentStatus.fromDetect`/`toDetect`. `setAgentStatus` now
  routes hook events through the first agent leaf's tracker (so `hooked` gets set)
  as well as painting the label.
- **`app.zig`:** 600ms `glib.timeoutAdd` → `onDetectTick` → `pollAgents` +
  `applyAttention`; source removed on teardown via `defer`. Window title gets a
  `🔔 `/`✓ `/`● ` prefix for the rolled-up state, composed by **stripping the
  prefix off the live title and re-prefixing** — no cached base string, so it
  stays correct no matter which path last set the title (startup / project
  switch / worktree switch) and never re-shells to `git` for the branch.
  Gotcha hit: `state` is already a module-level const in app.zig, so locals had
  to be named `attn`.
- **Verified live** (fake `claude` on PATH cycling working→blocked→idle,
  window title read back via `hyprctl clients`): single agent cycled
  `● → 🔔 → ✓ → ●` correctly; with a **second** Agent pane added (Ctrl+Shift+A)
  the rollup stayed on `🔔`/`✓` instead of following either agent's own cycle,
  which is the max-over-independent-trackers behavior. 24/24 core tests, md 14/14,
  ansi 10/10, build + additive gate + core gate all green.
- **Known gap — FIXED 2026-10-23:** hook events used to address the **first**
  agent pane, because the `ROOST_SOCK` protocol had no pane identity. They now
  carry `ROOST_PANE` (see the Maintenance pass entry).

#### Manifests rewritten against REAL probes (2026-07-29, same day)
The first cut of the rulesets was guesswork and was **mostly wrong**. Each CLI
was then driven for real inside a fixed 120x32 tmux pane, reading back exactly
what the detector gets (`capture-pane -p` = visible screen, `#{pane_title}` =
OSC title). Findings, all now encoded + covered by "captured …" regression
tests built from verbatim screens (35 tests total):
- **The OSC title is the best signal; the footer is the worst.** Claude Code 2.x
  does **not** print "esc to interrupt" while working — the footer reads
  "✽ Whirlpooling… (8s · ↓ 6 tokens)". The reliable signal is the title:
  Braille while working (`⠂ Claude Code`), `✳ ` at rest (`✳ Claude Code`, then
  `✳ <conversation summary>` after a turn). The original `? for shortcuts` idle
  rule never fires in this version.
- **Spinner glyphs are not universally Braille.** claude and codex animate
  Braille into the *title*, but claude's footer spinner is ✢/✶/✻/✽ and
  opencode's is ⬝ (U+2B1D). Braille-only footer rules silently never fired.
- **opencode says "esc interrupt" — no "to".** The original rule missed it.
- **A blocked agent can look idle in its title.** Claude's plan-approval menu
  ("Would you like to proceed?" / "❯ 1. Yes, and use auto mode") renders while
  the title still reads `✳ `. This is why screen-based blocked rules sit at
  940–950 and title-based idle rules at 90–100. Verified, and now a test.
- **codex**: title `⠦ <dir>` working / plain `<dir>` idle; footer "• Working (2s
  • esc to interrupt)"; update dialog "Press enter to continue" = blocked.
- **gemini**: only startup chrome observable (no API key on this machine) — the
  trust dialog and API-key dialog are verified blocked; its working rules are
  marked UNVERIFIED in the source. Its title reads "◇  Ready (dir)" *even while
  a modal is blocking*, hence the low priority on that idle rule.
- **`generic` deliberately has no idle rule.** For an unknown CLI there's
  nothing safe to match, and a wrong idle would fabricate working→idle edges and
  phantom "done" notifications.
- **End-to-end with the real `claude` inside Roost:** title log shows
  `✳ Claude Code` → `⠂ Claude Code` → `⠂ Count from 1 to 40` → `✳ Count from 1
  to 40`, and the window title reached `✓` — which is only reachable by passing
  through `working`. Pipeline confirmed against the real agent.

### ▶ BUG FIXED (pre-existing, NOT from this work) — agent command couldn't take arguments
**Symptom:** any `ROOST_AGENT` or `agent` setting containing arguments
(`claude --resume`, `codex exec`) silently dropped the Agent pane to a bare
shell. Found while setting up the live detection test —
`ROOST_AGENT='claude "…"'` produced a zsh pane.

**Cause:** `resolveAgentCmd` (app.zig) gated on `commandOnPath(cmd)` →
`internal_os.path.expand(alloc, cmd)` against the **whole string**, so it
searched PATH for a binary literally named `claude --resume`, missed, and
returned null (the shell-fallback contract). The command is spawned via
`.shell`, so arguments were always legal at spawn time — only the *check* was
wrong.

**Fix:** new `detect.firstToken()` in `core/agent_detect.zig` (quote-aware: a
quoted first token containing spaces stays whole). `resolveAgentCmd` now accepts
the command if the whole string resolves **or** its first token does —
whole-string first, so nothing that resolved before stops resolving (e.g. an
unquoted path containing spaces, which `expand` passes through because it
contains `/`). `commandName` was refactored onto `firstToken`, so it picks up
quote handling for free. `commandOnPath` relaxed to `[]const u8`.

Also documented in `commandOnPath`: Ghostty's `expand` returns any string
containing `/` **verbatim without stat-ing it**, so a path-shaped command always
"resolves". Left as-is — the check is a UX guard (fall back to a shell rather
than show a "command not found" pane), not a security boundary.

**Verified live:** `ROOST_AGENT='claude "count slowly from 1 to 40…"'` now spawns
`claude count slowly from 1 to 40, one number per line` in the Agent pane (was a
bare zsh), the claude manifest is still selected (`commandName` → `firstToken`),
and detection ran the full `✳ → ⠂ → ✳` cycle to a `✓` window title. Negative case
re-checked: `ROOST_AGENT='definitelynotarealagent --flag'` still falls back to
the shell. 6 new unit tests (37 total).


### ▶ macOS portability — decision recorded (2026-07-29)
Roost is **not** Wayland-coupled (zero Wayland references; the "Hyprland"
mentions are comments about keymap feel). It is GTK4/libadwaita-coupled, and the
coupling measured out at roughly: 1,681 lines already portable, ~595 more after
light surgery, `tree.zig`'s 1,752 splittable into model + widget realization, and
~4,046 genuinely platform shell (`app.zig` 3,142 / `scratchpad_pane` / `ipc`).
So about half the codebase can be shared.

**There is no GTK-on-macOS path**: `vendor/ghostty/src/apprt/runtime.zig` offers
only `.none` and `.gtk` for executables, and its own comment says macOS uses
Xcode against libghostty. So macOS Roost = **Swift/AppKit shell + libghostty +
our `core/` as a static lib behind a C ABI** (Ghostty already ships the
`include/ghostty.h` + `module.modulemap` pattern to copy). User confirmed they
have a Mac and want Roost usable on both — but explicitly **not** session
sharing/sync between them, so the two installs stay independent.

**Explicit non-goal:** herdr's detach / remote / SSH. That works because herdr
streams cells from a server; Roost's whole value is in-process GPU surfaces.
Can't have both — don't chase it.

- **Rename → "Roost" + dedicated app id (2026-06-23):** binary, source dir (`src/roost/` + `src/main_roost.zig`), build step (`zig build roost`), env vars (`ROOST_SOCK` / `ROOST_PROJECT` / `ROOST_AGENT`), IPC socket (`roost-<pid>.sock`), and XDG dir (`<config>/roost/`) all renamed from "myterm". Dedicated GTK app id **`dev.scottzirkel.Roost`** is forced in-process via `injectAppId` (src/roost/app.zig): it prepends `--class=<id>` to `std.os.argv` BEFORE apprt loads config — additive (no Ghostty-source edit), and a valid `class` is used verbatim, so debug + release share the id (no `-debug` suffix). `launchedFromDesktop` keys off an env var, not argv, so desktop detection is undisturbed. Launcher reinstalled as `roost.desktop` (StartupWMClass `dev.scottzirkel.Roost`); live `~/.claude/settings.json` hooks repointed to `scripts/roost-notify`; `~/.config/myterm` migrated to `~/.config/roost` (layouts/recents preserved). Gate branch renamed `myterm`→`roost`. **NOTE:** the project dir is now `/home/scott/projects/roost` (renamed + memory migrated 2026-06-23 — see Naming / repo). **Icon: DONE** 2026-06-29 (`429c021`) — ghost-bird asset installed (see the Roost-icon item under Older deferred). **App-id runtime-verified on a live display 2026-06-29** — `hyprctl clients` showed `class`/`initialClass` = `dev.scottzirkel.Roost` for a launched instance.
- **Phase 0–2:** real Ghostty `Surface` panes in our own GtkApplicationWindow; free-form role-typed pane **tree** (split/add-by-role/close/reset-to-default), layout **persisted** & restored (per-project as of 3c — see below), keyboard nav.
- **3a:** scratchpad selection/line → Agent pane (`Ctrl+Enter`).
- **3b:** Agent pane runs `claude`; Unix-socket IPC (`src/roost/ipc.zig`, path exported as `ROOST_SOCK`) → native desktop notification + Agent-pane status badge; wired to Claude Code `Stop`/`Notification` hooks (now in `~/.claude/settings.json`) via `scripts/roost-notify`.
- **3c (core):** **Ctrl+Shift+B** → branch-name dialog → `git worktree add <repo>.worktrees/<branch> -b <branch>` → switch the whole workspace into it (reuses `rebuildWorkspace`). New `src/roost/git.zig` = `git` subprocess helpers (`std.process.Child`). **Per-worktree layout:** the layout file is now keyed by a Wyhash of the project path (`<config>/roost/layouts/<hash>.json`); switching projects/worktrees saves the OUTGOING arrangement and restores the TARGET dir's own (replaces the old global `layout.json` + carry-across). Split ratios are captured live (incl. manual drags) on any save/clean-exit and re-applied on reopen. Forced launch-`maximize()` removed (WM size/tiling wins).
- **3d (launcher UX + chooser):** **Ctrl+O** opens a project/worktree chooser (recents + current repo's worktrees + "Open Folder…" + "New Worktree…"). **Default = replace THIS window** with the picked project (`rebuildWorkspace`); **"New Window"** opens the selected row as a NEW detached window instead (`openProjectNewWindow`: `setsid` child, stdio /dev/null, `--gtk-single-instance=false` → its own window, no controlling terminal). "Open Folder…" also replaces the current window. Single-instance forwarding: a 2nd **desktop** launch forwards an app-level `present-chooser` GAction over D-Bus and exits (no stray window) — NOT `activate()` (Ghostty overrides it to open a window). Desktop launch with none running opens the **last project** (`resolveInitialProject` + `internal_os.launchedFromDesktop`); terminal `cd && roost` still opens cwd. Single-click selects, double-click switches; a 400ms guard ignores the phantom row-activation when the dialog pops under the pointer. Subsumes the old 3c.2 switcher. New `git.zig` `worktreeList`.
- **3e (focus & pane UX, 2026-06-23 — user-verified, committed on `main` — see Git below):** all in `tree.zig` / `layout.zig` / `app.zig`; gate still only `build.zig`.
  - **Active-pane indicator:** every pane box carries a faint `.roost-pane` border (app-level CSS provider, `installPaneCss` in app.zig); the focused pane also gets `.roost-active` (brighter border — color-only, so the terminal grid never reflows). Driven by ONE window `notify::focus-widget` handler → `Workspace.updateHighlight` → `Tree.updateHighlightFromWindow`, which covers mouse clicks, keyboard nav, AND programmatic grabs (all route through `grabFocus`). `Tree.highlighted` is nulled at both node-free sites (`closeFocused` + `destroyNode`) so a closed pane can't dangle. Intensity (`0.06` base / `0.26` active rgba-white) is a one-line tweak.
  - **Spatial directional focus (Hyprland-style):** `moveFocus` rewritten — lays the tree into normalized [0,1]² rects from each split's LIVE `GtkPaned` ratio, then picks the pane with the most perpendicular-axis overlap in the move direction (tie-break nearest). Fixes the old `edgeLeaf` bug where focus "followed pane numbers, not positions" (bottom-left → right wrongly landed top-right). NO graphene (that import would need `SharedDeps.zig` → break the gate); geometry comes from paned ratios only. Removed dead `edgeLeaf` + `Direction.orientation/towardEnd`.
  - **Pane swap:** **Ctrl+Shift+Alt+Arrow** swaps the focused pane with the neighbor in that direction — reuses the SAME `findInDirection` search as focus (so swap-X and focus-X always agree), focus follows the moved pane (Hyprland "move window"), persists, no-op at edges. Mechanically swaps the two leaves' `Slot`s via existing `attach`/`detach`, holding a widget ref during reparenting. Handles siblings + different-depth subtrees. **UPDATE 2026-06-24 — swap now PRESERVES each pane's size (committed `59eb8d1`, user-verified):** sizes travel WITH the panes (a short pane swapped above a long one stays short) instead of inheriting the destination slot. `swapNodes` captures each leaf's pre-swap extent + parent orientation (`captureGeo`) and, after re-attaching, restores it via the new parent's divider (`restoreGeo`): exact for sibling swaps (one `setPosition`), per-pane for same-orientation neighbors, and a no-op fallback for cross-orientation moves (where "keep size" is ill-defined and would squish bystanders).
- **Git:** branch `roost` (renamed from `myterm`) in `vendor/ghostty` off tag `v1.3.1` → `2f24299` (0–3a) → `a882c70` (3b) → `8ef05b5` (3c) → `f3f0a66` (3d) → rename commit. `git diff v1.3.1 HEAD` = only our files (the additive gate). `scripts/` are tracked in the parent repo (`roost-launch` added `6aa213d`). 3e and all later work (incl. swap-keeps-size `59eb8d1`, reload `9b0a667`) are committed on `main`.

## Operational playbook
- **Build:** `./build.sh` from the project root (overlays our `src/roost` into the Ghostty submodule via symlink, applies `patches/build.zig.patch`, runs `zig build roost`) → `vendor/ghostty/zig-out/bin/roost`. Zig **0.15.2** at `~/.local/bin/zig`. Edit source in the PARENT `src/roost/` (symlinked in). Gate check: `git -C vendor/ghostty diff --name-only v1.3.1` = only `build.zig`.
- **Toolchain:** if Zig is reinstalled, re-run `scripts/patch-zig-linker.sh` (forces LLVM+LLD around the Arch glibc SFrame relocation — Zig issue #31272).
- **Run:** from a git repo `cd <repo> && <…>/zig-out/bin/roost`, or `ROOST_PROJECT=<repo> <…>/roost`. Project dir = `ROOST_PROJECT` → cwd. **Never** a positional arg (Ghostty's config parser rejects bare argv).
- **Multi-window caveat (bit us hard while debugging):** each launch writes the same log file and its own `$XDG_RUNTIME_DIR/roost-<pid>.sock`. Never `pkill`/`killall` roost: live windows hold real sessions. Test in an isolated instance instead (private D-Bus, its own XDG dirs and log, window parked on a hidden special workspace; see the 2026-10-23 Status entry), stop only the PID you started, and target its socket (`roost-<pid>.sock`).
- **Action test fixture (gitignored):** `.roost/actions.json` in this repo holds sample actions (Echo OK → notify, Failing Tests → on_failure agent, List Files → scratchpad). A test instance with `ROOST_PROJECT` set to this repo loads them too.
- **Gate check:** `git -C vendor/ghostty diff --name-only v1.3.1` → must be only `build.zig` (our additive step). Our `src/roost`/`main_roost.zig` are untracked symlinks in the submodule (`??`), the canonical copies live in the parent repo.
- **Dev pattern:** delegate each feature to a background `Agent` with a detailed brief (it edits + compiles); then **rebuild + run + verify yourself** — agent sandboxes sometimes can't run git/zig and have shipped non-compiling guesses.
- **Reload (dev loop):** edit → `./build.sh` → **Ctrl+Shift+Q** → confirm → the window restarts into the freshly-built binary (`win.reload` → `onReload`/`doReload`/`reExecSelf`; committed `4f85097`, user-verified). Native code can't hot-swap, so reload **re-execs in place** (`std.posix.execvpeZ` on **`argv[0]`**, reusing our live argv) — same PID, NO spawned process, no single-instance forwarding, no quit-race. Layout (roles/splits/**sizes**) is persisted first and restored by the new image; pane processes + scrollback start fresh (unavoidable across a process swap). Confirms first (Cancel default) since it ends everything in the panes. **Gotchas (hard-won, 2026-06-25 — both bit us live):**
  - Re-exec MUST use `argv[0]`, not `std.fs.selfExePath`/`/proc/self/exe`: after `./build.sh` replaces the binary, that link resolves to the deleted old inode (`… (deleted)`) → `execve` returns `error.FileNotFound`. `argv[0]` is a plain path that still points at the new file.
  - **Ctrl+Shift+Q** took two fixes: (1) the GTK accelerator must be UPPERCASE `<Ctrl><Shift>Q` (Shift delivers the uppercase keyval; lowercase silently never matches — the same gotcha as the other shift-combos); (2) Ghostty binds `ctrl+shift+q → quit` by DEFAULT and its terminal surface consumes the chord before our window accelerator fires, so we inject **`--keybind=ctrl+shift+q=unbind`** into our own argv (`injectArgs`, alongside `--class`) to free it. Roost keeps its own quit on Ctrl+Q. (Earlier "spawn + quit" reload was flaky — spawn/quit race, single-instance forwarding, and a corrupted flag could strand it on a config-error dialog — hence the switch to re-exec.)
- **CLI launcher:** `roost` on PATH is now `scripts/roost-launch` (symlink), a wrapper that `setsid`-detaches the binary, inherits cwd (so `cd proj && roost` still picks the project), logs to `${XDG_STATE_HOME:-~/.local/state}/roost.log`, and closes the launching terminal. The `.desktop` file still points at the binary directly (no terminal there).

## Gotchas (hard-won)
- Code lives in the parent repo's `src/roost/` (+ thin `src/main_roost.zig`) and is symlinked into `vendor/ghostty/src/` at build time so it can relative-import Ghostty internals (it MUST sit inside the Ghostty tree to compile). Only `terminal_pane.zig` names `Surface`; everything else goes through the `TerminalPane` abstraction.
- App id: Ghostty derives it ONLY from `config.class` (valid → used verbatim, else default `com.mitchellh.ghostty[-debug]`), loaded from config files + argv inside apprt init. We can't edit Ghostty source (the gate), so we inject `--class` into `std.os.argv` from our entry point. Do NOT set `class` in the user's shared `~/.config/ghostty/config` (would also change real Ghostty).
- zig-gobject: `g_input_stream_read`'s buffer param is typed `*[*]u8` → pass `@ptrCast(&buf)` of an `align(8)` buffer. **Shift+digit accelerators don't match** (use Ctrl+Alt or Ctrl+Shift+letter). Structural ops call `tree.syncFocusFromWindow(window)` first — `Tree.focused` otherwise only tracks programmatic focus, not mouse clicks.
- gio notifications are silent by design (no system audio).

## Open issues

### Crash when a pane closes (GTK + NVIDIA driver; vanilla Ghostty too)
- **Symptom:** closing a pane, or the reparent that follows, can SIGSEGV. Every stack runs `GtkGLArea` unrealize → `delete_one_texture` → `gdk_gl_texture_release` → `gdk_memory_texture_from_texture` → `gdk_gl_context_download` (`glGetTexImage`), and faults inside the NVIDIA driver.
- **Not Roost's bug:** vanilla Ghostty crashes the same way (ghostty-org/ghostty discussion #14803: driver 615.78.08, GTK 4.24.1). Roost's crashes were on driver 610.57.04, GTK 4.22.4.
- **Timing clue:** the crashes began after the 2026-10-13 update that brought egl-wayland 1.1.22, egl-gbm and mesa. None since the 2026-10-22 reboot.
- **Ruled out:** deferring the close to an idle callback, as Ghostty does. Ghostty's idle rebuild also unrealizes, and Ghostty still crashes.
- **Untested ideas:** hide the panes for a few frames before unparenting them; avoid reparenting the surviving pane.
- **Next:** watch #14803 and GTK/NVIDIA releases for a fix. Not posting Roost's data to Ghostty for now (decided 2026-10-23).

### Needs user verification
- The font-upgrade crash fix (2026-10-13, see Status) has only been tested in an isolated instance.
- The 2026-10-23 maintenance pass (see Status) has only been unit-tested and tested in isolated instances.

## Launcher / multi-window (operational)
- **Isolation by default (committed `197032d`, user-verified 2026-06-25):** every roost window is its OWN process — a hang/crash in one can't take down the others. The desktop launcher (`scripts/roost.desktop`, installed at `~/.local/share/applications/roost.desktop`) **no longer passes `--gtk-single-instance`** (NOT a copy of the repo file — the installed one must be re-`cp`'d when the repo changes). No shared primary, no D-Bus forwarding. The app id (`dev.scottzirkel.Roost`) is forced in code (`injectArgs`), so the Exec needs no `--class`.
- **Relaunch → chooser:** a **desktop** launch (sets `GIO_LAUNCHED_DESKTOP_FILE_PID`) while another roost is alive opens the project CHOOSER instead of auto-opening the last project (each window picks its own). Liveness = `ipc.liveSiblingExists()` pinging `roost-<pid>.sock` PIDs (ignores stale sockets). First launch with no live sibling → opens the last project directly. Terminal `cd && roost` (CLI) → opens cwd, never the chooser. Chooser focuses the top row (Enter opens it); a pick on a no-project window opens directly (no switch confirm).
- **New windows from within roost** = detached child processes (`openProjectNewWindow`: `setsid` child, stdio /dev/null, `--gtk-single-instance=false`): one process per window, full isolation (the recents file is the only shared state).
- **Chooser "New Worktree…" → new window** — *DONE — committed `61d4ddb` 2026-06-29.* The chooser's "New Worktree…" now creates the branch+worktree and opens it in a NEW detached window (a `WorktreeReq.new_window` flag → `openProjectNewWindow`; dialog wording adapts); Ctrl+Shift+B still switches THIS window into it.

## Naming / repo
Rename to **Roost** + dedicated app id **`dev.scottzirkel.Roost`** + the clean **repo extraction** are all DONE. Published at https://github.com/scottzirkel/roost (public) in the supacode model: small repo + Ghostty as a pinned vanilla submodule + additive overlay (see top of file). Namespace convention for all the user's apps: `dev.scottzirkel.<App>` (owns both scottzirkel.dev and .com).

**Fully renamed (verified 2026-06-23):** the on-disk project dir is now `/home/scott/projects/roost` (old `.../myterm` gone); the desktop launcher `Exec` and `~/.claude/settings.json` hooks point at `roost`; this project's Claude memory was migrated into the re-keyed dir `-home-scott-projects-roost/memory/` (it had been left empty after the re-key); the four `myterm-*` memory slugs were renamed to `roost-*` (files + `name:` frontmatter + `[[links]]` + `MEMORY.md` index); and the `patch-zig-linker.sh` sentinel + the comment it injects into the live Zig `Compile.zig` were renamed `myterm:`→`roost:`. Stale `myterm` tokens and paths inside the memory bodies were updated to `roost`; only a few explicit "renamed from working title myterm" history markers remain (in `roost-app-name`, the `roost-project-overview` banner, and the `MEMORY.md` index). **One leftover:** the orphaned `-home-scott-projects-myterm/memory/` duplicate could not be auto-deleted (permission declined on the `.claude` path); remove it manually with `rm -rf ~/.claude/projects/-home-scott-projects-myterm/memory` if you want — harmless to leave (its project key is dead, so it's never loaded). The session-transcript `.jsonl` files in that project dir were left untouched.
