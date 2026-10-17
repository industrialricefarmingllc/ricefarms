#!/bin/bash
# capture-wallpapers.sh - render every Steam Workshop wallpaper once with
# linux-wallpaperengine's frame recorder (DEMOMODE build) and store a ~10s
# webm per wall in the pibble captures cache. The picker's generation pass
# bakes preview mp4s from those captures, upgrading tiles from preview
# stills to true renders as captures land - no scan/recipe changes needed.
#
# Singleton via flock (safe to trigger often; pibble's generation pass
# starts it whenever captures are missing). Sequential, niced, resumable:
# finished captures are skipped, failures back off for 7 days.
#
# Capture windows (title "wallpaperengine") are banished to a hidden
# special workspace by hyprland.conf window rules, so a run is invisible.
#
# ...rewired: captures run under a private Xvfb (software GL), so they never
# touch the desktop at all - no rules, no dispatch, no flashes. llvmpipe is
# slower than the NVIDIA path but plenty for 960x540 stills-in-motion, and
# rendering is renderer-identical (conformant GL).
set -u

WEDIR="${WEDIR:-$HOME/.local/share/Steam/steamapps/workshop/content/431960}"
CAPDIR="${CAPDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/pibble/captures}"
DEMOBIN="${DEMOBIN:-/opt/linux-wallpaperengine-capture/linux-wallpaperengine}"

[ -x "$DEMOBIN" ] || { echo "capture binary not built yet: $DEMOBIN" >&2; exit 0; }
[ -d "$WEDIR" ] || { echo "workshop dir missing: $WEDIR" >&2; exit 0; }
command -v ffprobe >/dev/null 2>&1 || echo "warning: ffprobe missing, validating by size only" >&2

mkdir -p "$CAPDIR"
exec 9>"$CAPDIR/.lock"
flock -n 9 || exit 0

# paused when the user wants a quiet machine (fps testing, gaming):
# `touch ~/.cache/pibble/captures/PAUSED` to pause, rm to resume
if [ -f "$CAPDIR/PAUSED" ]; then
    exit 0
fi

# private display for fully-offscreen captures
XVFB_STARTED=0
if [ ! -S /tmp/.X11-unix/X99 ]; then
    Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
    XVFB_PID=$!
    XVFB_STARTED=1
    for i in $(seq 1 50); do
        [ -S /tmp/.X11-unix/X99 ] && break
        sleep 0.1
    done
fi
cleanup_xvfb() {
    if [ "$XVFB_STARTED" = "1" ]; then
        kill "$XVFB_PID" 2>/dev/null || true
    fi
}
trap cleanup_xvfb EXIT

# installed layout keeps its libs beside the binary (lib/ + CEF blobs)
export LD_LIBRARY_PATH="$(dirname "$DEMOBIN")/lib:$(dirname "$DEMOBIN")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Hyprland IPC is unused (captures never map there); the banish helper is
# kept in history only. See git log if windowed captures ever return.

# Transcode a picker preview from a fresh capture (mirrors the Wallpapers
# gen recipe: 960px, 12fps, half speed, crf 18 slow, even dims, validated).
# Atomic.
bake_preview() {
    # $1 = wall dir, $2 = capture webm
    local wall="$1" capfile="$2" cachedir acache akey tmp frames size
    cachedir="$(dirname "$CAPDIR")"
    akey=$(printf '%s' "$wall|a7" | md5sum | cut -d' ' -f1)
    acache="$cachedir/animated/$akey.mp4"
    mkdir -p "$cachedir/animated"
    tmp="${acache%.mp4}.$$.mp4"
    if ffmpeg -y -v error -i "$capfile" -vf "fps=24,scale='min(960,iw)':-2:flags=lanczos,crop='trunc(iw/2)*2':'trunc(ih/2)*2',setpts=2*PTS" -an -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -movflags +faststart "$tmp" 2>/dev/null; then
        frames=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$tmp" 2>/dev/null | grep -E '^[0-9]+$' || echo 0)
        size=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
        if [ "$frames" -ge 10 ] 2>/dev/null && [ "$size" -gt 20000 ]; then
            mv -f "$tmp" "$acache"
        else
            rm -f "$tmp"
        fi
    else
        rm -f "$tmp"
    fi
}

for w in "$WEDIR"/*/; do
    [ -d "$w" ] || continue
    w="${w%/}"
    [ -f "$w/project.json" ] || continue
    id="$(basename "$w")"
    cap="$CAPDIR/$id.webm"
    fail="$CAPDIR/$id.failed"
    # video walls need no capture: the picker plays the real file, and the
    # baked fallback transcodes straight from it (see Wallpapers gen)
    if command -v python3 >/dev/null 2>&1; then
        wtype=$(python3 -c 'import json,os,sys; print((json.load(open(os.path.join(sys.argv[1],"project.json"))).get("type") or "").lower())' "$w" 2>/dev/null) || wtype=""
        [ "$wtype" = "video" ] && continue
    fi
    # fresh capture, or fresh failure backoff, both relative to the wall
    # itself so workshop updates recapture. Fresh means project.json is
    # NOT newer than the capture (>=, not -nt: legacy captures were
    # backdated to exactly project.json's mtime, and strict -nt made
    # every freshness check downstream permanently false). Captures
    # narrower than 900px are the first generation (512px masters) and
    # recapture at the current resolution.
    if [ -f "$cap" ] && [ ! "$w/project.json" -nt "$cap" ]; then
        capw=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$cap" 2>/dev/null | grep -E '^[0-9]+$' || echo 0)
        if [ "$capw" -ge 900 ] 2>/dev/null; then
            rm -f "$fail"
            touch "$cap"
            continue
        fi
    fi
    if [ -f "$fail" ] && [ "$fail" -nt "$w/project.json" ] && [ -z "$(find "$fail" -mtime +7 2>/dev/null)" ]; then
        continue
    fi
    rm -f "$fail"

    tmp="$(mktemp -d)"
    (
        cd "$tmp" || exit 1
        # self-terminating (~10s of frames + startup); timeout is the guard
        # for hangs and renderer crashes, not the normal path.
        # WAYLAND_DISPLAY is unset on purpose: stay on Xvfb (software GL),
        # fully offscreen - nothing ever maps on the desktop.
        env -u WAYLAND_DISPLAY XDG_SESSION_TYPE=x11 DISPLAY=:99 \
            timeout -s KILL 240 taskset -c 0-5 nice -n 19 "$DEMOBIN" \
            --silent --no-fullscreen-pause --no-audio-processing \
            --disable-mouse --window 0x0x960x540 "$w" >capture.log 2>&1
    )
    if [ -f "$tmp/output.webm" ] && [ "$(stat -c%s "$tmp/output.webm" 2>/dev/null || echo 0)" -gt 100000 ]; then
        if command -v ffprobe >/dev/null 2>&1; then
            dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp/output.webm" 2>/dev/null || echo 0)
            if awk "BEGIN {exit !(($dur + 0) > 3)}"; then
                mv -f "$tmp/output.webm" "$cap"
                # bake the picker preview straight from the fresh capture
                # (same recipe + validation as Wallpapers gen, so tiles
                # upgrade without waiting for a gen pass)
                bake_preview "$w" "$cap"
            else
                touch "$fail"
            fi
        else
            mv -f "$tmp/output.webm" "$cap"
            bake_preview "$w" "$cap"
        fi
    else
        touch "$fail"
    fi
    rm -rf "$tmp"
done
