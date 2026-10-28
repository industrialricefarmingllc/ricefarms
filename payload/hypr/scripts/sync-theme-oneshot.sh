#!/bin/bash
set -e
THEME_FILE="$HOME/.cache/quickshell/theme_mode"
WALL_FILE="$HOME/.cache/current_wallpaper"
MODE=$(cat "$THEME_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
[[ "$MODE" != "light" && "$MODE" != "dark" ]] && MODE="dark"
WALL=$(cat "$WALL_FILE" 2>/dev/null | tr -d '\n' | xargs || true)
[ -z "$WALL" ] && WALL=$(cat "$HOME/.cache/hypr_last_wallpaper" 2>/dev/null | tr -d '\n' | xargs || true)
if [[ -n "$WALL" && -f "$WALL" ]]; then
  exec "$HOME/.config/hypr/scripts/wallpaper-matugen.sh" "$WALL" "$MODE"
else
  matugen color hex "#89b4fa" -m "$MODE" 2>&1 | tail -n 20
  "$HOME/.config/lucid/app-surface-sync.sh" >/dev/null 2>&1 || true
  "$HOME/.config/lucid/opencode-theme-notify.sh" >/dev/null 2>&1 || true
  ( setsid "$HOME/.config/lucid/theme-fanout.sh" --request >/dev/null 2>&1 < /dev/null & ) 2>/dev/null || true
fi
