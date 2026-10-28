#!/usr/bin/env bash
# set-wallpaper.sh <path-to-image> [dark|light]
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

if [[ "$WALLPAPER" == skwd:* ]]; then
    [[ "$SKWD" == 1 ]] || { echo "error: skwd-wall is not enabled" >&2; exit 1; }
    SKWD_TARGET="${WALLPAPER#skwd:}"
    SKWD_LIVE_LABEL="$WALLPAPER"
    if [[ -z "$SKWD_SAMPLE" || ! -f "$SKWD_SAMPLE" ]]; then
        command -v jq >/dev/null 2>&1 || { echo "error: jq is needed to sample a scene" >&2; exit 1; }
        SKWD_SAMPLE=$(skwd-helm list --json 2>/dev/null \
            | jq -r --arg k "$SKWD_TARGET" '.wallpapers[]? | select(.key == $k) | (.thumb // .preview // empty)' 2>/dev/null \
            | head -n1)
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
REVEALING=0
reveal_write() { # $1 = in|out
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg id "$TOKEN" --arg path "$WALLPAPER" --arg phase "$1" \
            '{id:$id, path:$path, phase:$phase}' >"$REVEAL_FILE"
    else
        printf '{"id":"%s","path":"%s","phase":"%s"}\n' "$TOKEN" "$WALLPAPER" "$1" >"$REVEAL_FILE"
    fi
}
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
# A wallpaper's brightness does not change while its mtime/size are unchanged,
# so cache the answer. This removes an ffmpeg decode from every re-select and
# from every mode toggle.
if [[ -n "$EXPLICIT_MODE" ]]; then
    MODE="$EXPLICIT_MODE"
else
    MODE_KEY=$(printf '%s|%s' "$WALLPAPER" "$(stat_key "$WALLPAPER")" | sha1sum | cut -d' ' -f1)
    MODE_CACHE="$CACHE_DIR/lucid/wallpaper-mode/$MODE_KEY"
    if [[ -f "$MODE_CACHE" ]]; then
        MODE="$(cat "$MODE_CACHE")"
    else
        MODE="dark"
        if command -v ffmpeg >/dev/null 2>&1; then
            ffmpeg -y -i "$WALLPAPER" -vf "scale=64:64:flags=area" -f rawvideo -pix_fmt rgb24 "$CACHE_DIR/lucid/.wallgrid.rgb" 2>/dev/null || true
            MODE=$(python3 - << 'PY' 2>/dev/null || echo dark
import os
p=os.path.expanduser('~/.cache/lucid/.wallgrid.rgb')
try:
    d=open(p,'rb').read(); n=len(d)//3
    if n==0:
        print('dark')
    else:
        dark=sum(1 for i in range(n) if 0.2126*d[3*i]+0.7152*d[3*i+1]+0.0722*d[3*i+2] < 100)
        print('dark' if dark/n >= 0.25 else 'light')
except Exception:
    print('dark')
PY
)
        fi
        [[ "$MODE" != "light" && "$MODE" != "dark" ]] && MODE="dark"
        mkdir -p "$(dirname "$MODE_CACHE")"
        printf '%s' "$MODE" >"$MODE_CACHE.tmp" && mv -f "$MODE_CACHE.tmp" "$MODE_CACHE"
        find "$CACHE_DIR/lucid/wallpaper-mode" -type f -mtime +60 -delete 2>/dev/null || true
    fi
fi
[[ "$MODE" == "light" || "$MODE" == "dark" ]] || { echo "error: mode must be dark or light (got: $MODE)" >&2; exit 1; }

# ── fast path: the same wallpaper + mode + theme is already fully applied ───
# Only the matugen-relevant prefs count. The file is rewritten for unrelated
# settings (and every write changes its mtime), so a stat of the whole file
# would turn a fast re-select into a full repaint.
SIG=$(printf '%s|%s|%s|%s|%s|%s|%s|%s' \
    "$WALLPAPER" "$(stat_key "$WALLPAPER")" "$MODE" "$CURRENT_THEME" \
    "$(stat_key "$MATUGEN_CFG")" "$PREF_SIG" "$SKWD_TARGET" "$SKWD_LIVE_LABEL")
