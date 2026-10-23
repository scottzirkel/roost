#!/usr/bin/env bash
#
# Roost's checks that need no GTK and no Ghostty checkout: the core purity
# check, then the unit tests of every std-only file. CI runs exactly this
# (.github/workflows/ci.yml), so a change that passes here passes there.
#
# Everything in src/roost/core/ is std-only by rule, so all of it is tested
# without listing it: a new core file can't be forgotten. The few std-only
# files outside core/ are listed below.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="${ZIG:-$(command -v zig || echo "$HOME/.local/bin/zig")}"

"$root/scripts/check-core.sh"

files=("$root"/src/roost/core/*.zig)
files+=("$root/src/roost/actions.zig" "$root/src/roost/md.zig" "$root/src/roost/ansi.zig")

for f in "${files[@]}"; do
  echo "==> zig test ${f#"$root/"}"
  "$ZIG" test "$f"
done
