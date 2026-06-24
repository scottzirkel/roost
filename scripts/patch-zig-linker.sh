#!/usr/bin/env bash
# patch-zig-linker.sh — workaround for Zig issue #31272.
#
# Arch's glibc (update 2026-04-22) ships crt1.o with an .sframe section using
# R_X86_64_PC64 relocations. Zig 0.15.2's self-hosted ELF linker can't handle
# that relocation, and forcing -flld alone (self-hosted backend + LLD) CRASHES
# the compiler ("terminated unexpectedly"). The stable combo is LLVM backend + LLD.
#
# This patches our PROJECT-LOCAL Zig's std.Build so every Compile step defaults
# to use_llvm=true and use_lld=true. vendor/ghostty stays at a ZERO git diff, so
# the Phase-1 patch-ugliness gate stays an honest measure of OUR coupling, not
# polluted by a toolchain workaround.
#
# Idempotent. Re-run after reinstalling/upgrading Zig. Requires `zig` on PATH.
set -euo pipefail
ZIG_REAL=$(readlink -f "$(command -v zig)")
FILE="$(dirname "$ZIG_REAL")/lib/std/Build/Step/Compile.zig"
[ -f "$FILE" ] || { echo "error: $FILE not found" >&2; exit 1; }

if ! grep -q "roost: force LLVM" "$FILE"; then
  sed -i 's|\.use_llvm = options\.use_llvm,|.use_llvm = options.use_llvm orelse true, // roost: force LLVM (Zig #31272)|' "$FILE"
fi
if ! grep -q "roost: force LLD" "$FILE"; then
  sed -i 's|\.use_lld = options\.use_lld,|.use_lld = options.use_lld orelse true, // roost: force LLD (Zig #31272 SFrame workaround)|' "$FILE"
fi
echo "patched: $FILE"
grep -n "roost: force" "$FILE"
