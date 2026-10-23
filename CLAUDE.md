# Roost: notes for coding agents

Roost is a GTK4 "agent command center" built as an overlay on Ghostty. Read what
the task needs:

- [README.md](README.md): what Roost is and how people use it.
- [docs/architecture.md](docs/architecture.md): how it's built, and why.
- [docs/development.md](docs/development.md): build, test, debug, gotchas.
- [ROADMAP.md](ROADMAP.md): what's next, known issues, and what's not planned.

## Rules

- Never edit `vendor/ghostty`. `git -C vendor/ghostty diff --name-only v1.3.1`
  must print only `build.zig`.
- Nothing in `src/roost/core/` may import a UI toolkit or Ghostty.
  `scripts/check-core.sh` enforces this on every build.
- Never stop Roost by name (`pkill`, `killall`). Other windows may hold someone's
  live work, and you may be running inside one. Stop only processes you started,
  by PID.
- Test running behavior in an isolated instance, never in live windows. See
  [Isolated test instances](docs/development.md#isolated-test-instances).
- Build with `./build.sh`. Use `-p <dir>` for a scratch build that leaves the
  installed binary alone.
- Keep the docs current as you work. Update `ROADMAP.md` when you finish or add
  planned work, and `docs/` when a design or gotcha changes. History goes in
  commit messages, not in docs.
