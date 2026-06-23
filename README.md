# Roost

A GTK4 **agent command center** for Omarchy / Hyprland — a focused, Linux-native
take on [supacode](https://github.com/supabitapp/supacode). One window holds a
role-typed, splittable workspace of real terminal panes — **agent** (Claude
Code), **git** (lazygit), **shell** — plus a wired **scratchpad**, with
per-project layouts, a one-keystroke worktree command center, and agent-aware
desktop notifications.

Roost is built on real [Ghostty](https://github.com/ghostty-org/ghostty)
`Surface` widgets via an **additive soft-fork**: it *adds* files to the Ghostty
tree and never edits Ghostty's own source. Ghostty is a pinned submodule; our
code overlays on top at build time.

> App id `dev.scottzirkel.Roost`. Status: core complete (panes, layouts,
> worktree create/switch, IPC notifications). Early and evolving.

## Build

Requires **Zig 0.15.2** and GTK4 / libadwaita (matching Ghostty's deps).

```sh
git clone --recurse-submodules https://github.com/scottzirkel/roost
cd roost
# One-time on Arch + Zig 0.15.2: work around the SFrame relocation (Zig #31272)
scripts/patch-zig-linker.sh
./build.sh                       # overlays our source + builds -> vendor/ghostty/zig-out/bin/roost
```

Run from a git repo (`cd <repo> && .../zig-out/bin/roost`) or point it at one
with `ROOST_PROJECT=<repo>`. A desktop launcher lives at `scripts/roost.desktop`.

## How the overlay works

Our code relative-imports Ghostty internals, so it must live *inside* the
Ghostty source tree to compile. `build.sh`:

1. checks out the pinned Ghostty submodule (vanilla upstream tag),
2. symlinks `src/roost/` + `src/main_roost.zig` into `vendor/ghostty/src/`,
3. applies `patches/build.zig.patch` (the one additive change — it registers the
   `roost` executable), and
4. runs `zig build roost`.

Because the fork is purely additive, the diff against upstream Ghostty is just
our own files plus that one build step.

## Layout

```
src/roost/            the workspace: panes, tree, layout, git, IPC, scratchpad
src/main_roost.zig    thin entry point
patches/              additive build.zig step
scripts/              roost-notify (agent hooks), roost.desktop, toolchain patch
vendor/ghostty/       Ghostty submodule (pinned, vanilla upstream)
build.sh              overlay + build
```

## Agent notifications

The Agent pane exports `ROOST_SOCK`; wiring `scripts/roost-notify` into Claude
Code's `Stop` / `Notification` hooks raises native notifications + a pane status
badge when the agent finishes or needs you. See `scripts/README.md`.

## License

Roost's own code: MIT. Ghostty is a separate upstream project (MIT) consumed as
a submodule.
