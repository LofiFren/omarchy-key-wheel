#!/bin/bash
# Collect what's needed to debug the plugin into the shared folder:
#
#   bash ~/OM_Shared/omarchy-key-wheel/dev-logs.sh
#
# Writes ~/OM_Shared/key-wheel-logs.txt. Nothing here changes any settings.
out="$HOME/OM_Shared/key-wheel-logs.txt"
id="lofifren.key-wheel"
shell_path="${OMARCHY_PATH:-$HOME/.local/share/omarchy}/shell"

{
  echo "== $(date)"
  echo "== toggle"
  omarchy-shell shell toggle "$id" '{}' 2>&1
  sleep 1
  omarchy-shell shell hide "$id" 2>&1
  echo "== listPlugins"
  omarchy-shell shell listPlugins 2>&1 | grep -A12 "$id"
  echo "== binding"
  grep -n "$id" "$HOME/.config/hypr/bindings.lua" 2>&1
  echo "== hyprctl binds (R)"
  hyprctl binds 2>&1 | grep -B3 -A6 "key-wheel" | head -40
  echo "== quickshell log"
  for cmd in "qs log -p $shell_path" "quickshell log -p $shell_path" "qs log"; do
    echo "-- $cmd"
    timeout 5 $cmd 2>&1 | grep -iE "key-wheel|KeyWheel|Wheel.js|error|warn" | tail -80 && break
  done
  echo "== journal"
  journalctl --user -n 400 --no-pager 2>&1 | grep -iE "key-wheel|KeyWheel|Wheel.js|qml" | tail -60
} > "$out" 2>&1

echo "Wrote $out"
