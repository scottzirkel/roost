# Roost — code audit (2026-06-30)

Whole-codebase audit of `src/roost/` + `main_roost.zig` + the build overlay
(`build.sh`, `patches/build.zig.patch`), run against commit `13d8d4f`.
Methodology: 18 review units (the two big files — `app.zig`, `tree.zig` —
split by lens: memory-safety / concurrency / correctness / simplification;
one finder per smaller file; one for the build glue), each finding then
independently, adversarially verified. **46 candidates → 33 verified**
(23 CONFIRMED, 10 PLAUSIBLE), 8 refuted. The vendored Ghostty submodule was
out of scope. Two recurring themes: GTK widget-lifecycle / teardown
ordering, and error-path memory ownership.

## Outcome (33 verified findings) — 28 fixed, 5 won't-fix, 0 open (2026-06-30)
- **14 fixed (initial pass)** — `fc904e0` (2 HIGH + 4 MEDIUM + 3 durability + 3
  action-modal follow-ups) and `4603b5c` (2 simplifications).
- **14 fixed (follow-up pass, 2026-06-30 — 12 items)** — the rest of the
  actionable backlog, tracked in `TODO.md` → "▶ Audit follow-ups". Reachable:
  `md.zig` emphasis flanking (`d560775`), `ansi.zig` re-sync (`2f54a0a`),
  `tree.zig` ratio-slot leak (`5ff65e1`), `app.zig` orphan children (`8ba4084`).
  Edge/OOM-gated: `app.zig` agent-cmd UAF + stopRun pid (`28e76eb`), `config.zig`
  agent-literal free + `resolvePath` (`92b2d56`), `git.zig` `addWorktree`
  false-success (`657f8ab`), `proc.zig` `run` leak (`e03ac1a`), `tree.zig`
  `buildFromSer` floating-widget leak (`71797e0`), `tree.zig`
  `splitFocused`/`splitGroup` detach-UAF + leak (`cc94aa4`).
- **5 decided NOT to fix** — recorded below so a future audit doesn't
  re-raise them.

## Decided: won't fix
Each is correct-by-intent, already fail-safe, or has a benign / near-
unreachable failure whose fix costs more than it's worth.

- **`ipc.zig` single-read framing (`onReadComplete`)** — assumes one read =
  one whole line; an `AF_UNIX SOCK_STREAM` short read could split a message
  across delivery boundaries. **Won't fix:** the only sender
  (`scripts/roost-notify`) does a single `sendall` of a sub-100-byte line
  into a local stream socket (delivered atomically), and the parser keys on
  the first ≤11-byte token — accumulation/length-framing is over-engineering
  for one local writer.
- **`ipc.zig` PID-as-identity (`liveSiblingExists` / `sweepStaleSockets`)** —
  treats any live PID matching a `roost-<pid>.sock` as proof of a live roost,
  without verifying the process actually is roost. **Won't fix:** documented
  best-effort; triggering needs an exact PID-recycle collision, and the worst
  case is benign — a fresh desktop launch opens the chooser instead of the
  last project, or one stale socket file lingers. No state corruption. (A
  non-blocking `connect()` identity probe would harden it if this ever
  matters.)
- **`config.zig` 64 KiB read cap (`load`)** — a config larger than 64 KiB
  returns `error.FileTooBig`, which is logged and reverts to defaults.
  **Won't fix:** unreachable for ~8 scalar settings, it already `log.warn`s
  (not silent), and defaults-on-unreadable is the documented contract.
- **`build.sh:31` `git apply` idempotency** — `git apply` isn't
  self-idempotent; idempotency rests on the silenced `git checkout --
  build.zig` reset (`2>/dev/null || true`). **Won't fix:** `set -euo
  pipefail` makes it fail safe (loud abort, never corruption); the
  reset-then-apply works in practice, and the only failure mode is a
  misleading "patch does not apply" message under manual submodule
  corruption.
- **`build.sh:32` dirty vendored tree** — each build leaves `vendor/ghostty`
  with a patched `build.zig` + two untracked symlinks, never reverted.
  **Won't fix:** this is inherent to the additive-overlay design — the
  symlinks + the one-line `build.zig` patch ARE the build step. The committed
  submodule **PIN** (the real zero-diff invariant) stays clean, and the
  script self-heals (resets `build.zig` before re-patching). A teardown trap
  would risk fighting the symlink-based live-edit workflow.
