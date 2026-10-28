#!/bin/bash
# wallpaper-matugen.sh - legacy entry point.
#
# This used to duplicate set-wallpaper.sh (awww, state files, matugen, kitty
# boosts, apply-gtk-mode, hyprctl reload). It is now a thin delegate so every
# caller shares the same scheme cache, single matugen render, kitty tune pass
# and coalesced theme-fanout delivery.
set -e
WALL="${1:-$HOME/Pictures/Wallpapers/wallhaven-og13vm.png}"
[ -f "$WALL" ] || { echo "not found: $WALL" >&2; exit 1; }
exec "$HOME/.config/hypr/scripts/wallpaper/set-wallpaper.sh" "$WALL" "${2:-}"
