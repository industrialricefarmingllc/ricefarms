#!/usr/bin/env bash
# set-mode.sh <dark|light|auto>
#
# flips the desktop between light and dark, then rebuilds the palette the same
# way the theme that is active builds it normally:
#   matugen / pywal — wallpaper-derived, so the generator is re-run in the new
#                     mode and every template it owns is rewritten with it
#   colour          — built from one colour, so apply-colour.sh builds it again
#                     in the new mode
#   anything else   — a static palette, so apply-theme.sh picks (or synthesises)
#                     the theme's light variant
#
# auto takes it from the wallpaper's sidecar when that pins a mode, otherwise
# from how bright the wallpaper is (wallpaper-mode.sh).
#
# the mode itself lives in ~/.cache/current_mode, beside current_theme, because
# the shell and these scripts both have to agree on it.

set -euo pipefail

MODE="${1:?usage: set-mode.sh <dark|light|auto>}"
CACHE_DIR="$HOME/.cache"
LUCID_DIR="$HOME/.config/lucid"

THEME="$(cat "$CACHE_DIR/current_theme" 2>/dev/null || echo matugen)"
# current_wallpaper is the still that stands in for a live wallpaper
SAMPLE="$(cat "$CACHE_DIR/current_wallpaper" 2>/dev/null || true)"
WALLPAPER="$SAMPLE"
# with a live wallpaper current_wallpaper is only its first frame. handing that
# back would set the frame as a still and stop the video, so the video goes back
LIVE="$(head -n1 "$CACHE_DIR/current_live_wallpaper" 2>/dev/null || true)"
if [[ "$LIVE" == skwd:* ]]; then
    # a Wallpaper Engine scene has no file of its own; hand the key back
    WALLPAPER="$LIVE"
elif [[ -n "$LIVE" && -f "$LIVE" ]]; then
    WALLPAPER="$LIVE"
fi

if [[ "$MODE" == "auto" ]]; then
    # Prefer the moving file's sidecar. A video has no readable still of its
    # own, so fall back to the frame current_wallpaper already points at.
    AUTO_IMAGE="$WALLPAPER"
    [[ "$LIVE" == skwd:* ]] && AUTO_IMAGE="$SAMPLE"
    MODE=$("$LUCID_DIR/wallpaper-mode.sh" "$AUTO_IMAGE" 2>/dev/null) \
        || MODE=$("$LUCID_DIR/wallpaper-mode.sh" "$SAMPLE" 2>/dev/null) \
        || MODE="$(cat "$CACHE_DIR/current_mode" 2>/dev/null || echo dark)"
fi

if [[ "$MODE" != "dark" && "$MODE" != "light" ]]; then
    echo "error: mode must be dark, light or auto (got: $MODE)" >&2
    exit 1
fi

mkdir -p "$CACHE_DIR"
printf '%s' "$MODE" > "$CACHE_DIR/current_mode"
# ricefarms: keep the existing hypr/matugen/kitty pipeline in sync (it reads
# ~/.cache/quickshell/theme_mode rather than current_mode)
mkdir -p "$CACHE_DIR/quickshell"
printf '%s' "$MODE" > "$CACHE_DIR/quickshell/theme_mode.tmp" && mv -f "$CACHE_DIR/quickshell/theme_mode.tmp" "$CACHE_DIR/quickshell/theme_mode"

case "$THEME" in
matugen | pywal)
    if [[ -z "$WALLPAPER" || ! -f "$WALLPAPER" ]]; then
        echo "error: $THEME derives its colours from the wallpaper, and none is set" >&2
        exit 1
    fi
    # re-setting the same image is a no-op on screen; the point is the
    # regeneration it drives
    "$HOME/.config/hypr/scripts/wallpaper/set-wallpaper.sh" "$WALLPAPER" "$MODE"
    ;;
colour)
    # one colour, built again in the new mode
    "$LUCID_DIR/apply-colour.sh" "$MODE"
    ;;
*)
    "$LUCID_DIR/apply-theme.sh" "$THEME" "$MODE"
    ;;
esac

echo "mode: $MODE (theme: $THEME)"
