#!/usr/bin/env bash
# set-wallpaper.sh <path-to-image> [dark|light]
#
# A picture's <stem>.json sidecar can pin its mode with {"themeMode":"dark"}
# (or {"mode":"dark"}); the explicit argument above still wins.
#
# Sets the wallpaper, then regenerates the palette if the active theme derives
# it from the image. ~/.cache/current_theme decides:
#   matugen  — one scheme computed from the image, every template rendered
#              from that scheme, side effects delivered once by theme-fanout.sh
#   pywal    — wal extracts, gen-pywal-palette.py maps it to material roles
#   anything else — a static theme owns its palette, so colours are left alone
#
# THEME_ONLY=1 derives colours + dark/light mode from the image WITHOUT
# touching the on-screen wallpaper or restore state. Used for animated sources
# (Wallpaper Engine walls, videos) that have no static file to set: a cached
# thumbnail/frame stands in as the sampler image while the live backend keeps
# rendering.
#
# Ordering and concurrency:
#   * the wallpaper is set first because it is the only step you see;
#   * a monotonically newer selection supersedes an older one: the fast path
#     checks a token before touching the screen, and the publish lock checks
#     it again before writing the live palette;
#   * scheme decoding is serialised, so a burst of 4K images cannot saturate
#     every core; the newest selection reuses the cache the older one filled;
#   * application fanout is asynchronous and coalesced (theme-fanout.sh).

set -euo pipefail

WALLPAPER="${1:-}"
EXPLICIT_MODE="${2:-}"
CACHE_DIR="$HOME/.cache"
LUCID_DIR="$HOME/.config/lucid"
LIVE_INDEX="$CACHE_DIR/lucid/live-previews/index.json"
LIVE_CAPTURE="$HOME/.config/quickshell/luciddocks/live-capture.sh"
MATUGEN_CFG="$HOME/.config/matugen/config.toml"
PREFS="$HOME/.config/quickshell/lucidprefs/prefs.json"
CURRENT_WALL_FILE="$CACHE_DIR/current_wallpaper"
CURRENT_LIVE_FILE="$CACHE_DIR/current_live_wallpaper"
CURRENT_THEME_FILE="$CACHE_DIR/current_theme"
SIG_FILE="$CACHE_DIR/lucid/apply.sig"
SCHEME_DIR="$CACHE_DIR/lucid/schemes"
SOURCE_DIR="$CACHE_DIR/lucid/sources"
REQ_FILE="$CACHE_DIR/lucid/fast.request"
mkdir -p "$CACHE_DIR/lucid" "$SCHEME_DIR" "$SOURCE_DIR" "$CACHE_DIR/quickshell"

# Pillow/numpy live in the system interpreter (python-pillow/python-numpy).
# A pyenv or venv shim earlier in PATH cannot import them, so surface-seed.py
# and wallpaper-softlight.py silently do nothing and kitty/Lucid keep flat,
# accent-tinted background colours. Prefer an interpreter with both;
# LUCID_PYTHON overrides.
PYTHON="${LUCID_PYTHON:-}"
if [ -z "$PYTHON" ]; then
    for _py in /usr/bin/python3 python3; do
        if "$_py" -c 'import PIL, numpy' >/dev/null 2>&1; then PYTHON="$_py"; break; fi
    done
    PYTHON="${PYTHON:-python3}"
fi

