#!/usr/bin/env bash
# live-capture.sh <key> <we|video> <video-source> <current-label> [token]
#
# After an animated wallpaper has settled, keep a high-resolution recording:
#
#   <cache>/<safe>.mp4   the recording (for a plain video, the source itself)
#   <cache>/<safe>.gif   10s, 1280px, for the picker's hover preview
#   <cache>/<safe>.jpg   a full-resolution frame, for the iris
#
# Workshop scenes are rendered on a private headless sway compositor, so the
# recording contains the background only: no windows, no bar, no desktop
# widgets. Keeping that compositor out of the real Hyprland session means
# skwd's scene renderer is never rebuilt and the desktop never fades out.
# Plain videos are read from their source file; nothing is recorded.
#
# A cached entry is reused while the source's mtime is unchanged. The request
# token is checked before and after every stage, so A -> B -> A during the
# recording cannot install A's stale preview.
set -uo pipefail

key="${1:-}"
kind="${2:-}"
source="${3:-}"
label="${4:-}"
token="${5:-}"
REQ_FILE="$HOME/.cache/lucid/fast.request"

[ -n "$key" ] || exit 0
command -v ffmpeg >/dev/null 2>&1 || exit 0

CACHE="$HOME/.cache/lucid/live-previews"
INDEX="$CACHE/index.json"
mkdir -p "$CACHE" || exit 0

if [ "$kind" = "video" ]; then
    [ -n "$source" ] && [ -f "$source" ] || exit 0
    mtime=$(stat -c %Y "$source" 2>/dev/null || echo 0)
    safe="video-$(printf '%s|%s' "$key" "$mtime" | sha1sum | cut -c1-16)"
    mp4="$source"
    owns_mp4=0
else
    scene_id="${key#we:}"
    scene="$HOME/.local/share/Steam/steamapps/workshop/content/431960/$scene_id"
    [ -d "$scene" ] || exit 0
    mtime=$(stat -c %Y "$scene" 2>/dev/null || echo 0)
    safe="we-$(printf '%s' "$scene_id" | tr -c 'A-Za-z0-9._-' '-')"
    mp4="$CACHE/$safe.mp4"
    owns_mp4=1
fi

gif="$CACHE/$safe.gif"
jpg="$CACHE/$safe.jpg"

cached() {
    [ -s "$mp4" ] && [ -s "$gif" ] && [ -s "$jpg" ] || return 1
    [ -f "$INDEX" ] || return 1
    old=$(jq -r --arg k "$key" '.[$k].mtime // ""' "$INDEX" 2>/dev/null || true)
    [ "$old" = "$mtime" ]
}

cached && exit 0

exec 9>"$CACHE/.lock"
command -v flock >/dev/null 2>&1 && flock -w 20 9 || true
cached && exit 0

CAP_RUNTIME=""
CAP_PID=""
CAP_DISPLAY=""
tmp="$CACHE/.$safe.$$.mp4"
tmp_gif="$CACHE/.$safe.$$.gif"
tmp_jpg="$CACHE/.$safe.$$.jpg"

# The recording compositor is disposable: a private runtime directory means
# its Wayland display and paper socket cannot be mistaken for the real session.
cap_stop() {
    [ -n "$CAP_RUNTIME" ] || return 0
    timeout 5 env XDG_RUNTIME_DIR="$CAP_RUNTIME" WAYLAND_DISPLAY="${CAP_DISPLAY:-wayland-1}" \
        skwd-paper-v2 stop HEADLESS-1 >/dev/null 2>&1 || true
    if [ -n "$CAP_PID" ]; then
        kill -TERM "$CAP_PID" >/dev/null 2>&1 || true
        for _ in {1..20}; do
            kill -0 "$CAP_PID" 2>/dev/null || break
            sleep 0.05
        done
        kill -KILL "$CAP_PID" >/dev/null 2>&1 || true
        wait "$CAP_PID" 2>/dev/null || true
    fi
    rm -rf "$CAP_RUNTIME"
    CAP_RUNTIME=""
    CAP_PID=""
    CAP_DISPLAY=""
}

cleanup() {
    cap_stop
    rm -f "$tmp" "$tmp_gif" "$tmp_jpg"
}
trap cleanup EXIT

# let the skwd transition and the picker close finish
sleep 1.5

current() {
    head -n1 "$HOME/.cache/current_live_wallpaper" 2>/dev/null || true
}

# A label alone is not enough: A -> B -> A during the recording would still
# match it. The request token changes on every apply.
still_current() {
    [ "$(current)" = "$label" ] || return 1
    if [ -n "$token" ]; then
        [ "$(cut -d'|' -f1 "$REQ_FILE" 2>/dev/null || true)" = "$token" ] || return 1
    fi
    return 0
}

still_current || exit 0

if [ "$kind" = "video" ]; then
    # show the video itself: a GIF and a poster are derived from the file, not
    # from a screen recording of it
    record="$source"
