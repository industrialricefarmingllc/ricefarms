#!/bin/bash
# watch-theme-mode.sh - poll theme_mode and regenerate matugen/kitty when it changes
# runs as hyprland exec-once daemon (no inotify-tools required, uses stat)
set -u
THEME_FILE="$HOME/.cache/quickshell/theme_mode"
WALL_FILE="$HOME/.cache/current_wallpaper"
HYPR_MODE_FILE="$HOME/.cache/hypr_last_wallpaper_mode"
# ensure files exist for stat
mkdir -p "$(dirname "$THEME_FILE")" "$(dirname "$WALL_FILE")"
[ -f "$THEME_FILE" ] || echo "dark" > "$THEME_FILE"
LAST_MODE=$(cat "$THEME_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || echo dark)
LAST_WALL=$(cat "$WALL_FILE" 2>/dev/null | tr -d '\n' | xargs || true)
LAST_MTIME=$(stat -c %Y "$THEME_FILE" 2>/dev/null || echo 0)
LAST_WALL_MTIME=$(stat -c %Y "$WALL_FILE" 2>/dev/null || echo 0)
# also watch gsettings? we sync gsettings from theme_mode, not the other way
while true; do
  sleep 0.8
  # check theme_mode mtime or content change
  CUR_MTIME=$(stat -c %Y "$THEME_FILE" 2>/dev/null || echo 0)
  CUR_WALL_MTIME=$(stat -c %Y "$WALL_FILE" 2>/dev/null || echo 0)
  CUR_MODE=$(cat "$THEME_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || echo dark)
  [[ "$CUR_MODE" != "light" && "$CUR_MODE" != "dark" ]] && CUR_MODE="dark"
  CUR_WALL=$(cat "$WALL_FILE" 2>/dev/null | tr -d '\n' | xargs || true)
  # trigger if mode changed (mtime or content) - but not on first run
  if [[ "$CUR_MODE" != "$LAST_MODE" ]] || [[ "$CUR_MTIME" != "$LAST_MTIME" ]]; then
    # debounce: ensure file stable for 0.2s
    sleep 0.2
    CUR_MODE2=$(cat "$THEME_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || echo dark)
    [[ "$CUR_MODE2" != "light" && "$CUR_MODE2" != "dark" ]] && CUR_MODE2="dark"
    if [[ "$CUR_MODE2" != "$LAST_MODE" ]]; then
      # skip if toggle script just handled it (lock file <3s old)
      if [[ -f /tmp/matugen-theme-toggle.lock ]]; then
        LOCK_AGE=$(( $(date +%s) - $(stat -c %Y /tmp/matugen-theme-toggle.lock 2>/dev/null || echo 0) ))
        if [[ $LOCK_AGE -lt 3 ]]; then
          echo "[watch-theme-mode] mode → $CUR_MODE2 (already handled by toggle, skipping)" >&2
          LAST_MODE="$CUR_MODE2"
          LAST_MTIME="$CUR_MTIME"
          echo "$CUR_MODE2" > "$HYPR_MODE_FILE" 2>/dev/null || true
          continue
        fi
      fi
      LAST_MODE="$CUR_MODE2"
      LAST_MTIME="$CUR_MTIME"
      echo "[watch-theme-mode] mode → $CUR_MODE2, regenerating" >&2
      if [[ -n "$CUR_WALL" && -f "$CUR_WALL" ]]; then
        # use wallpaper-matugen.sh so awww + matugen + kitty reload happen atomically
        "$HOME/.config/hypr/scripts/wallpaper-matugen.sh" "$CUR_WALL" "$CUR_MODE2" 2>&1 | tail -n 20 >&2 || matugen image "$CUR_WALL" -m "$CUR_MODE2" 2>&1 | tail -n 20 >&2 || true
      else
        # no wallpaper: generate from fallback color so kitty still switches
        matugen color hex "#89b4fa" -m "$CUR_MODE2" 2>&1 | tail -n 20 >&2 || true
        pkill -SIGUSR1 kitty 2>/dev/null || true
        hyprctl reload 2>/dev/null || true
      fi
      # keep hypr mode file in sync
      echo "$CUR_MODE2" > "$HYPR_MODE_FILE" 2>/dev/null || true
    fi
    LAST_MTIME="$CUR_MTIME"
  fi
  # also detect wallpaper change that wasn't via matugen (e.g., direct write to current_wallpaper)
  # wallpaper-matugen.sh already handles this, so we only update LAST_WALL tracking
  if [[ "$CUR_WALL" != "$LAST_WALL" ]] || [[ "$CUR_WALL_MTIME" != "$LAST_WALL_MTIME" ]]; then
    LAST_WALL="$CUR_WALL"
    LAST_WALL_MTIME="$CUR_WALL_MTIME"
  fi
done
