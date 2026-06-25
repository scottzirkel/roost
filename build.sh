#!/usr/bin/env bash
#
# Roost build — overlay our additive source onto a pinned, vanilla Ghostty
# checkout, then build the `roost` target.
#
# Roost is an *additive* soft-fork of Ghostty: it adds files, it never edits
# Ghostty's own source. So the "overlay" is just our source symlinked into the
# Ghostty tree (relative imports need it there) plus ONE additive build.zig
# patch that registers the `roost` executable. The Ghostty submodule stays
# pinned at a vanilla upstream tag (see .gitmodules / vendor/ghostty).
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sub="$root/vendor/ghostty"
ZIG="${ZIG:-$(command -v zig || echo "$HOME/.local/bin/zig")}"

# 1. Ensure the Ghostty submodule is present at its pinned commit.
if [ ! -e "$sub/build.zig" ]; then
  echo "==> initializing Ghostty submodule"
  git -C "$root" submodule update --init vendor/ghostty
fi

# 2. Overlay our additive source into the Ghostty tree (symlinks = live edits:
#    edit src/roost/* here, rebuild, done — no copy step).
rm -rf "$sub/src/roost" "$sub/src/main_roost.zig"
ln -sfn ../../../src/roost          "$sub/src/roost"
ln -sfn ../../../src/main_roost.zig "$sub/src/main_roost.zig"

# 3. Apply the additive build.zig step (idempotent: reset to pristine, re-patch).
git -C "$sub" checkout -- build.zig 2>/dev/null || true
git -C "$sub" apply "$root/patches/build.zig.patch"

# 3.5 Compile our bundled header-bar icons into a GResource the binary
#     @embedFiles (src/roost/icons.gresource is gitignored — it's generated).
echo "==> compiling bundled icons"
glib-compile-resources \
  --sourcedir="$root/src/roost/icons" \
  --target="$root/src/roost/icons.gresource" \
  "$root/src/roost/icons/roost-icons.gresource.xml"

# 4. Build. Extra args pass through (e.g. ./build.sh -Doptimize=ReleaseFast).
echo "==> $ZIG build roost"
( cd "$sub" && "$ZIG" build roost "$@" )
echo "==> built: $sub/zig-out/bin/roost"
