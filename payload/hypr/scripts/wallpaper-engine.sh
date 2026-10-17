#!/bin/bash
# wallpaper-engine.sh - run Almamu/linux-wallpaperengine as a real Hyprland
# background (wlr-layer-shell), not a floating window.
#
# IMPORTANT: linux-wallpaperengine only uses the layer-shell background path
# when given --screen-root/--screen-span/--bg. A bare
# `linux-wallpaperengine <id>` runs in NORMAL_WINDOW mode = a floating GLFW
# window. So this script ALWAYS builds per-monitor --screen-root/--bg args.
#
# Usage:
#   wallpaper-engine.sh <id-or-path>               # same wallpaper, all monitors
#   wallpaper-engine.sh --per-monitor DP-2:<id> DP-1:<id> [...]
#   wallpaper-engine.sh --dry-run <same args...>   # print command, don't run
#   wallpaper-engine.sh stop                       # kill it, restore awww setup
#
# Examples:
#   wallpaper-engine.sh 3707876915
#   wallpaper-engine.sh --per-monitor DP-2:2667198601 DP-1:2667198602 --scaling fill --fps 30
#
# Notes:
# - Needs Wallpaper Engine on Steam + subscribed wallpapers in
#   ~/.local/share/Steam/steamapps/workshop/content/431960/<id>
#   (assets auto-detect from .../steamapps/common/wallpaper_engine/assets,
#   else pass --assets-dir /path/to/assets).
# - Starting stops competing setters (awww-daemon/hyprpaper/mpvpaper); `stop`
#   brings the awww setup back via wallpaper-restore.sh.
# - Useful flags: --scaling fill|fit|stretch --fps 30 --silent --disable-mouse
set -eu

BIN="linux-wallpaperengine"
RESTORE="$HOME/.config/hypr/scripts/wallpaper-restore.sh"

if [ "${1:-}" = "stop" ]; then
    # NOTE: comm truncates to 15 chars, so the process is "linux-wallpaper"
    pkill -x linux-wallpaper || true
    # bring the regular static-wallpaper setup back
    if ! pgrep -x awww-daemon >/dev/null 2>&1; then
        setsid awww-daemon >/dev/null 2>&1 < /dev/null &
    fi
    if [ -x "$RESTORE" ]; then
        sleep 1
        "$RESTORE" >/dev/null 2>&1 &
    fi
    echo "stopped linux-wallpaperengine, awww setup restoring"
    exit 0
fi

DRYRUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRYRUN=1
    shift
fi

FPS=30
SCALING="fill"
EXTRA=""
MONMAP=""   # entries MON:id
DEFAULT_BG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --per-monitor) shift ;;  # marker only; MON:id tokens handled below
        --fps) FPS="$2"; shift 2 ;;
        --scaling) SCALING="$2"; shift 2 ;;
        *:*)
            # MON:id — but guard against --assets-dir style values later; only
            # treat as monitor map if left side looks like a monitor name
            # (hyprctl names contain no '/' and no leading '-')
            left="${1%%:*}"
            case "$left" in
                -*|*/*) EXTRA="$EXTRA $1"; shift ;;
                *) MONMAP="$MONMAP $1"; shift ;;
            esac
            ;;
        --*)
            # value-taking flags consume the next token, booleans don't
            case "$1" in
                --window|--screen-root|--screen-span|--bg|--playlist|--scaling|--clamping|--clamp|--layer|--fps|--volume|--screenshot|--screenshot-delay|--assets-dir|--set-property|--render-debug|--dump-structure|--fullscreen-pause-ignore-appid)
                    EXTRA="$EXTRA $1 ${2:-}"; shift 2 ;;
                *) EXTRA="$EXTRA $1"; shift ;;
            esac
            ;;
        *)  # bare id or path -> default for monitors without explicit mapping
            if [ -z "$DEFAULT_BG" ]; then DEFAULT_BG="$1"; else EXTRA="$EXTRA $1"; fi
            shift
            ;;
    esac
done

if [ -z "$MONMAP" ] && [ -z "$DEFAULT_BG" ]; then
    echo "usage: wallpaper-engine.sh <id-or-path> | --per-monitor MON:id [...] | stop" >&2
    exit 1
fi

# monitor names live from the compositor (DP-1, DP-2, ...)
MONITORS="$(hyprctl monitors -j 2>/dev/null | python3 -c 'import json,sys; print(" ".join(m["name"] for m in json.load(sys.stdin)))' 2>/dev/null || true)"
if [ -z "$MONITORS" ]; then
    echo "could not list monitors via hyprctl; is Hyprland running?" >&2
    exit 1
fi

ARGS="--fps $FPS"
# shellcheck disable=SC2086
for mon in $MONITORS; do
    bg="$DEFAULT_BG"
    for m in $MONMAP; do
        if [ "${m%%:*}" = "$mon" ]; then bg="${m#*:}"; fi
    done
    if [ -z "$bg" ]; then
        echo "no wallpaper for monitor $mon (and no default given), skipping" >&2
        continue
    fi
    # NOTE: --scaling goes BEFORE --screen-root per upstream README ordering
    ARGS="$ARGS --scaling $SCALING --screen-root $mon --bg $bg"
done
ARGS="$ARGS $EXTRA"

if [ "$DRYRUN" = "1" ]; then
    echo "$BIN $ARGS"
    exit 0
fi

# one instance only: an old one would stack a second layer over this one
pkill -x linux-wallpaper || true
pkill -x mpvpaper || true
# uncap swaps: with several outputs lwe's vsync-serialized eglSwapBuffers
# collapses to a slideshow (measured); the compositor still vsyncs presents
export __GL_SYNC_TO_VBLANK=0
# competing static setters only when covering ALL outputs: on a subset (e.g.
# DP-2 animated, awww statics elsewhere) they must keep running underneath
full=1
# shellcheck disable=SC2086
for mon in $MONITORS; do
    covered=""
    [ -n "$DEFAULT_BG" ] && covered=1
    for m in $MONMAP; do
        [ "${m%%:*}" = "$mon" ] && covered=1
    done
    [ -n "$covered" ] || full=0
done
if [ "$full" = "1" ]; then
    pkill -x awww-daemon || true
    pkill -x hyprpaper || true
fi

# shellcheck disable=SC2086
exec $BIN $ARGS
