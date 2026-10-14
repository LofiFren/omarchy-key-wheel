#!/bin/bash
# Install this checkout as a plugin, for testing from a shared folder.
#
#   bash ~/OM_Shared/omarchy-key-wheel/dev-install.sh
#
# Copies rather than symlinks: Omarchy refuses symlinks in a plugin folder.
# Run it again after every change to pick up the new files.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
id="lofifren.key-wheel"
dest="$HOME/.config/omarchy/plugins/$id"

mkdir -p "$(dirname "$dest")"
rm -rf "$dest"
mkdir "$dest"
cp -R "$src"/. "$dest"/
rm -rf "$dest/.git"

chmod +x "$dest/bin/omarchy-menu-select"
omarchy plugin validate "$dest"

# A rescan doesn't reliably reload a changed overlay, so restart the shell
# (the bar blinks once) and wait for it to answer before enabling.
omarchy restart shell >/dev/null 2>&1 || omarchy-restart-shell >/dev/null 2>&1 || true
for _ in $(seq 1 50); do
  omarchy-shell shell ping >/dev/null 2>&1 && break
  sleep 0.2
done
omarchy plugin enable "$id" || true

# Bind Super + R, replacing any binding an earlier version added.
bash "$dest/bind.sh" "${1:-SUPER + R}"
