#!/bin/bash
# wallpaper-restore.sh - Restore last wallpaper on Hyprland launch (Dolphin + matugen compatible)
# Called via exec-once in hyprland.conf/hyprland.lua
set -eu

# Wait for awww-daemon to be ready (started via exec-once before this)
for i in 1 2 3 4 5; do
  pgrep -x awww-daemon >/dev/null 2>&1 && break
  sleep 0.3
done

# Find last wallpaper - unified state: .cache/current_wallpaper (lucid) + hypr_last + wallpaper.json
# Pick newest valid file to avoid reverting to stale hypr_last when lucid recently changed wallpaper via Dock.
WALL=""
MODE="dark"
if [ -f "$HOME/.cache/quickshell/theme_mode" ]; then
  MODE=$(cat "$HOME/.cache/quickshell/theme_mode" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  [ "$MODE" != "light" ] && MODE="dark"
fi

# Collect candidates with mtime for newest-pick
candidates=()
add_candidate() { [ -f "$1" ] && candidates+=("$1"); }

# Lucid primary source (Dock + Lock both watch this)
if [ -f "$HOME/.cache/current_wallpaper" ]; then
  c=$(cat "$HOME/.cache/current_wallpaper" 2>/dev/null | tr -d '\n' | xargs)
  [ -n "$c" ] && [ -f "$c" ] && candidates+=("$c")
fi
# Lucid dock json
if [ -f "$HOME/.config/quickshell/luciddocks/wallpaper.json" ]; then
  c=$(jq -r '.current // empty' "$HOME/.config/quickshell/luciddocks/wallpaper.json" 2>/dev/null | tr -d '\n' | xargs)
  [ -z "$c" ] && c=$(grep -oP '"current"\s*:\s*"\K[^"]+' "$HOME/.config/quickshell/luciddocks/wallpaper.json" 2>/dev/null | head -n1)
  [ -n "$c" ] && [ -f "$c" ] && candidates+=("$c")
fi
# Legacy hypr sources
if [ -f "$HOME/.cache/hypr_last_wallpaper" ]; then
  c=$(cat "$HOME/.cache/hypr_last_wallpaper" 2>/dev/null | tr -d '\n' | xargs)
  [ -n "$c" ] && [ -f "$c" ] && candidates+=("$c")
fi
if [ -f "$HOME/.config/hypr/current_wallpaper" ]; then
  c=$(cat "$HOME/.config/hypr/current_wallpaper" 2>/dev/null | tr -d '\n' | xargs)
  [ -n "$c" ] && [ -f "$c" ] && candidates+=("$c")
fi

# If we have candidates, prefer the newest file's path (via stat mtime of the state files, not the image)
# Simpler: if .cache/current_wallpaper exists and is newer than hypr_last, use it; else use first valid candidate.
WALL=""
if [ ${#candidates[@]} -gt 0 ]; then
  # Prefer .cache/current_wallpaper if it exists and is valid (lucid source of truth)
  if [ -f "$HOME/.cache/current_wallpaper" ]; then
    c=$(cat "$HOME/.cache/current_wallpaper" 2>/dev/null | tr -d '\n' | xargs)
    if [ -n "$c" ] && [ -f "$c" ]; then
      WALL="$c"
    fi
  fi
  # Fallback to most-recent state file mtime if WALL still empty or stale
  if [ -z "$WALL" ]; then
    newest="" ; newest_mtime=0
    for f in "$HOME/.cache/current_wallpaper" "$HOME/.config/quickshell/luciddocks/wallpaper.json" "$HOME/.cache/hypr_last_wallpaper" "$HOME/.config/hypr/current_wallpaper"; do
      [ -f "$f" ] || continue
      mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
      [ "$mt" -gt "$newest_mtime" ] 2>/dev/null || continue
      # extract path from that file
      if [[ "$f" == *wallpaper.json ]]; then
        cand=$(jq -r '.current // empty' "$f" 2>/dev/null | tr -d '\n' | xargs)
        [ -z "$cand" ] && cand=$(grep -oP '"current"\s*:\s*"\K[^"]+' "$f" 2>/dev/null | head -n1)
      else
        cand=$(cat "$f" 2>/dev/null | tr -d '\n' | xargs)
      fi
      if [ -n "$cand" ] && [ -f "$cand" ]; then
        newest="$cand"; newest_mtime="$mt"
      fi
    done
    [ -n "$newest" ] && WALL="$newest"
  fi
  # Final fallback to first candidate if still empty
  [ -z "$WALL" ] && WALL="${candidates[0]}"
fi
# Fallback to defaults based on MODE
if [ -z "$WALL" ] || [ ! -f "$WALL" ]; then
  if [ "$MODE" = "light" ]; then
    WALL="$HOME/.config/hypr/wallpapers/default-light.jpg"
  else
    WALL="$HOME/.config/hypr/wallpapers/default-dark.jpg"
  fi
fi
# Final fallback to any wallpaper in Pictures/Wallpapers
if [ ! -f "$WALL" ] && [ -d "$HOME/Pictures/Wallpapers" ]; then
  WALL=$(find "$HOME/Pictures/Wallpapers" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.webp" \) 2>/dev/null | head -n1 || true)
fi
[ -z "$WALL" ] || [ ! -f "$WALL" ] && { echo "No wallpaper found, skipping restore" >&2; exit 0; }

echo "Restoring wallpaper: $WALL (auto → smart)"

# Ensure HYPRLAND_INSTANCE_SIGNATURE is set for hyprctl (if called via exec-once, it should be, but fallback)
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  SIG=$(hyprctl instances 2>/dev/null | grep -oP 'instance \K[^:]+' | tail -n1 || true)
  if [ -n "$SIG" ]; then
    export HYPRLAND_INSTANCE_SIGNATURE="$SIG"
  else
    SIG=$(ls -t /run/user/$(id -u)/hypr 2>/dev/null | head -n1 || true)
    [ -n "$SIG" ] && export HYPRLAND_INSTANCE_SIGNATURE="$SIG" || true
  fi
fi
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Use unified matugen path (handles awww + hypr borders + quickshell accent)
# Auto-detect light/dark from wallpaper via --mode smart (kitty watcher stays in sync)
if [ -x "$HOME/.config/hypr/scripts/wallpaper-matugen.sh" ]; then
  exec "$HOME/.config/hypr/scripts/wallpaper-matugen.sh" "$WALL"
else
  # Fallback direct
  awww img "$WALL" --transition-type wipe --transition-duration 1.2 2>/dev/null || awww img "$WALL" 2>/dev/null || true
  if command -v matugen >/dev/null 2>&1; then
    matugen image "$WALL" -m "$MODE" 2>&1 | tail -n 5
  fi
fi