if [[ "${FORCE:-0}" != "1" && "$CURRENT_THEME" == "matugen" \
        && "$(cat "$SIG_FILE" 2>/dev/null || true)" == "$SIG" \
        && -s "$CACHE_DIR/quickshell/matugen.json" \
        && -s "$HOME/.config/hypr/colors.conf" \
        && -s "$HOME/.config/kitty/matugen-colors.conf" ]]; then
    exit 0
fi

# Latest selection wins. Every later invocation overwrites this token; stale
# invocations exit before they can paint over the newer one.
TOKEN="$(date +%s%N)-$$"
COMMIT_AT_NS=""
printf '%s|%s|%s' "$TOKEN" "$WALLPAPER" "$MODE" >"$REQ_FILE.tmp"
mv -f "$REQ_FILE.tmp" "$REQ_FILE"

# ── synchronized commit gate ────────────────────────────────────────────────
# If this image already has a cached source colour, we can align every visible
# change with OpenCode's built-in 1 s theme refresh. Start that timer now, wait
# until just before it fires, then let the wallpaper transition, palette and
# app surfaces all begin together. A never-seen image cannot be aligned without
# adding a full second after its decode, so it keeps the normal fast path.
EARLY_SENT=0
EARLY_SOURCE_KEY=""
if [[ "$CURRENT_THEME" == "matugen" && "${THEME_ONLY:-0}" != "1" \
        && "${LUCID_SYNC_COMMIT:-1}" != "0" ]]; then
    EARLY_SOURCE_KEY=$(printf '%s|%s|%s' "$WALLPAPER" "$(stat_key "$WALLPAPER")" \
        "$(stat_key "$MATUGEN_CFG")" | sha1sum | cut -d' ' -f1)
    EARLY_SCHEME=$(jq -r '.matugenScheme // "scheme-tonal-spot"' "$PREFS" 2>/dev/null || echo scheme-tonal-spot)
    EARLY_CONTRAST=$(jq -r '.matugenContrast // 0' "$PREFS" 2>/dev/null || echo 0)
    EARLY_SCHEME_KEY=$(printf '%s|%s|%s|%s|%s|%s' "$WALLPAPER" "$(stat_key "$WALLPAPER")" \
        "$MODE" "$EARLY_SCHEME" "$EARLY_CONTRAST" "$(stat_key "$MATUGEN_CFG")" | sha1sum | cut -d' ' -f1)
    if [[ -s "$SOURCE_DIR/$EARLY_SOURCE_KEY" || -s "$SCHEME_DIR/$EARLY_SCHEME_KEY.json" ]]; then
        "$LUCID_DIR/opencode-theme-notify.sh" --early >/dev/null 2>&1 || true
        EARLY_SENT=1
        COMMIT_AT_NS=$(( $(date +%s%N) + 1000000000 ))
        REVEALING=1
        printf '1' >"$REVEAL_FLAG"
        reveal_at=$(( COMMIT_AT_NS - 800000000 ))
        now=$(date +%s%N)
        if (( reveal_at > now )); then
            sleep "$(awk -v ns="$((reveal_at - now))" 'BEGIN { printf "%.3f", ns / 1000000000 }')"
        fi
        is_current || exit 0
        reveal_write in
        target=$(( COMMIT_AT_NS - 450000000 ))
        now=$(date +%s%N)
        if (( target > now )); then
            sleep "$(awk -v ns="$((target - now))" 'BEGIN { printf "%.3f", ns / 1000000000 }')"
        fi
        is_current || exit 0
    fi
fi

