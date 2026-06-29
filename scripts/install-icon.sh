#!/usr/bin/env bash
# Install the Roost app icon (dev.scottzirkel.Roost) into the user's hicolor
# icon theme so the launcher, taskbar, Alt-Tab, and notification fallback render
# the ghost-bird mark instead of a generic icon.
#
# The canonical SVG is monochrome and theme-NEUTRAL (a plain neutral light tone,
# no palette-specific color) so it reads on every Omarchy theme. To recolor it
# (e.g. to the active theme's accent), pass a hex color as $1 or $ROOST_ICON_FILL
# and re-run; the value is substituted for the SVG's default fill at render time.
#
# Idempotent; re-run after editing the SVG or to change the color. Needs rsvg-convert.
set -euo pipefail

APP_ID="dev.scottzirkel.Roost"
DEFAULT_FILL="#d0d0d0"          # must match the fill in the canonical SVG
FILL="${1:-${ROOST_ICON_FILL:-$DEFAULT_FILL}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SVG="$SCRIPT_DIR/../src/roost/icons/scalable/apps/$APP_ID.svg"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
SIZES=(16 24 32 48 64 128 256 512)

command -v rsvg-convert >/dev/null 2>&1 || { echo "error: rsvg-convert not found (install librsvg)"; exit 1; }
[ -f "$SRC_SVG" ] || { echo "error: source SVG missing: $SRC_SVG"; exit 1; }

# Render SVG (recolored if a non-default fill was requested). Install the SVG
# colorized too, so scalable consumers match the PNGs.
render_svg="$SRC_SVG"
tmp_svg=""
if [ "$FILL" != "$DEFAULT_FILL" ]; then
  tmp_svg="$(mktemp --suffix=.svg)"
  sed "s|$DEFAULT_FILL|$FILL|g" "$SRC_SVG" > "$tmp_svg"
  render_svg="$tmp_svg"
  trap 'rm -f "$tmp_svg"' EXIT
fi

for s in "${SIZES[@]}"; do
  dir="$DEST/${s}x${s}/apps"
  mkdir -p "$dir"
  rsvg-convert -w "$s" -h "$s" "$render_svg" -o "$dir/$APP_ID.png"
  echo "  ${s}x${s}/apps/$APP_ID.png"
done

mkdir -p "$DEST/scalable/apps"
cp "$render_svg" "$DEST/scalable/apps/$APP_ID.svg"
echo "  scalable/apps/$APP_ID.svg"

# Refresh the per-dir cache only if this hicolor root is itself a theme (has an
# index.theme). It usually isn't — the user dir just contributes icons to the
# system "hicolor" theme — and direct directory lookup finds the icons either way.
if [ -f "$DEST/index.theme" ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$DEST" >/dev/null 2>&1 && echo "icon cache updated" || true
fi

echo "installed $APP_ID ($FILL) into $DEST"
