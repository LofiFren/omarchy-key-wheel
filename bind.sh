#!/bin/bash
# Give Key Wheel a shortcut. Run once after installing the plugin:
#
#   bash ~/.config/omarchy/plugins/lofifren.key-wheel/bind.sh            # Super + R
#   bash ~/.config/omarchy/plugins/lofifren.key-wheel/bind.sh "SUPER + I" # or another
#
# Adds one line to ~/.config/hypr/bindings.lua (replacing any line this
# script added before) and reloads Hyprland. Refuses a combo that's already
# bound to something else. To remove it, delete the lines that mention
# lofifren.key-wheel from that file.
set -euo pipefail

id="lofifren.key-wheel"
combo="${1:-SUPER + R}"
combo="$(tr '[:lower:]' '[:upper:]' <<<"$combo" | sed -E 's/[[:space:]]*\+[[:space:]]*/ + /g')"
bindings="$HOME/.config/hypr/bindings.lua"

# Is the combo taken by something other than us?
mods="${combo% + *}"
key="${combo##* + }"
taken="$(omarchy menu keybindings --print 2>/dev/null |
  awk -v m="$mods" -v k="$key" '
    { split($0, side, "→"); left = side[1]; gsub(/^[ \t]+|[ \t]+$/, "", left)
      n = split(left, parts, " \\+ "); if (n < 2) next
      if (parts[n] == k && parts[1] == m) { sub(/^[ \t]+/, "", side[2]); print side[2]; exit } }')"
if [[ -n $taken && $taken != "Key wheel" ]]; then
  echo "$combo is already bound to: $taken"
  echo "Pick another, for example:"
  echo "  bash $0 \"SUPER + I\""
  exit 1
fi

mkdir -p "$(dirname "$bindings")"
touch "$bindings"
sed -i "/$id/d" "$bindings"
printf -- '-- Key wheel (%s)\no.bind("%s", "Key wheel", "omarchy-shell shell toggle %s \x27{}\x27") -- %s\n' \
  "$id" "$combo" "$id" "$id" >> "$bindings"
hyprctl reload >/dev/null 2>&1 || true

echo "Key Wheel is on $combo."