# ── wallpaper ───────────────────────────────────────────────────────────────
# Start the transition in parallel with the palette work. The two have no
# dependency on each other: awww owns the screen, matugen owns the colours.
# The wallpaper lock is still taken inside the job, so a newer pick waits at
# most one transition and then becomes the one left on screen.
WP_PID=""
wait_wallpaper() {
    # skwd renders the handoff asynchronously and the palette does not depend
    # on it; waiting here only delayed the app colours by the renderer's start.
    if [[ "$SKWD" == 1 ]]; then
        WP_PID=""
        return 0
    fi
    if [[ -n "${WP_PID:-}" ]]; then
        wait "$WP_PID" 2>/dev/null || true
        WP_PID=""
    fi
}
if [[ "${THEME_ONLY:-0}" != "1" ]]; then
    if [[ "$SKWD" == 1 ]]; then
        # skwd's daemon renders the wallpaper on the background layer and keeps
        # its own transition; the lock keeps a burst of picks in order
        (
            exec 8>"$CACHE_DIR/lucid/wallpaper.lock"
            flock 8
            if is_current; then
                skwd-helm apply "$SKWD_TARGET" >/dev/null 2>&1 \
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
if [[ -z "$EXPLICIT_MODE" ]]; then
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
                # never leave colours unchanged
                matugen image "$WALLPAPER" -m "$MODE" -t "$MATUGEN_SCHEME" --contrast "$MATUGEN_CONTRAST"
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
        matugen -c "$MATUGEN_CFG" json "$SCHEME_FILE" -m "$MODE" -q

        # Finish the shared app surface now, before the fanout's 250 ms settle
        # window. This pins the OpenCode theme to bgOpaque and starts its 1 s
        # refresh timer as early as the final file exists. The later fanout
        # call is a fast no-op.
        "$LUCID_DIR/app-surface-sync.sh" >/dev/null 2>&1 || true
        "$LUCID_DIR/opencode-theme-notify.sh" >/dev/null 2>&1 || true

        # one pass over kitty's palette (soften + saturate), no signals here
        TUNE_KEY=$(sha1sum "$HOME/.config/kitty/matugen-colors.conf" \
            "$CACHE_DIR/quickshell/matugen.json" 2>/dev/null | sha1sum | cut -d' ' -f1)
        if [[ "$(cat "$CACHE_DIR/lucid/kitty-tune.key" 2>/dev/null || true)" != "$TUNE_KEY" ]]; then
            python3 "$LUCID_DIR/kitty-tune.py" \
                "$HOME/.config/kitty/matugen-colors.conf" \
                "$CACHE_DIR/quickshell/matugen.json" "$MODE" >/dev/null 2>&1 || true
            printf '%s' "$TUNE_KEY" >"$CACHE_DIR/lucid/kitty-tune.key.tmp"
            mv -f "$CACHE_DIR/lucid/kitty-tune.key.tmp" "$CACHE_DIR/lucid/kitty-tune.key"
        fi
        printf '%s' "$SIG" >"$SIG_FILE.tmp" && mv -f "$SIG_FILE.tmp" "$SIG_FILE"
        flock -u 7
        wait_wallpaper
        if [[ "$REVEALING" == "1" && -n "${COMMIT_AT_NS:-}" ]]; then
            target=$(( COMMIT_AT_NS + 50000000 ))
            now=$(date +%s%N)
            if (( target > now )); then
                sleep "$(awk -v ns="$((target - now))" 'BEGIN { printf "%.3f", ns / 1000000000 }')"
            fi
            reveal_write out
            printf '0' >"$REVEAL_FLAG"
        fi
        ( THEME_SETTLE_MS="${COMMIT_AT_NS:+0}" setsid "$LUCID_DIR/theme-fanout.sh" --request >/dev/null 2>&1 < /dev/null & ) 2>/dev/null || true
    else
        # The scheme-cache write path failed but matugen's direct fallback
        # succeeded; still deliver the side effects once.
        printf '%s' "$SIG" >"$SIG_FILE.tmp" && mv -f "$SIG_FILE.tmp" "$SIG_FILE"
        wait_wallpaper
        ( setsid "$LUCID_DIR/theme-fanout.sh" --request >/dev/null 2>&1 < /dev/null & ) 2>/dev/null || true
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

if [[ "${THEME_ONLY:-0}" == "1" ]]; then
    echo "done: $TARGET_LABEL ($MODE, theme: $CURRENT_THEME, theme-only - wallpaper untouched)"
else
    echo "done: $TARGET_LABEL ($MODE, theme: $CURRENT_THEME)"
fi