# both settings reads in one jq: the backend switch and the palette signature.
# jq is by far the most expensive thing on the fast path, so it is called once.
PREF_LINE=$(jq -r '[(if .skwdWall == false then "false" else "true" end),
    ([.matugenScheme // "", .matugenContrast // "",
      .matugenSourceIndex // "", .matugenSourceImage // "",
      .themeColour // "", .skwdWall // true] | tojson)] | @tsv' \
    "$PREFS" 2>/dev/null || true)
SKWD_PREF="${PREF_LINE%%$'\t'*}"
PREF_SIG="${PREF_LINE#*$'\t'}"
[[ "$SKWD_PREF" == "false" ]] || SKWD_PREF=true

# ── backend ─────────────────────────────────────────────────────────────────
# skwd-wall takes over images, videos and Wallpaper Engine scenes when it is
# installed and Settings -> Theme -> skwd-wall is on. A scene arrives as
# skwd:we:<id>, because there is no file of its own to set.
SKWD=0
SKWD_TARGET=""
SKWD_SAMPLE="${SKWD_SAMPLE:-}"
SKWD_LIVE_LABEL=""
SKWD_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/skwd-wall-v2/wall.sock"
if command -v skwd-helm >/dev/null 2>&1 && command -v skwd-walld >/dev/null 2>&1; then
    if [[ "$SKWD_PREF" != "false" ]]; then
        # the socket is the cheap liveness check; asking systemd on every apply
        # costs more than the rest of the fast path put together
        if [[ -S "$SKWD_SOCK" ]]; then
            SKWD=1
        else
            systemctl --user start skwd-walld >/dev/null 2>&1 || true
            for _ in {1..20}; do
                [[ -S "$SKWD_SOCK" ]] && { SKWD=1; break; }
                sleep 0.05
            done
        fi
    fi
fi

[[ -n "$WALLPAPER" ]] || { echo "error: no wallpaper path given" >&2; echo "usage: $(basename "$0") <path-to-image> [dark|light]" >&2; exit 1; }
WALLPAPER="${WALLPAPER/#\~/$HOME}"
TARGET_LABEL="$WALLPAPER"

# A Wallpaper Engine preset is only a set of settings; its project.json names
# the Workshop scene it needs. Download that scene first, or the daemon rejects
# the apply with "requires Workshop item <id>; download it first".
ensure_scene_dependency() {
    [[ "$SKWD" == 1 && "$SKWD_TARGET" == we:* ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local scene="${SKWD_TARGET#we:}"
    local dir="$HOME/.local/share/Steam/steamapps/workshop/content/431960/$scene"
    [ -f "$dir/project.json" ] || return 0
    local deps one installed=0
    deps=$(jq -r '.dependency // empty' "$dir/project.json" 2>/dev/null || true)
    [ -n "$deps" ] || return 0
    command -v skwd-steam >/dev/null 2>&1 || return 0
    if ! pgrep -x steam >/dev/null 2>&1; then
        nohup steam -silent >/dev/null 2>&1 &
        sleep 5
    fi
    for one in ${deps//,/ }; do
        [[ "$one" =~ ^[0-9]+$ ]] || continue
        local dep_dir="$HOME/.local/share/Steam/steamapps/workshop/content/431960/$one"
        [ -d "$dep_dir" ] && continue
        echo "installing Workshop dependency $one" >&2
        skwd-steam "$one" >/dev/null 2>&1 || true
        [ -d "$dep_dir" ] && installed=1
    done
    # a new scene folder is invisible to skwd until its next scan
    if [[ "$installed" == "1" ]]; then
        skwd-helm list >/dev/null 2>&1 || true
    fi
}

if [[ "$WALLPAPER" == skwd:* ]]; then
    [[ "$SKWD" == 1 ]] || { echo "error: skwd-wall is not enabled" >&2; exit 1; }
    SKWD_TARGET="${WALLPAPER#skwd:}"
    SKWD_LIVE_LABEL="$WALLPAPER"
    ensure_scene_dependency
    if [[ -z "$SKWD_SAMPLE" || ! -f "$SKWD_SAMPLE" ]]; then
        command -v jq >/dev/null 2>&1 || { echo "error: jq is needed to sample a scene" >&2; exit 1; }
        SKWD_SAMPLE=$(skwd-helm list --json 2>/dev/null \
            | jq -r --arg k "$SKWD_TARGET" '.wallpapers[]? | select(.key == $k) | (.thumb // .preview // empty)' 2>/dev/null \
            | head -n1)
    fi
    # A scene that was just downloaded is already on disk before skwd has
    # scanned it, so the list above can still be empty. Use the author's own
    # preview as the sample instead of bailing out before wait_skwd_target
    # gets a chance to wait for the library.
    if [[ -z "$SKWD_SAMPLE" || ! -f "$SKWD_SAMPLE" ]]; then
        scene_dir="$HOME/.local/share/Steam/steamapps/workshop/content/431960/${SKWD_TARGET#we:}"
        for f in preview.gif preview.jpg preview.png; do
            if [[ -f "$scene_dir/$f" ]]; then
                SKWD_SAMPLE="$scene_dir/$f"
                break
            fi
        done
    fi
    [[ -n "$SKWD_SAMPLE" && -f "$SKWD_SAMPLE" ]] || { echo "error: no preview for $WALLPAPER" >&2; exit 1; }
    WALLPAPER="$SKWD_SAMPLE"
else
    SKWD_TARGET="$WALLPAPER"
fi

[[ -f "$WALLPAPER" ]] || { echo "error: file not found: $WALLPAPER" >&2; exit 1; }

# skwd renders the video itself, but the palette still needs a still. Its own
# video thumbnail is exactly that first frame and already on disk, so prefer
# it; a direct invocation without one falls back to the cached ffmpeg frame.
if [[ "$SKWD" == 1 && "$WALLPAPER" =~ \.(mp4|webm|mkv|mov|m4v)$ ]]; then
    SKWD_LIVE_LABEL="$WALLPAPER"
    if [[ -z "$SKWD_SAMPLE" || ! -f "$SKWD_SAMPLE" ]]; then
        if command -v jq >/dev/null 2>&1; then
            SKWD_SAMPLE=$(skwd-helm list --json 2>/dev/null \
                | jq -r --arg p "$WALLPAPER" '.wallpapers[]? | select(.video_file == $p) | (.thumb // empty)' 2>/dev/null \
                | head -n1)
        fi
    fi
    if [[ -z "$SKWD_SAMPLE" || ! -f "$SKWD_SAMPLE" ]]; then
        command -v ffmpeg >/dev/null 2>&1 || { echo "error: a video wallpaper needs ffmpeg" >&2; exit 1; }
        FRAME_DIR="$CACHE_DIR/lucid/live-frames"
        FRAME="$FRAME_DIR/$(printf '%s|%s' "$WALLPAPER" "$(stat -c %Y "$WALLPAPER" 2>/dev/null || echo 0)" | sha1sum | cut -c1-16).jpg"
        if [[ ! -f "$FRAME" ]]; then
            mkdir -p "$FRAME_DIR"
            if ! ffmpeg -v error -y -i "$WALLPAPER" -frames:v 1 -q:v 2 "$FRAME.$$.jpg" </dev/null; then
                rm -f "$FRAME.$$.jpg"
                echo "error: could not read a frame from $WALLPAPER" >&2
                exit 1
            fi
            mv -f "$FRAME.$$.jpg" "$FRAME"
            # touched once, when cut: a repeated apply must still hit the fast path
            touch "$FRAME"
            find "$FRAME_DIR" -type f -mtime +60 -delete 2>/dev/null || true
        fi
        SKWD_SAMPLE="$FRAME"
    fi
    WALLPAPER="$SKWD_SAMPLE"
fi
if [[ "$SKWD" == 1 ]]; then
    SKWD_SAMPLE="${SKWD_SAMPLE:-$WALLPAPER}"
    [[ -n "$SKWD_TARGET" ]] || SKWD_TARGET="$TARGET_LABEL"
fi

# ── reveal source ───────────────────────────────────────────────────────────
# The iris used to reveal a WebP/thumbnail, which is soft and sometimes not
# decodable. Prefer the poster frame from the 10s live recording, then the
# author's own preview image, then a real video frame, then the sample.
REVEAL_SOURCE="$WALLPAPER"
LIVE_KEY=""
LIVE_KIND=""
LIVE_SOURCE=""
LIVE_SCENE=""
if [[ "$SKWD" == 1 ]]; then
    if [[ "$SKWD_TARGET" == we:* ]]; then
        LIVE_KEY="$SKWD_TARGET"
        live_meta=$(skwd-helm list --json 2>/dev/null \
            | jq -r --arg k "$LIVE_KEY" '.wallpapers[]? | select(.key == $k) | [.type, (.video_file // ""), (.path // "")] | @tsv' 2>/dev/null \
            | head -n1)
        IFS=$'\t' read -r live_type live_video live_path <<<"$live_meta"
        if [[ "$live_type" == "video" && -n "$live_video" ]]; then
            LIVE_KIND=video
            LIVE_SOURCE="$live_video"
        else
            LIVE_KIND=we
            LIVE_SCENE="$live_path"
        fi
    elif [[ "$SKWD_LIVE_LABEL" =~ \.(mp4|webm|mkv|mov|m4v)$ ]]; then
        LIVE_KIND=video
        LIVE_SOURCE="$SKWD_LIVE_LABEL"
        LIVE_KEY=$(skwd-helm list --json 2>/dev/null \
            | jq -r --arg p "$SKWD_LIVE_LABEL" '.wallpapers[]? | select(.video_file == $p) | .key' 2>/dev/null \
            | head -n1)
        [[ -n "$LIVE_KEY" ]] || LIVE_KEY="$SKWD_LIVE_LABEL"
    fi

    if [[ -n "$LIVE_KEY" && -f "$LIVE_INDEX" ]]; then
        live_jpg=$(jq -r --arg k "$LIVE_KEY" '.[$k].jpg // empty' "$LIVE_INDEX" 2>/dev/null | head -n1)
        [[ -n "$live_jpg" && -f "$live_jpg" ]] && REVEAL_SOURCE="$live_jpg"
    fi

    # first scene apply: the author's preview is a real image, unlike the WebP thumb
    if [[ "$REVEAL_SOURCE" == "$WALLPAPER" && "$LIVE_KIND" == "we" ]]; then
        for c in "$LIVE_SCENE/preview.jpg" "$LIVE_SCENE/preview.png" "$LIVE_SCENE/preview.gif"; do
            if [[ -n "$LIVE_SCENE" && -f "$c" ]]; then
                REVEAL_SOURCE="$c"
                break
            fi
        done
    fi

    # first video apply: a real frame at 1s, not the WebP thumb
    if [[ "$REVEAL_SOURCE" == "$WALLPAPER" && "$LIVE_KIND" == "video" && -n "$LIVE_SOURCE" ]] \
            && command -v ffmpeg >/dev/null 2>&1; then
        RF_DIR="$CACHE_DIR/lucid/reveal-frames"
        RF="$RF_DIR/$(printf '%s|%s' "$LIVE_SOURCE" "$(stat -c %Y "$LIVE_SOURCE" 2>/dev/null || echo 0)" | sha1sum | cut -c1-16).jpg"
        if [[ ! -f "$RF" ]]; then
            mkdir -p "$RF_DIR"
            ffmpeg -v error -y -ss 1 -i "$LIVE_SOURCE" -frames:v 1 -q:v 2 "$RF.$$.jpg" </dev/null \
                && mv -f "$RF.$$.jpg" "$RF" || rm -f "$RF.$$.jpg"
        fi
        [[ -f "$RF" ]] && REVEAL_SOURCE="$RF"
    fi
fi

stat_key() { stat -c '%y|%s' "$1" 2>/dev/null || printf missing; }
write_if_diff() { # $1 = file, $2 = value
    local f="$1" v="$2"
    if [ ! -f "$f" ] || [ "$(cat "$f" 2>/dev/null)" != "$v" ]; then
        printf '%s' "$v" >"$f.tmp" && mv -f "$f.tmp" "$f"
    fi
}
write_atomic() { # $1 = file, content on stdin
    local f="$1" tmp="${1}.tmp.$$"
    mkdir -p "$(dirname "$f")"
    cat >"$tmp"
    if [ -f "$f" ] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; else mv -f "$tmp" "$f"; fi
}
is_current() {
    [ "$(cut -d'|' -f1 "$REQ_FILE" 2>/dev/null || true)" = "$TOKEN" ]
}
REVEAL_FILE="$CACHE_DIR/quickshell/wallpaper-reveal.json"
REVEAL_FLAG="$CACHE_DIR/quickshell/reveal-active"
REVEAL_READY="$CACHE_DIR/quickshell/reveal-ready"
REVEAL_COVERED="$CACHE_DIR/quickshell/reveal-covered"
REVEAL_HEARTBEAT="$CACHE_DIR/quickshell/reveal-heartbeat"
HEARTBEAT_PID=""
REVEALING=0
# The reveal's watchdog closes the iris when the shell has gone quiet. Keep
# proving this apply is still working while depth/matte/mesh and the wallpaper
# decode run, so the circle only opens when everything is actually there.
reveal_heartbeat_start() {
    [ -n "$HEARTBEAT_PID" ] && return 0
    # $$ is this script's own pid, and bash keeps it in the subshell below.
    # $PPID is whatever started the script - normally the shell - so a script
    # killed without running its EXIT trap used to leave this loop refreshing
    # the heartbeat for ever: the iris watchdog then never saw a quiet script
    # and the circle stayed on screen with the wallpaper already applied.
    ( while kill -0 "$$" 2>/dev/null; do
        date +%s%3N >"$REVEAL_HEARTBEAT" 2>/dev/null || true
        sleep 0.5
      done ) &
    HEARTBEAT_PID=$!
}
reveal_heartbeat_stop() {
    [ -n "$HEARTBEAT_PID" ] || return 0
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
}
wait_reveal_ready() {
    local i
    # The ready marker is announced when the drawing has finished, so this
    # also covers the whole animation. Everything that follows (mode detect,
    # palette, depth, wallpaper) runs on the drawing's last frame instead of
    # competing with it.
    for i in {1..500}; do
        [ -f "$REVEAL_READY" ] && return 0
        sleep 0.02
    done
    return 0
}
wait_reveal_covered() {
    local i
    # The drawing now holds the "covered" marker until it has played out, so
    # the palette/depth work starts on its finished frame instead of stalling
    # the animation. Allow the full drawing plus a few stalled frames.
    for i in {1..500}; do
        [ -f "$REVEAL_COVERED" ] && return 0
        sleep 0.02
    done
    return 0
}
reveal_write() { # $1 = in|out
    # qs ipc call waits for the handler to answer, and the handler's reply is
    # held until the shell finishes the animation frame (300-600 ms). Send it
    # detached so the wallpaper/palette writes happen while the circle is
    # already growing, not after it has gone.
    if [[ "$1" == "in" ]]; then
        ( timeout 2 qs ipc call wallpaper-reveal reveal "$TOKEN" "$REVEAL_SOURCE" >/dev/null 2>&1 & ) 2>/dev/null || true
    else
        ( timeout 2 qs ipc call wallpaper-reveal conceal "$TOKEN" >/dev/null 2>&1 & ) 2>/dev/null || true
    fi
}

# Close the iris on any exit that this apply still owns. Without this, one
# failing step (a matugen template, skwd, a killed helper) used to leave the
# reveal to the shell's heartbeat watchdog: the circle stayed up for another
# 2.5 s and then vanished wherever the wallpaper/spatial pipeline happened to
# be. The token guard in the shell means a stale apply cannot close a newer
# reveal, so only close when this selection is still the current one.
reveal_cleanup() {
    if [[ "${REVEALING:-0}" == "1" && -n "${TOKEN:-}" ]] && is_current; then
        REVEALING=0
        reveal_write out
        printf '0' >"$REVEAL_FLAG"
    fi
    reveal_heartbeat_stop
}
trap 'reveal_cleanup' EXIT
trap 'reveal_cleanup; exit 143' TERM INT HUP

write_restore_state() {
    # two lines, the same file LiveWall reads: the real moving target (a video
    # path or skwd:we:<id>) and the still that stands in for it in the palette.
    # An empty first line means the desktop is a still. Written before
    # current_wallpaper, so whoever reads that on its change already sees it.
    if [[ "$SKWD" == 1 ]]; then
        write_if_diff "$CURRENT_LIVE_FILE" "$(printf '%s\n%s' "${SKWD_LIVE_LABEL:-}" "$WALLPAPER")"
    else
        # no moving target: stop lucid's player if it still has one from before
        write_if_diff "$CURRENT_LIVE_FILE" "$(printf '\n%s' "$WALLPAPER")"
    fi
    write_if_diff "$CURRENT_WALL_FILE" "$WALLPAPER"
    write_if_diff "$HOME/.cache/hypr_last_wallpaper" "$WALLPAPER"
    write_if_diff "$HOME/.config/hypr/current_wallpaper" "$WALLPAPER"
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg p "$WALLPAPER" '{current:$p}' | \
            write_atomic "$HOME/.config/quickshell/luciddocks/wallpaper.json"
    else
        printf '{\n    "current": "%s"\n}\n' "$WALLPAPER" | \
            write_atomic "$HOME/.config/quickshell/luciddocks/wallpaper.json"
    fi
    if [[ "$SKWD" != 1 ]]; then
        {
            cat <<EOF2
preload = $WALLPAPER

wallpaper {
    monitor = DP-1
    path = $WALLPAPER
}

wallpaper {
    monitor =
    path = $WALLPAPER
}

splash = false
ipc = on
EOF2
        } | write_atomic "$HOME/.config/hypr/hyprpaper.conf"
    fi
}

CURRENT_THEME="$(cat "$CURRENT_THEME_FILE" 2>/dev/null || echo matugen)"

# ── mode ────────────────────────────────────────────────────────────────────
# A picture's sidecar (<stem>.json, the Wallhaven metadata file) can pin the
# mode instead of measuring the image: {"themeMode": "dark"} (or "mode").
# An explicit [dark|light] argument still wins over the sidecar.
#
# Otherwise a wallpaper is dark when either more than half of a 64×64 sample
# sits below luma 100, or at least a fifth sits below luma 32 (a large true-black
# region). The two wallpapers this was tuned against:
#   wallhaven-ogwgmp.png  2460/4096 = 60.06% below 100 -> dark
#   wallhaven-gwmyk7.jpg   1153/4096 = 28.15% below 32  -> dark
DARK_LUMA=100
DARK_THRESHOLD=0.5
BLACK_LUMA=32
BLACK_THRESHOLD=0.2

wallpaper_mode_override() { # $1 = image, prints dark|light when pinned
    local image="$1" sidecar mode
    [[ -n "$image" && -f "$image" ]] || return 1
    sidecar="${image%.*}.json"
    [[ -f "$sidecar" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    mode=$(jq -r '(.themeMode // .mode // "") | tostring | ascii_downcase' "$sidecar" 2>/dev/null || true)
    case "$mode" in
        dark | light) printf '%s' "$mode" ;;
        *) return 1 ;;
    esac
}
CONFIG_MODE="$(wallpaper_mode_override "$TARGET_LABEL" || true)"
[[ -n "$CONFIG_MODE" ]] || CONFIG_MODE="$(wallpaper_mode_override "$WALLPAPER" || true)"

# A wallpaper's brightness does not change while its mtime/size are unchanged,
# so cache the answer. This removes an ffmpeg decode from every re-select and
# from every mode toggle. Both thresholds are part of the key, so retuning
# either never resurrects answers measured against the old one.
MODE=""
MODE_KEY=$(printf '%s|%s|%s|%s|%s|%s' "$WALLPAPER" "$(stat_key "$WALLPAPER")" "$DARK_LUMA" "$DARK_THRESHOLD" "$BLACK_LUMA" "$BLACK_THRESHOLD" | sha1sum | cut -d' ' -f1)
MODE_CACHE="$CACHE_DIR/lucid/wallpaper-mode/$MODE_KEY"
if [[ -n "$EXPLICIT_MODE" ]]; then
    MODE="$EXPLICIT_MODE"
elif [[ -n "$CONFIG_MODE" ]]; then
    MODE="$CONFIG_MODE"
elif [[ -f "$MODE_CACHE" ]]; then
    MODE="$(cat "$MODE_CACHE")"
fi

# The first sighting of an image costs ~320 ms of ffmpeg + Python before the
# iris can even start. Nothing the iris needs depends on the answer, so the
# reveal starts first and this runs while the circle grows.
detect_mode() {
    [[ -n "$MODE" ]] && return 0
    local mode="dark"
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -y -i "$WALLPAPER" -vf "scale=64:64:flags=area" -f rawvideo -pix_fmt rgb24 "$CACHE_DIR/lucid/.wallgrid.rgb" 2>/dev/null || true
        mode=$(DARK_LUMA="$DARK_LUMA" DARK_THRESHOLD="$DARK_THRESHOLD" \
            BLACK_LUMA="$BLACK_LUMA" BLACK_THRESHOLD="$BLACK_THRESHOLD" "$PYTHON" - << 'PY' 2>/dev/null || echo dark
import os
p=os.path.expanduser('~/.cache/lucid/.wallgrid.rgb')
try:
    d=open(p,'rb').read(); n=len(d)//3
    if n==0:
        print('dark')
    else:
        dark_luma=float(os.environ.get('DARK_LUMA', '100'))
        black_luma=float(os.environ.get('BLACK_LUMA', '32'))
        dark=black=0
        for i in range(n):
            v=0.2126*d[3*i]+0.7152*d[3*i+1]+0.0722*d[3*i+2]
            if v < dark_luma: dark+=1
            if v < black_luma: black+=1
        is_dark = dark/n > float(os.environ.get('DARK_THRESHOLD', '0.5')) \
            or black/n > float(os.environ.get('BLACK_THRESHOLD', '0.2'))
        print('dark' if is_dark else 'light')
except Exception:
    print('dark')
PY
)
    fi
    [[ "$mode" != "light" && "$mode" != "dark" ]] && mode="dark"
    MODE="$mode"
    mkdir -p "$(dirname "$MODE_CACHE")"
    printf '%s' "$MODE" >"$MODE_CACHE.tmp" && mv -f "$MODE_CACHE.tmp" "$MODE_CACHE"
    find "$CACHE_DIR/lucid/wallpaper-mode" -type f -mtime +60 -delete 2>/dev/null || true
}

# The signature alone is not proof the wallpaper is on screen: a transient
# backend failure still used to write it, and an apply from skwd's own picker
# does not update it. Check the actual current wallpaper before taking the
# fast path, so a downloaded remote item can always be re-applied.
wallpaper_is_current() {
    if [[ "$SKWD" == 1 ]]; then
        command -v skwd-helm >/dev/null 2>&1 || return 1
        local target="${SKWD_TARGET#we:}"
        local cur line
        cur=$(skwd-helm current 2>/dev/null \
            | awk -F'\t' '$1 !~ /^HEADLESS/ && $2 != "" { print $2 }' || true)
        [ -n "$cur" ] || return 1
        while IFS= read -r line; do
            [[ "$line" == "$target" || "$line" == "$SKWD_TARGET" || "$line" == "$WALLPAPER" ]] || return 1
        done <<<"$cur"
        return 0
    fi
    [[ "$(cat "$CURRENT_WALL_FILE" 2>/dev/null || true)" == "$WALLPAPER" ]]
}

# ── fast path: the same wallpaper + mode + theme is already fully applied ───
# Only the matugen-relevant prefs count. The file is rewritten for unrelated
# settings (and every write changes its mtime), so a stat of the whole file
# would turn a fast re-select into a full repaint.
SIG=$(printf '%s|%s|%s|%s|%s|%s|%s|%s' \
    "$WALLPAPER" "$(stat_key "$WALLPAPER")" "$MODE" "$CURRENT_THEME" \
    "$(stat_key "$MATUGEN_CFG")" "$PREF_SIG" "$SKWD_TARGET" "$SKWD_LIVE_LABEL")
if [[ "${FORCE:-0}" != "1" && -n "$MODE" && "$CURRENT_THEME" == "matugen" \
        && "$(cat "$SIG_FILE" 2>/dev/null || true)" == "$SIG" \
        && -s "$CACHE_DIR/quickshell/matugen.json" \
        && -s "$HOME/.config/hypr/colors.conf" \
        && -s "$HOME/.config/kitty/matugen-colors.conf" ]] \
        && wallpaper_is_current; then
    exit 0
fi

# Latest selection wins. Every later invocation overwrites this token; stale
# invocations exit before they can paint over the newer one.
TOKEN="$(date +%s%N)-$$"
printf '%s|%s|%s' "$TOKEN" "$WALLPAPER" "$MODE" >"$REQ_FILE.tmp"
mv -f "$REQ_FILE.tmp" "$REQ_FILE"

# Tell the shell which wallpaper this token belongs to, so depth/matte/mesh
# generation starts for this selection instead of waiting for skwd's output
# state to catch up. When a reveal is coming, the request is deferred until
# the circle has covered the screen (below): accepting it earlier makes the
# old 3D layer fade out while the iris is still growing, which is visible.
write_spatial_request() {
    [[ "${THEME_ONLY:-0}" != "1" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local req="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lucid-spatial-request.json"
    jq -n --arg p "$TARGET_LABEL" --arg t "$TOKEN" --argjson c "$(date +%s%3N)" \
        '{path:$p, token:$t, created:$c}' >"$req.tmp" \
        && mv -f "$req.tmp" "$req" || true
}
WILL_REVEAL=0
if [[ "$CURRENT_THEME" == "matugen" && "${THEME_ONLY:-0}" != "1" \
        && "${LUCID_SYNC_COMMIT:-1}" != "0" ]]; then
    WILL_REVEAL=1
fi
[[ "$WILL_REVEAL" == "1" ]] || write_spatial_request

# ── synchronized commit gate ────────────────────────────────────────────────
# If this image already has a cached source colour, we can align every visible
# change with OpenCode's built-in 1 s theme refresh. Start that timer now, wait
# until just before it fires, then let the wallpaper transition, palette and
# app surfaces all begin together. A never-seen image cannot be aligned without
# adding a full second after its decode, so it keeps the normal fast path.
EARLY_SENT=0
EARLY_SOURCE_KEY=""
# Grow the iris without waiting for the brightness decode, the cache keys or
# the seed: none of them are needed to show the picture inside the circle.
start_reveal() {
    [[ "$REVEALING" == "1" ]] && return 0
    REVEALING=1
    EARLY_SENT=1
    printf '1' >"$REVEAL_FLAG"
    reveal_heartbeat_start
    is_current || exit 0
    # Clear markers before the trigger. A stale reveal-covered from the
    # previous animation otherwise lets the palette write immediately.
    rm -f "$REVEAL_READY" "$REVEAL_COVERED"
    reveal_write in
}
if [[ "$CURRENT_THEME" == "matugen" && "${THEME_ONLY:-0}" != "1" \
        && "${LUCID_SYNC_COMMIT:-1}" != "0" ]]; then
    # The reveal needs the picture, not the brightness answer. Decode the
    # picture first, then measure while the circle grows; running both large
    # decodes at once only makes a low-power device slower.
    if [[ -z "$MODE" ]]; then
        start_reveal
        wait_reveal_ready
        is_current || exit 0
        detect_mode
    fi
    EARLY_SOURCE_KEY=$(printf '%s|%s|%s' "$WALLPAPER" "$(stat_key "$WALLPAPER")" \
        "$(stat_key "$MATUGEN_CFG")" | sha1sum | cut -d' ' -f1)
    EARLY_SCHEME=$(jq -r '.matugenScheme // "scheme-tonal-spot"' "$PREFS" 2>/dev/null || echo scheme-tonal-spot)
    EARLY_CONTRAST=$(jq -r '.matugenContrast // 0' "$PREFS" 2>/dev/null || echo 0)
    EARLY_SCHEME_KEY=$(printf '%s|%s|%s|%s|%s|%s' "$WALLPAPER" "$(stat_key "$WALLPAPER")" \
        "$MODE" "$EARLY_SCHEME" "$EARLY_CONTRAST" "$(stat_key "$MATUGEN_CFG")" | sha1sum | cut -d' ' -f1)
    CACHED=0
    [[ -s "$SOURCE_DIR/$EARLY_SOURCE_KEY" || -s "$SCHEME_DIR/$EARLY_SCHEME_KEY.json" ]] && CACHED=1

    # A cached image can afford to precompute its seed before the OpenCode
    # timer starts. A never-seen image cannot: the circle must start first, and
    # the seed/app-surface work happens under it.
    if [[ "$CACHED" == "1" ]]; then
        SEED_KEY="$WALLPAPER|$(stat_key "$WALLPAPER")"
        if [[ ! -f "$CACHE_DIR/quickshell/surface-seed.key" \
                || "$(cat "$CACHE_DIR/quickshell/surface-seed.key" 2>/dev/null)" != "$SEED_KEY" ]]; then
            SEED_THUMB_DIR="$CACHE_DIR/lucid/wallpaper-thumbs/680x422"
            SEED_THUMB_KEY=$(stat -c '%i-%s-%T@' "$WALLPAPER" 2>/dev/null || true)
            SEED_THUMB="$SEED_THUMB_DIR/$SEED_THUMB_KEY.jpg"
            [ -f "$SEED_THUMB" ] || SEED_THUMB=""
            "$PYTHON" "$LUCID_DIR/surface-seed.py" "$WALLPAPER" \
                "$CACHE_DIR/quickshell/matugen.json" "$CACHE_DIR/quickshell/surface-seed.json" \
                "$SEED_KEY" "$SEED_THUMB" >/dev/null 2>&1 || true
        fi
    fi

    start_reveal
    wait_reveal_ready
    is_current || exit 0
    # Do not touch the live wallpaper or palette until the iris has finished
    # growing. That is the whole point: the old desktop stays visible outside
    # the growing circle, and every colour change happens under full cover.
    wait_reveal_covered
    is_current || exit 0
    # Only now hand the new path to the spatial layer. Accepting it before the
    # cover made the old 3D wallpaper fade out under the growing circle, where
    # it could still be seen.
    write_spatial_request
fi

# Themes other than matugen skip the block above but still tag the mode files.
detect_mode
[[ "$MODE" == "light" || "$MODE" == "dark" ]] || { echo "error: mode must be dark or light (got: $MODE)" >&2; exit 1; }


# ── wallpaper ───────────────────────────────────────────────────────────────
# Start the transition in parallel with the palette work. The two have no
# dependency on each other: awww owns the screen, matugen owns the colours.
# The wallpaper lock is still taken inside the job, so a newer pick waits at
# most one transition and then becomes the one left on screen.
WP_PID=""

# Lucid's own depth engine can give a scene's static background a fixed
# parallax. unpack + classify the scene, then write the sidecar the patched
# skwd renderer reads when it starts. The result is cached beside the depth
# map, so this is instant after the first apply. Non-static scenes get no
# sidecar and keep skwd's normal renderer.
prepare_scene_depth() {
    [[ "$SKWD" == 1 && "$SKWD_TARGET" == we:* ]] || return 0
    local scene="${SKWD_TARGET#we:}"
    local dir="$CACHE_DIR/liquid-shell/we-depth"
    local script="$HOME/.config/quickshell/luciddocks/we-scene.py"
    [[ -n "$scene" && -x "$script" ]] || return 0
    local spatial
    spatial=$(jq -r '.spatialWallpapers // true' "$PREFS" 2>/dev/null || echo true)
    if [[ "$spatial" != "true" ]]; then
        rm -f "$dir/$scene.json"
        return 0
    fi
    # A cold depth model can take a while; never wedge the iris on it.
    timeout 70 /usr/bin/python3 "$script" --scene "$scene" --prepare-depth >/dev/null 2>&1 || true
}

# A freshly installed Workshop scene exists on disk before skwd's library has
# scanned it. `skwd-helm apply we:<id>` then says "not found" and the first
# click leaves the old wallpaper up (the second click works). Wait for the key
# the download just created, but never block a selection the user has left.
wait_skwd_target() {
    [[ "$SKWD" == 1 && "$SKWD_TARGET" == we:* ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local scene="${SKWD_TARGET#we:}"
    local dir="$HOME/.local/share/Steam/steamapps/workshop/content/431960/$scene"
    [ -d "$dir" ] || return 0
    local i
    for i in {1..60}; do
        is_current || return 0
        if skwd-helm list --json 2>/dev/null \
                | jq -e --arg k "$SKWD_TARGET" '.wallpapers[]? | select(.key == $k)' >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.25
    done
    return 0
}
wait_skwd_target
# The iris stays closed until the spatial layer has its first usable frame.
# Without this the geometric wallpaper pops in after the circle has gone.
wait_spatial_ready() {
    [[ "${REVEALING:-0}" == "1" ]] || return 0
    [[ "${THEME_ONLY:-0}" != "1" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -e '.spatialWallpapers // true' "$PREFS" >/dev/null 2>&1 || return 0

    local file="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lucid-spatial-ready.json"
    local target="$TARGET_LABEL"
    local i
    # 26 s: a cold 4K still needs depth + matte + two mesh builds, and the cover
    # must not open halfway through that. A generation that failed reports its
    # error under the same token and releases the wait instead.
    for i in {1..260}; do
        is_current || return 0
        if [[ -f "$file" ]]; then
            # An empty token means the shell re-read its request file too late
            # (a restart during the apply) and could not echo it back; the path
            # still proves the spatial layer is showing this wallpaper.
            if jq -e --arg p "$target" --arg t "$TOKEN"                     '.path == $p and .ready == true and (.token == $t or .token == "")' "$file" >/dev/null 2>&1; then
                # one compositor frame under the cover, so the first mesh frame is
                # already presented when the iris opens
                sleep 0.07
                return 0
            fi
            if jq -e --arg p "$target" --arg t "$TOKEN"                     '.path == $p and .token == $t and (.error // "") != ""' "$file" >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 0.1
    done
    return 0
}

wait_wallpaper() {
    # skwd's apply RPC is synchronous: it returns after the render handoff, and
    # a Workshop scene's handoff is part of the same call. Polling `current`
    # afterwards added seconds (and could never match on a lagging output), so
    # the client's own completion is the whole wait.
    if [[ -n "${WP_PID:-}" ]]; then
        wait "$WP_PID" 2>/dev/null || true
        WP_PID=""
    fi
}

wait_fanout() {
    # The palette files are written before this; the fanout is what tells the
    # apps (kitty, hypr borders, opencode, discord) to read them. Keep the iris
    # up until that has actually happened, but never wait forever: a fanout
    # wedged on a FIFO or an app signal used to hold the circle until the
    # shell's 90 s deadline, and the still-running heartbeat then disabled the
    # reveal watchdog for later applies. The loop above is the cap; the waits
    # below must not undo it.
    [[ -n "${FANOUT_PID:-}" ]] || return 0
    local i
    for i in {1..50}; do
        kill -0 "$FANOUT_PID" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$FANOUT_PID" 2>/dev/null; then
        kill "$FANOUT_PID" 2>/dev/null || true
        sleep 0.1
        kill -9 "$FANOUT_PID" 2>/dev/null || true
    fi
    wait "$FANOUT_PID" 2>/dev/null || true
    FANOUT_PID=""
}
if [[ "${THEME_ONLY:-0}" != "1" ]]; then
    if [[ "$SKWD" == 1 ]]; then
        # skwd's daemon renders the wallpaper on the background layer and keeps
        # its own transition; the lock keeps a burst of picks in order
        (
            exec 8>"$CACHE_DIR/lucid/wallpaper.lock"
            flock 8
            if is_current; then
                prepare_scene_depth
                # A scene-to-scene swap reuses skwd's shared scene renderer,
                # and that renderer keeps the first scene's canvas size. Going
                # from a 320x200 pixel-art scene to a 4K one then shows the 4K
                # scene at 320x200. A still in between rebuilds the presenter;
                # it stays under the reveal cover, and the scene follows at
                # its own native resolution.
                if [[ "$SKWD_TARGET" == we:* ]]; then
                    prev=$(skwd-helm current 2>/dev/null \
                        | awk -F'\t' '$1 !~ /^HEADLESS/ && $2 ~ /^[0-9]+$/ { print $2; exit }' || true)
                    if [[ -n "$prev" && "$prev" != "${SKWD_TARGET#we:}" ]]; then
                        skwd-helm apply "$WALLPAPER" >/dev/null 2>&1 || true
                    fi
                fi
                # A daemon that is still finishing the previous transition can
                # reject one request. It can also answer success while the
                # visible output is still the still frame put in for the scene
                # renderer reset; for a Workshop scene, require `current` to
                # name that scene's id, not just a successful RPC.
                applied=0
                for _attempt in 1 2 3 4 5 6 7 8; do
                    if skwd-helm apply "$SKWD_TARGET" >/dev/null 2>&1; then
                        if [[ "$SKWD_TARGET" != we:* ]]; then
                            applied=1
                            break
                        fi
                        _scene="${SKWD_TARGET#we:}"
                        _current=$(skwd-helm current 2>/dev/null \
                            | awk -F'\t' '$1 !~ /^HEADLESS/ && $2 ~ /^[0-9]+$/ { print $2; exit }' || true)
                        if [[ "$_current" == "$_scene" ]]; then
                            applied=1
                            break
                        fi
                    fi
                    sleep 0.2
                done
                [[ "$applied" == "1" ]] \
                    || echo "warning: skwd could not apply $SKWD_TARGET" >&2
            fi
            flock -u 8
        ) &
        WP_PID=$!
    else
        if command -v awww &>/dev/null; then
            WP_CLI=awww; WP_DAEMON=awww-daemon
        elif command -v swww &>/dev/null; then
            WP_CLI=swww; WP_DAEMON=swww-daemon
        else
            echo "error: neither awww nor swww is installed" >&2
            exit 1
        fi
        if ! "$WP_CLI" query &>/dev/null; then
            "$WP_DAEMON" &>/dev/null &
            sleep 0.5
        fi
        (
            exec 8>"$CACHE_DIR/lucid/wallpaper.lock"
            flock 8
            if is_current; then
                if [[ "$REVEALING" == "1" ]]; then
                    "$WP_CLI" img "$WALLPAPER" --transition-type none 2>/dev/null || \
                        "$WP_CLI" img "$WALLPAPER" 2>/dev/null || true
                else
                    "$WP_CLI" img "$WALLPAPER" \
                        --transition-type fade --transition-duration 1 --transition-fps 60 2>/dev/null || \
                        "$WP_CLI" img "$WALLPAPER" 2>/dev/null || true
                fi
            fi
            flock -u 8
        ) &
        WP_PID=$!
    fi
fi
is_current || exit 0

# sync theme_mode for the kitty/quickshell watchers (both explicit and auto)
touch /tmp/matugen-theme-toggle.lock
OLD_MODE="$(cat "$CACHE_DIR/current_mode" 2>/dev/null || true)"
write_if_diff "$CACHE_DIR/quickshell/theme_mode" "$MODE"
write_if_diff "$CACHE_DIR/current_mode" "$MODE"
write_if_diff "$CACHE_DIR/hypr_last_wallpaper_mode" "$MODE"
if command -v gsettings >/dev/null 2>&1 && [[ "$OLD_MODE" != "$MODE" ]]; then
    if [[ "$MODE" == "light" ]]; then
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-light' 2>/dev/null || true
    else
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
    fi
fi
if [[ -n "$CONFIG_MODE" && -z "$EXPLICIT_MODE" ]]; then
    echo "→ wallpaper config for $TARGET_LABEL → $MODE"
elif [[ -z "$EXPLICIT_MODE" ]]; then
    echo "→ measured dark-area for $TARGET_LABEL → $MODE"
fi

# ── palette ─────────────────────────────────────────────────────────────────
case "$CURRENT_THEME" in
matugen)
    if ! command -v matugen &>/dev/null; then
        echo "warning: matugen not installed, colours unchanged" >&2
        exit 0
    fi

    # Scheme options come from prefs, with the same validation as the rest of
    # Lucid. Source index is intentionally not forced: an explicit index
    # bypasses config.prefer and pins index 0, which picks a cyan background
    # over a red subject (observed live).
    MATUGEN_SCHEME="$(jq -r '.matugenScheme // empty' "$PREFS" 2>/dev/null || true)"
    case "$MATUGEN_SCHEME" in
    scheme-content | scheme-expressive | scheme-fidelity | scheme-fruit-salad | \
        scheme-monochrome | scheme-neutral | scheme-rainbow | scheme-tonal-spot | scheme-vibrant) ;;
    *) MATUGEN_SCHEME=scheme-tonal-spot ;;
    esac
    MATUGEN_CONTRAST="$(jq -r '.matugenContrast // empty' "$PREFS" 2>/dev/null || true)"
    if ! [[ "$MATUGEN_CONTRAST" =~ ^-?([0-9]+\.?[0-9]*|\.[0-9]+)$ ]] ||
            awk -v c="$MATUGEN_CONTRAST" 'BEGIN { exit !(c < -1 || c > 1) }'; then
        MATUGEN_CONTRAST=0
    fi

    SCHEME_KEY=$(printf '%s|%s|%s|%s|%s|%s' \
        "$WALLPAPER" "$(stat_key "$WALLPAPER")" "$MODE" "$MATUGEN_SCHEME" \
        "$MATUGEN_CONTRAST" "$(stat_key "$MATUGEN_CFG")" | sha1sum | cut -d' ' -f1)
    SCHEME_FILE="$SCHEME_DIR/$SCHEME_KEY.json"
    SOURCE_KEY=$(printf '%s|%s|%s' "$WALLPAPER" "$(stat_key "$WALLPAPER")" \
        "$(stat_key "$MATUGEN_CFG")" | sha1sum | cut -d' ' -f1)
    SOURCE_FILE="$SOURCE_DIR/$SOURCE_KEY"

    # Cached scheme/source means the final theme will be ready well inside
    # OpenCode's 1 s refresh window. Start that window now, before the render,
    # so a normal wallpaper/mode change lands in ~1 s rather than 2-3 s.
    if [[ "$EARLY_SENT" != "1" && "${THEME_ONLY:-0}" != "1" ]] \
            && { [[ -s "$SCHEME_FILE" ]] || [[ -s "$SOURCE_FILE" ]]; }; then
        # Sync disabled (or a source that only had a scheme): start OpenCode's
        # timer now; the rest of the pipeline stays on its normal timing.
        "$LUCID_DIR/opencode-theme-notify.sh" --early >/dev/null 2>&1 || true
    fi

    # Browsing debounce: the wallpaper itself is already on screen, so there
    # is no reason to spend 0.2-1.5 s decoding an image the user has already
    # arrowed past. A selection must stay current for 120 ms before it gets a
    # scheme. Explicit mode changes (the toggle) skip this.
    if [[ -z "$EXPLICIT_MODE" ]]; then
        sleep 0.12
        is_current || exit 0
    fi

    # One decode at a time. The newest selection checks its token again after
    # acquiring the lock, so an older image cannot spend seconds decoding for
    # a wallpaper the user already left.
    exec 6>"$CACHE_DIR/lucid/scheme.lock"
    flock 6
    if ! is_current; then
        flock -u 6
        exit 0
    fi
    if [[ ! -s "$SCHEME_FILE" ]]; then
        tmp="$(mktemp "$SCHEME_DIR/.scheme-XXXXXX")"
        # Once an image has been decoded, its source colour is enough to build
        # that image in any other mode/scheme/contrast: matugen color hex is
        # ~6 ms, while decoding a 4K PNG for every light/dark flip is ~1 s.
        if [[ -s "$SOURCE_FILE" ]] && command -v jq >/dev/null 2>&1; then
            if matugen color hex "$(cat "$SOURCE_FILE")" -m "$MODE" -t "$MATUGEN_SCHEME" \
                    --contrast "$MATUGEN_CONTRAST" --dry-run --json hex -q 2>/dev/null |
                    jq --arg image "$WALLPAPER" '.image = $image' >"$tmp" 2>/dev/null; then
                mv -f "$tmp" "$SCHEME_FILE"
            else
                rm -f "$tmp"
            fi
        fi
        if [[ ! -s "$SCHEME_FILE" ]]; then
            if matugen image "$WALLPAPER" -m "$MODE" -t "$MATUGEN_SCHEME" \
                    --contrast "$MATUGEN_CONTRAST" --dry-run --json hex -q >"$tmp" 2>/dev/null; then
                mv -f "$tmp" "$SCHEME_FILE"
                if command -v jq >/dev/null 2>&1; then
                    jq -r '.colors.source_color.default.color // empty' "$SCHEME_FILE" \
                        >"$SOURCE_FILE.tmp" 2>/dev/null && mv -f "$SOURCE_FILE.tmp" "$SOURCE_FILE"
                fi
            else
                rm -f "$tmp"
                # fall back to matugen's normal path so a cache write failure can
                # never leave colours unchanged. A broken template must not take
                # the whole apply (and the reveal) down with it.
                if ! matugen image "$WALLPAPER" -m "$MODE" -t "$MATUGEN_SCHEME" --contrast "$MATUGEN_CONTRAST"; then
                    echo "warning: matugen could not render the palette; colours may be stale" >&2
                fi
                "$LUCID_DIR/app-surface-sync.sh" >/dev/null 2>&1 || true
                "$LUCID_DIR/opencode-theme-notify.sh" >/dev/null 2>&1 || true
                SCHEME_FILE=""
            fi
        fi
        find "$SCHEME_DIR" -type f -mtime +30 -delete 2>/dev/null || true
        find "$SOURCE_DIR" -type f -mtime +60 -delete 2>/dev/null || true
    fi
    flock -u 6

    is_current || exit 0
    if [[ -n "$SCHEME_FILE" ]]; then
        # Publish lock: newest selection wins even if an older decode finished
        # later. The render itself is ~30-50 ms, so this never blocks the UI.
        exec 7>"$CACHE_DIR/lucid/publish.lock"
        flock 7
        if ! is_current; then
            flock -u 7
            exit 0
        fi
        [[ "${THEME_ONLY:-0}" != "1" ]] && write_restore_state
        # matugen json renders every configured template in one process and is
        # byte-identical to `image` for the same scheme. No post_hooks: the
        # fanout below is the single delivery point.
        # A single unwritable template (e.g. a root-owned app config) must not
        # abort the apply: that used to leave the iris to the heartbeat
        # watchdog, which opened the circle before the wallpaper and spatial
        # layer had finished. Keep going with whatever templates did render.
        if ! matugen -c "$MATUGEN_CFG" json "$SCHEME_FILE" -m "$MODE" -q; then
            echo "warning: matugen could not render every template; colours may be partly stale" >&2
        fi

        # Finish the shared app surface now, before the fanout's settle window.
        # The later fanout call is a fast no-op.
        "$LUCID_DIR/app-surface-sync.sh" >/dev/null 2>&1 || true
        "$LUCID_DIR/opencode-theme-notify.sh" >/dev/null 2>&1 || true

        # one pass over kitty's palette (soften + saturate), no signals here
        TUNE_KEY=$(sha1sum "$HOME/.config/kitty/matugen-colors.conf" \
            "$CACHE_DIR/quickshell/matugen.json" 2>/dev/null | sha1sum | cut -d' ' -f1)
        if [[ "$(cat "$CACHE_DIR/lucid/kitty-tune.key" 2>/dev/null || true)" != "$TUNE_KEY" ]]; then
            "$PYTHON" "$LUCID_DIR/kitty-tune.py" \
                "$HOME/.config/kitty/matugen-colors.conf" \
                "$CACHE_DIR/quickshell/matugen.json" "$MODE" >/dev/null 2>&1 || true
            printf '%s' "$TUNE_KEY" >"$CACHE_DIR/lucid/kitty-tune.key.tmp"
            mv -f "$CACHE_DIR/lucid/kitty-tune.key.tmp" "$CACHE_DIR/lucid/kitty-tune.key"
        fi
        printf '%s' "$SIG" >"$SIG_FILE.tmp" && mv -f "$SIG_FILE.tmp" "$SIG_FILE"
        flock -u 7
        # Deliver the palette now, while the iris is fully closed. The fanout
        # only recolours the bar/dock and reads the palette file, so it does not
        # need to wait for the wallpaper; running it here means a slow wallpaper
        # apply hides the colour commit too, while a fast one still opens the
        # iris immediately.
        THEME_SETTLE_MS=50 "$LUCID_DIR/theme-fanout.sh" --request >/dev/null 2>&1 &
        FANOUT_PID=$!
        wait_wallpaper
        wait_spatial_ready
        # The apps are told about the new palette here, still under the circle.
        # It used to be waited for after "out", so kitty/hypr/opencode could
        # visibly recolour after the iris had already opened.
        wait_fanout
        # Only the selection that still owns the screen may open it. A newer
        # pick is already staging its own reveal; closing this one would flash
        # the desktop before the new circle grows.
        if [[ "$REVEALING" == "1" ]]; then
            if is_current; then
                reveal_write out
                printf '0' >"$REVEAL_FLAG"
            fi
            reveal_heartbeat_stop
            REVEALING=0
        fi
    else
        # The scheme-cache write path failed but matugen's direct fallback
        # succeeded; still deliver the side effects once.
        printf '%s' "$SIG" >"$SIG_FILE.tmp" && mv -f "$SIG_FILE.tmp" "$SIG_FILE"
        wait_wallpaper
        wait_spatial_ready
        ( setsid "$LUCID_DIR/theme-fanout.sh" --request >/dev/null 2>&1 < /dev/null & ) 2>/dev/null || true
        # The exit trap closes the iris for this fallback path.
    fi
    ;;
pywal)
    if ! command -v wal &>/dev/null; then
        echo "warning: pywal not installed, colours unchanged" >&2
        exit 0
    fi
    if [[ -z "$EXPLICIT_MODE" ]]; then
        sleep 0.12
        is_current || exit 0
    fi
    exec 7>"$CACHE_DIR/lucid/publish.lock"
    flock 7
    is_current || { flock -u 7; exit 0; }
    [[ "${THEME_ONLY:-0}" != "1" ]] && write_restore_state
    wal -i "$WALLPAPER" -n -s -t -e -q || echo "warning: wal failed" >&2
    wait_wallpaper
    if "$LUCID_DIR/gen-pywal-palette.py"; then
        "$LUCID_DIR/apply-theme.sh" pywal
    else
        echo "warning: pywal palette generation failed" >&2
    fi
    flock -u 7
    ;;
*)
    exec 7>"$CACHE_DIR/lucid/publish.lock"
    flock 7
    is_current || { flock -u 7; exit 0; }
    [[ "${THEME_ONLY:-0}" != "1" ]] && write_restore_state
    flock -u 7
    wait_wallpaper
    echo "static theme ($CURRENT_THEME) — colours unchanged"
    ;;
esac

# ── live preview ────────────────────────────────────────────────────────────
# After an animated wallpaper has settled, keep 10s of it. The picker card
# uses the GIF, and the iris uses the full-size frame from that recording.
# Best-effort and detached: it must never delay the apply.
if [[ "$SKWD" == 1 && "${THEME_ONLY:-0}" != "1" && -n "$LIVE_KEY" && -x "$LIVE_CAPTURE" ]]; then
    if [[ "$LIVE_KIND" == "we" ]]; then
        ( setsid "$LIVE_CAPTURE" "$LIVE_KEY" we "" "$SKWD_LIVE_LABEL" "$TOKEN" >/dev/null 2>&1 < /dev/null & ) 2>/dev/null || true
    elif [[ "$LIVE_KIND" == "video" && -n "$LIVE_SOURCE" ]]; then
        ( setsid "$LIVE_CAPTURE" "$LIVE_KEY" video "$LIVE_SOURCE" "$SKWD_LIVE_LABEL" "$TOKEN" >/dev/null 2>&1 < /dev/null & ) 2>/dev/null || true
    fi
fi

if [[ "${THEME_ONLY:-0}" == "1" ]]; then
    echo "done: $TARGET_LABEL ($MODE, theme: $CURRENT_THEME, theme-only - wallpaper untouched)"
else
    echo "done: $TARGET_LABEL ($MODE, theme: $CURRENT_THEME)"
fi
