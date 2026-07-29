#!/usr/bin/env bash
#
# Core purity gate — nothing under src/roost/core/ may depend on a UI toolkit.
#
# WHY: Roost's shell is GTK4, and GTK4 has no supported path on macOS (Ghostty
# itself builds its Mac app in Xcode against libghostty, not GTK). A native Mac
# Roost therefore needs a second shell — but it must not need a second *brain*.
# `src/roost/core/` is the portable half: pure std Zig, no toolkit, no Ghostty
# internals, so it can be compiled into a static lib behind a C ABI and driven
# from Swift exactly the way Ghostty drives libghostty.
#
# This gate is what keeps that true. It is the same idea as the additive
# Ghostty gate (`git -C vendor/ghostty diff --name-only v1.3.1` = only
# build.zig): a cheap mechanical check that catches the drift a code review
# would miss, run on every build so it can never rot.
#
# Exits non-zero listing every offending file:line.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core="$root/src/roost/core"

[ -d "$core" ] || { echo "check-core: no $core — nothing to check"; exit 0; }

# Toolkit imports: @import("gtk"), "adw", "gdk", "gio", "glib", "gobject".
toolkit='@import\("(gtk|adw|gdk|gio|glib|gobject)"\)'

# Ghostty internals: any relative import that climbs out of core/ into the
# surrounding Ghostty source tree. Sibling imports (./foo.zig) are fine, and so
# is "../<file>.zig" for another core module -- but core/ sits at src/roost/core,
# so reaching Ghostty needs at least two levels up.
ghostty='@import\("\.\./\.\./'

fail=0

if hits=$(grep -rEn "$toolkit" "$core" --include='*.zig' 2>/dev/null); then
  echo "check-core: FAIL — toolkit import inside src/roost/core/"
  echo "  core/ must stay portable (a macOS shell can't have GTK):"
  echo "$hits" | sed "s|$root/|    |"
  fail=1
fi

if hits=$(grep -rEn "$ghostty" "$core" --include='*.zig' 2>/dev/null); then
  echo "check-core: FAIL — Ghostty internal import inside src/roost/core/"
  echo "  core/ must not reach into the Ghostty tree:"
  echo "$hits" | sed "s|$root/|    |"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "  Move the toolkit-facing part into src/roost/ (the GTK shell) and keep"
  echo "  the decision logic in core/, talking in plain data."
  exit 1
fi

n=$(find "$core" -name '*.zig' | wc -l)
echo "==> core purity gate OK ($n file(s) in src/roost/core/, no toolkit deps)"
