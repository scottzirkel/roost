#!/usr/bin/env bash
#
# install-omarchy-widget.sh: put Roost's widget on the Omarchy bar.
#
# Copies integrations/omarchy into the Omarchy shell's plugin folder, checks
# it, and enables it. Run it again after pulling to update the widget; the
# shell reloads changed plugin files on its own. Placement options pass
# through to `omarchy plugin enable` on the first install, for example:
#
#   scripts/install-omarchy-widget.sh --before omarchy.agents
#
# It copies rather than links: Omarchy refuses symlinks in a plugin folder.
# The widget runs `roost status --all --watch`, so `roost` must be on the
# PATH (scripts/roost-launch, linked as ~/.local/bin/roost).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="dev.scottzirkel.roost"
src="$root/integrations/omarchy"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$id"

command -v omarchy >/dev/null || { echo "install-omarchy-widget: Omarchy isn't installed" >&2; exit 1; }
command -v roost >/dev/null || echo "install-omarchy-widget: warning: 'roost' isn't on your PATH, so the widget will stay hidden" >&2

omarchy plugin validate "$src"
mkdir -p "$dest"
cp -f "$src/manifest.json" "$src/BarWidget.qml" "$dest/"
echo "copied the widget to $dest"

enabled() {
  omarchy plugin list --json | jq -e --arg id "$id" 'any(.[]; .id == $id and .enabled)' >/dev/null
}
known() {
  omarchy plugin list --json | jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null
}

if enabled; then
  echo "already on the bar; the shell reloads the new files itself"
  exit 0
fi

# A brand-new plugin folder: have the shell look for it, then wait until it has.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
for _ in $(seq 1 50); do
  known && break
  sleep 0.1
done
omarchy plugin enable "$id" "$@"
echo "added Roost to the bar"
