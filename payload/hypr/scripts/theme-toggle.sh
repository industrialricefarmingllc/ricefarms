#!/bin/bash
# theme-toggle.sh - toggle dark/light and regenerate matugen (kitty, hypr, etc.)
set -euo pipefail
THEME_FILE="$HOME/.cache/quickshell/theme_mode"
HYPR_MODE_FILE="$HOME/.cache/hypr_last_wallpaper_mode"
WALL_FILE="$HOME/.cache/current_wallpaper"
# read current mode, default dark
CUR=$(cat "$THEME_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || echo dark)
[[ "$CUR" != "light" && "$CUR" != "dark" ]] && CUR="dark"
if [[ "$CUR" == "light" ]]; then NEW="dark"; else NEW="light"; fi
# lock for watch-theme-mode.sh to avoid double matugen (see watch script)
touch /tmp/matugen-theme-toggle.lock
# atomically update theme_mode (watchers use mv)
mkdir -p "$(dirname "$THEME_FILE")"
printf '%s' "$NEW" > "${THEME_FILE}.tmp" && mv -f "${THEME_FILE}.tmp" "$THEME_FILE"
printf '%s' "$NEW" > "$HYPR_MODE_FILE"
# lucid 1.20.1 reads its mode from ~/.cache/current_mode
printf '%s' "$NEW" > "$HOME/.cache/current_mode"
# keep gsettings in sync (for GTK apps & quickshell theme OS)
# NOTE: Everforest themes are not installed - use built-in Adwaita base.
# apply-gtk-mode.sh (via wallpaper-matugen.sh) layers pure-black on top in dark.
if command -v gsettings >/dev/null 2>&1; then
  if [[ "$NEW" == "light" ]]; then
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-light' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita' 2>/dev/null || true
  else
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita' 2>/dev/null || true
  fi
fi
# also update theme_osd for quickshell OSD
echo "$NEW" > "$HOME/.cache/quickshell/theme_osd" 2>/dev/null || true
WALL=$(cat "$WALL_FILE" 2>/dev/null | tr -d '\n' | xargs || true)
[ -z "$WALL" ] && WALL=$(cat "$HOME/.cache/hypr_last_wallpaper" 2>/dev/null | tr -d '\n' | xargs || true)
[ -z "$WALL" ] && WALL=$(cat "$HOME/.config/hypr/current_wallpaper" 2>/dev/null | tr -d '\n' | xargs || true)
if [[ -n "$WALL" && -f "$WALL" ]]; then
  echo "Toggling $CUR → $NEW, regenerating $WALL"
  # wallpaper-matugen.sh handles awww + matugen + hypr reload + kitty SIGUSR1 via post_hook
  exec "$HOME/.config/hypr/scripts/wallpaper-matugen.sh" "$WALL" "$NEW"
else
  echo "Toggling $CUR → $NEW (no wallpaper found, generating from fallback color)"
  if command -v matugen >/dev/null 2>&1; then
    matugen color hex "#89b4fa" -m "$NEW" 2>&1 | tail -n 20
    "$HOME/.config/lucid/app-surface-sync.sh" >/dev/null 2>&1 || true
    "$HOME/.config/lucid/opencode-theme-notify.sh" >/dev/null 2>&1 || true
    pkill -SIGUSR1 kitty 2>/dev/null || true
    hyprctl reload 2>/dev/null || true
  fi
  "$HOME/.config/hypr/scripts/apply-gtk-mode.sh" "$NEW" 2>&1 | tail -n 5 || true
  echo "Switched to $NEW (no wallpaper)"
fi
