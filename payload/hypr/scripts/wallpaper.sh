#!/bin/bash

set -u

THEME_SCRIPT="$HOME/.config/quickshell/utils/theme-mode.sh"
STATE_FILE="$HOME/.cache/quickshell/theme_mode"
# Optional per-monitor override. Set both to give one display a wallpaper of its
# own; leave either empty and every display gets the theme wallpaper.
# MONITOR_MATCH is matched against the description in `hyprctl monitors -j`.
MONITOR_MATCH="${MONITOR_MATCH:-}"
MONITOR_WALLPAPER="${MONITOR_WALLPAPER:-}"

command -v awww >/dev/null 2>&1 || exit 0

TRANSITION=()
if [[ "${1:-}" == "--transition" ]]; then
  TRANSITION=(--transition-type wipe --transition-pos center --transition-step 90 --transition-duration 1.2)
fi

# WALLPAPER_DARK / WALLPAPER_LIGHT - handle missing theme script (lucid migration removed utils/)
if [ -f "$THEME_SCRIPT" ]; then
  eval "$(grep -E '^WALLPAPER_(DARK|LIGHT)=' "$THEME_SCRIPT" 2>/dev/null || true)"
fi
# Fallback to hypr wallpapers if theme script missing or vars empty
: "${WALLPAPER_DARK:=$HOME/.config/hypr/wallpapers/default-dark.jpg}"
: "${WALLPAPER_LIGHT:=$HOME/.config/hypr/wallpapers/default-light.jpg}"
# Also allow override via .cache/current_wallpaper (lucid source of truth)
if [ -f "$HOME/.cache/current_wallpaper" ]; then
  _cur=$(cat "$HOME/.cache/current_wallpaper" 2>/dev/null | tr -d '\n' | xargs)
  [ -n "$_cur" ] && [ -f "$_cur" ] && WALLPAPER_DARK="$_cur" && WALLPAPER_LIGHT="$_cur"
fi

mode="$(cat "$STATE_FILE" 2>/dev/null || echo dark)"
if [[ "$mode" == "light" ]]; then
  theme_wallpaper="$WALLPAPER_LIGHT"
else
  theme_wallpaper="$WALLPAPER_DARK"
fi
# Ensure unbound doesn't fail under set -u
: "${theme_wallpaper:=}"

if ! monitors="$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | "\(.name) \(.description)"')" \
   || [[ -z "$monitors" ]]; then
  [[ -f "$theme_wallpaper" ]] && awww img "$theme_wallpaper" ${TRANSITION[@]+"${TRANSITION[@]}"}
  exit 0
fi

# Only enabled outputs show up here
while read -r name desc; do
  if [[ -n "$MONITOR_MATCH" && -n "$MONITOR_WALLPAPER" && "$desc" == *"$MONITOR_MATCH"* ]]; then
    wallpaper="$MONITOR_WALLPAPER"
  else
    wallpaper="$theme_wallpaper"
  fi
  [[ -f "$wallpaper" ]] && awww img -o "$name" "$wallpaper" ${TRANSITION[@]+"${TRANSITION[@]}"}
done <<< "$monitors"
