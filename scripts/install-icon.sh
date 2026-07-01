#!/usr/bin/env bash
# Install the Roost app icon (dev.scottzirkel.Roost) into the user's hicolor
# icon theme so the launcher, taskbar, Alt-Tab, and notification fallback render
# the Roost logo instead of a generic icon.
#
# The canonical SVG is the square variant of the official Roost logo (full color,
# same art as docs/logo-square.svg). Edit that SVG and re-run to update.
#
# Idempotent; re-run after editing the SVG. Needs rsvg-convert.
set -euo pipefail

APP_ID="dev.scottzirkel.Roost"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SVG="$SCRIPT_DIR/../src/roost/icons/scalable/apps/$APP_ID.svg"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
SIZES=(16 24 32 48 64 128 256 512)

command -v rsvg-convert >/dev/null 2>&1 || { echo "error: rsvg-convert not found (install librsvg)"; exit 1; }
[ -f "$SRC_SVG" ] || { echo "error: source SVG missing: $SRC_SVG"; exit 1; }

for s in "${SIZES[@]}"; do
  dir="$DEST/${s}x${s}/apps"
  mkdir -p "$dir"
  rsvg-convert -w "$s" -h "$s" "$SRC_SVG" -o "$dir/$APP_ID.png"
  echo "  ${s}x${s}/apps/$APP_ID.png"
done

mkdir -p "$DEST/scalable/apps"
cp "$SRC_SVG" "$DEST/scalable/apps/$APP_ID.svg"
echo "  scalable/apps/$APP_ID.svg"

# Refresh the per-dir cache only if this hicolor root is itself a theme (has an
# index.theme). It usually isn't — the user dir just contributes icons to the
# system "hicolor" theme — and direct directory lookup finds the icons either way.
if [ -f "$DEST/index.theme" ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$DEST" >/dev/null 2>&1 && echo "icon cache updated" || true
fi

echo "installed $APP_ID into $DEST"
