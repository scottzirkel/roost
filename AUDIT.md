# Roost — code audit follow-ups

Whole-codebase audit of `src/roost/` + `main_roost.zig` + the build overlay
(`build.sh`, `patches/build.zig.patch`), run 2026-06-30 against commit
`13d8d4f`. Methodology: 18 review units (the two big files — `app.zig`,
`tree.zig` — split by lens: memory-safety / concurrency / correctness /
simplification; one finder per smaller file; one for the build glue), each
finding then independently, adversarially verified before it was kept.
46 candidates → 33 verified (23 CONFIRMED, 10 PLAUSIBLE), 8 refuted. The
vendored Ghostty submodule was out of scope.

Two recurring hazard themes: **GTK widget-lifecycle / teardown ordering**
and **error-path memory ownership**.

## Already fixed
- **14 of 33** addressed:
  - The 2 HIGH + 4 MEDIUM + 3 durability + 3 action-modal follow-ups in
    `fc904e0` ("Audit fixes: teardown UAFs, fd/zombie leak, atomic writes,
    IPC main-loop unblock").
  - The 2 simplifications (`focus-n` collapse, unused `setupShortcuts`
    param) — see the commit that adds this file.
- **19 remain below**, none reachable in ordinary use (they need OOM, a
  pathological input, or are cosmetic). Line numbers are as of the audit
  commit and may have drifted slightly after the fix commits — the symbol
  name is the reliable locator.

---

## OOM-gated error-path unsafety (6)
Real UAF / double-free / leaks, but only reachable under allocation failure
(rare with `c_allocator`).

- **`app.zig` · `resolveAgentCmd` (~511) · low/CONFIRMED** — the `dupeZ(...)
  catch cmd` OOM fallback returns a borrowed Config-owned string into
  `app_ctx.agent_cmd`; a later Settings agent edit frees it → UAF on the next
  workspace rebuild. **Fix:** `catch null` (fall back to shell, the existing
  null contract).
- **`config.zig` · `load` (~52) · low/CONFIRMED** — `dupeZ(u8, "claude")
  catch "claude"` stores a static literal in the owned `agent` field;
  `deinit`/`setAgent` then `free()` a non-heap pointer. **Fix:** track
  ownership (an `agent_owned` bool) or abort load on that OOM.
- **`git.zig` · `addWorktree` (~87) · low/CONFIRMED** — both failure-message
  allocs use `catch null`, and `null` is the *success* sentinel, so an OOM
  reports a failed `git worktree add` as success → "created" UX for a missing
  dir. **Fix:** return an error union, or have the caller verify `dest` exists.
- **`proc.zig` · `run` (~55) · low/CONFIRMED** — if the second `toOwnedSlice`
  OOMs, the first (already-emptied list) leaks its buffer. **Fix:** bind the
  first slice to a local with its own `errdefer alloc.free(out)`.
- **`tree.zig` · `buildFromSer` (~374) · low/CONFIRMED** — the errdefer
  `destroyNode(start/end)` frees the node + pane but leaves the leaf's
  still-floating box+label unparented → widget leak on the error path.
  **Fix:** `g_object_ref_sink` + `unref` the floating box in the errdefer.
- **`tree.zig` · `splitFocused` / `splitGroup` (~891 / ~933) · low/CONFIRMED**
  — the detached focused-leaf widget survives only on a held ref; if the
  following `makeSplit` `create(Node)` OOMs there is no errdefer to re-attach,
  so the widget finalizes while `focused`/parent still point at it (latent
  UAF) and the new leaf (live surface + child) leaks. **Fix:** reorder so the
  alloc precedes the detach, or add `errdefer { attach(slot, leaf);
  destroyNode(new_leaf); }`.

## Correctness / cosmetic (5)

- **`ansi.zig` · `.esc` else branch (~48) · low/CONFIRMED** — a literal ESC in
  `.esc` is consumed as a 2-char escape's second byte instead of restarting,
  so `\x1b\x1b[31m…` leaks the SGR code as text. Same in `.osc_esc` (~60).
  **Fix:** add `0x1b => {}` (stay in `.esc`) before the `else` arm.
- **`ansi.zig` · `.csi` (~50) · low/PLAUSIBLE** — an unterminated/malformed CSI
  swallows bytes until a final byte (0x40–0x7e); an embedded ESC doesn't
  re-sync. **Fix:** in `.csi`, re-sync on ESC and optionally abort on C0
  controls.
- **`ansi.zig` · `.osc` (~60) · low/PLAUSIBLE** — an unterminated OSC swallows
  all output (incl. newlines) until BEL/ESC. **Fix:** bound the OSC/CSI drop
  states with a max-run length, flushing as literal text after N bytes.
- **`md.zig` · `scanInline` single-delimiter (~149) · low/CONFIRMED** — `*`/`_`
  italic pairs across arbitrary distance with no flanking rules, and the
  caller hides marker spans off the cursor line, so `run 5 * 6 * 7` and
  `my_var_name` visibly mangle in the live preview (buffer text is intact).
  **Fix:** apply CommonMark flanking rules (opener followed by non-ws, closer
  preceded by non-ws; reject intraword `_`).
- **`config.zig` · `resolvePath` (~239) · low/CONFIRMED** — when `$HOME` is
  unset, a `~/…` path is duped verbatim (literal tilde) and later used as a
  real filesystem path. **Fix:** treat `path[2..]` as cwd-relative, or reject.

## IPC robustness (2) — both PLAUSIBLE, best-effort

- **`ipc.zig` · `onReadComplete` (~189) · low/PLAUSIBLE** — assumes one read
  yields the whole line; an `AF_UNIX` `SOCK_STREAM` short read could truncate
  a message split across delivery boundaries. (The real sender does one
  sub-100-byte `sendall`, so not reachable in practice. Note: the read is now
  async after `fc904e0`, but still single-shot.) **Fix:** accumulate until EOF,
  or adopt length/newline framing.
- **`ipc.zig` · `liveSiblingExists` / `sweepStaleSockets` (~316) · low/PLAUSIBLE**
  — judge a `roost-<pid>.sock` live by `kill(pid, 0)` alone, so a recycled PID
  yields a false "sibling" (wrong launch choice) or a never-reaped stale
  socket. **Fix:** verify identity with a non-blocking `connect()` —
  `ECONNREFUSED` ⇒ stale.

## Leaks / lifecycle (3)

- **`tree.zig` · `applyRatioOnAllocate` / `onMaxPositionRatio` (~1669) ·
  low/CONFIRMED** — heap-allocates an `f64` ratio slot per `GtkPaned` and
  connects a handler with **no destroy-notify**, so the slot leaks 8 bytes per
  split forever (the comment falsely claims the handler frees it). **Fix:** add
  a `destroyData` that frees the slot; fix the comment.
- **`app.zig` · `onWindowCloseRequest` (~722) · low/PLAUSIBLE** — quit/close
  only flips `actions_alive`; in-flight action child processes (own process
  group, piped stdio) get no signal and orphan to init, despite the dialog
  promising it "ends everything running in it." **Fix:** iterate `active_runs`
  and `stopRun(ar)` each `!ar.done` before returning.
- **`app.zig` · `stopRun` (~2149) · low/PLAUSIBLE** — `ar.pid` is never reset
  after `child.wait()` reaps the child, and `ar.done` is set later on the main
  thread, so a Stop click in that window could `kill(-pid)` a PID-recycled
  group (effectively unreachable interactively). **Fix:** `@atomicStore(i32,
  &ar.pid, 0, .release)` right after `wait()`.

## Build glue (3) — cosmetic / near-unreachable

- **`build.sh:31` · low/PLAUSIBLE** — `git apply` isn't self-idempotent;
  idempotency rests entirely on the silenced `git checkout -- build.zig` reset
  (`2>/dev/null || true`), which restores from the *index* and can mask the
  real cause with a misleading "patch does not apply". **Fix:** `git checkout
  HEAD -- build.zig`, or guard with `git apply --reverse --check`.
- **`build.sh:32` · low/PLAUSIBLE** — the build leaves the pinned Ghostty
  working tree permanently dirty (patched `build.zig` + two untracked
  symlinks) with no teardown; inherent to the additive design, but can block a
  pin bump or confuse clean-tree checks. **Fix:** an `EXIT` trap that reverts
  `build.zig` + removes the symlinks, or document the expected dirty set.
- **`config.zig` · `load` 64 KiB cap (~57) · low/PLAUSIBLE** — `readFileAlloc`
  caps the config at 64 KiB; exceeding it reverts to defaults (it does
  `log.warn`, and 64 KiB is unreachable for ~8 scalar settings). **Fix (opt):**
  raise the cap. No correctness fix required.