else
    command -v wf-recorder >/dev/null 2>&1 || exit 0
    command -v sway >/dev/null 2>&1 || exit 0
    command -v skwd-paper-v2 >/dev/null 2>&1 || exit 0

    # Record on a private headless compositor, not an output added to the real
    # Hyprland session. Adding/removing a real output makes skwd rebuild its
    # shared scene renderer, which briefly blanked every monitor. A nested sway
    # with its own XDG_RUNTIME_DIR is invisible to the desktop entirely.
    maxres=$(hyprctl monitors -j 2>/dev/null \
        | jq -r '[.[] | select((.name | startswith("HEADLESS")) | not)] | max_by(.width * .height) | "\(.width)x\(.height)"' 2>/dev/null || true)
    [ -n "$maxres" ] && [ "$maxres" != "null" ] || maxres="3840x2160"

    CAP_RUNTIME=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/lucid-capture.XXXXXX") || exit 0
    chmod 700 "$CAP_RUNTIME"
    cap_conf="$CAP_RUNTIME/sway.conf"
    {
        printf 'output HEADLESS-1 resolution %s position 0,0\n' "$maxres"
        printf 'default_border none\n'
        printf 'default_floating_border none\n'
        printf 'focus_follows_mouse no\n'
    } >"$cap_conf"

    XDG_RUNTIME_DIR="$CAP_RUNTIME" WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 \
        WLR_LIBINPUT_NO_DEVICES=1 sway -c "$cap_conf" >"$CAP_RUNTIME/sway.log" 2>&1 &
    CAP_PID=$!

    cap_display=""
    for _ in {1..200}; do
        for sock in "$CAP_RUNTIME"/wayland-*; do
            if [ -S "$sock" ]; then
                cap_display="${sock##*/}"
                break
            fi
        done
        [ -n "$cap_display" ] && break
        kill -0 "$CAP_PID" 2>/dev/null || break
        sleep 0.05
    done
    [ -n "$cap_display" ] || exit 0
    CAP_DISPLAY="$cap_display"
    cap_env=(env XDG_RUNTIME_DIR="$CAP_RUNTIME" WAYLAND_DISPLAY="$cap_display")
    sleep 0.5

    # paper-v2 renders the scene, not skwd's daemon, so the real outputs keep
    # their renderer and wallpaper while this runs.
    timeout 30 "${cap_env[@]}" skwd-paper-v2 apply HEADLESS-1 "$scene" >/dev/null 2>&1 || exit 0
    sleep 1
    still_current || exit 0

    # Some scenes never produce a frame on the nested compositor (their WE
    # runtime cannot start there). wf-recorder waits for frames forever and
    # ignores SIGINT, so give it a hard kill and treat an empty file as a
    # failed capture instead of wedging the preview lock for every later scene.
    timeout -s INT -k 5 10 "${cap_env[@]}" wf-recorder -y -f "$tmp" -r 30 \
        -c libx264 -p crf=16 -p preset=fast -x yuv420p -o HEADLESS-1 >/dev/null 2>&1 || true
    cap_stop
    [ -s "$tmp" ] && [ "$(stat -c %s "$tmp" 2>/dev/null || echo 0)" -gt 20000 ] || exit 0
    [ -n "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$tmp" 2>/dev/null)" ] || exit 0
    record="$tmp"
fi

# a selection that changed while recording is not this wallpaper's preview
still_current || exit 0

# card loop: a 3s excerpt at 1280px, 30fps. The 10s recording is the mp4; a
# full-length GIF of a complex scene can be tens of MB, so the card loops a
# short, high-resolution window instead. 30fps gives smooth motion; GIF's
# centisecond delays round it to ~33fps, as close as the format allows.
ffmpeg -v error -y -t 3 -i "$record" \
    -vf "fps=30,scale=1280:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a" \
    "$tmp_gif" </dev/null || exit 0

# iris source: a full-resolution frame, not the library thumbnail
ffmpeg -v error -y -ss 1 -i "$record" -frames:v 1 \
    -vf "scale='min(3840,iw)':-2:flags=lanczos" -q:v 1 "$tmp_jpg" </dev/null || \
    ffmpeg -v error -y -ss 0 -i "$record" -frames:v 1 \
        -vf "scale='min(3840,iw)':-2:flags=lanczos" -q:v 1 "$tmp_jpg" </dev/null || exit 0

still_current || exit 0

if [ "$owns_mp4" = "1" ]; then
    mv -f "$tmp" "$mp4" || exit 0
fi
mv -f "$tmp_gif" "$gif" || exit 0
mv -f "$tmp_jpg" "$jpg" || exit 0
trap - EXIT

# a switch during the encode must not install a preview for the old one
still_current || exit 0

created=$(date +%s)
tmp_index="$INDEX.$$.tmp"
if [ -f "$INDEX" ]; then
    jq --arg k "$key" --arg mp4 "$mp4" --arg gif "$gif" --arg jpg "$jpg" \
        --argjson created "$created" --arg mtime "$mtime" \
        '.[$k] = {mp4:$mp4,gif:$gif,jpg:$jpg,created:$created,mtime:$mtime}' \
        "$INDEX" >"$tmp_index" 2>/dev/null || rm -f "$tmp_index"
else
    jq -n --arg k "$key" --arg mp4 "$mp4" --arg gif "$gif" --arg jpg "$jpg" \
        --argjson created "$created" --arg mtime "$mtime" \
        '{($k):{mp4:$mp4,gif:$gif,jpg:$jpg,created:$created,mtime:$mtime}}' \
        >"$tmp_index" 2>/dev/null || rm -f "$tmp_index"
fi
[ -s "$tmp_index" ] && mv -f "$tmp_index" "$INDEX" || rm -f "$tmp_index"

exit 0
