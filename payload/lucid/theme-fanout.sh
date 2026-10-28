#!/usr/bin/env bash
# theme-fanout.sh [--request]
#
# One place that tells applications the palette changed. matugen's templates
# are pure file writes now (no post_hook), so the side effects happen exactly
# once, after every output is final:
#
#   app-surface-sync.sh   kitty/GTK/opencode surface + soft-light wallpaper
#   hyprctl reload        borders/shadow colours (one reload, not three)
#   kitty SIGUSR1         one signal for every terminal (one, not four)
#   foot SIGUSR1
#   helium/chromugen fifo
#
# --request is the non-blocking entry point used by set-wallpaper.sh. It writes
# the current wallpaper/mode/theme as the desired state and returns immediately
# if another fanout owns the lock. The owner waits for a short quiet period,
# then applies only the newest request, so browsing twenty wallpapers costs one
# fanout, not twenty. That is the frequency half of the optimisation; the
# per-run work is the other half.

set -u

CACHE="$HOME/.cache/lucid"
REQ="$CACHE/fanout.request"
LOCK="$CACHE/fanout.lock"
STATE="$CACHE/fanout.state"
LOG="$CACHE/fanout.log"
SETTLE="${THEME_SETTLE_MS:-250}"   # milliseconds
mkdir -p "$CACHE"

profile() { [ "${LUCID_PROFILE:-0}" = "1" ] && printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" >>"$LOG" || true; }

snapshot() {
    printf '%s|%s|%s|%s' \
        "$(cat "$HOME/.cache/current_wallpaper" 2>/dev/null || true)" \
        "$(cat "$HOME/.cache/current_mode" 2>/dev/null || true)" \
        "$(cat "$HOME/.cache/current_theme" 2>/dev/null || true)" \
        "$(stat -c '%y' "$HOME/.config/quickshell/lucidprefs/prefs.json" 2>/dev/null || true)"
}

hash_of() { # $@ = files; empty/missing files are ignored
    local files=() f
    for f in "$@"; do [ -f "$f" ] && files+=("$f"); done
    ((${#files[@]})) || { printf 'none'; return; }
    sha1sum "${files[@]}" 2>/dev/null | sha1sum | cut -d' ' -f1
}

changed() { # $1 cache key, rest files; writes hash and returns 0 if changed
    local key="$1"; shift
    local h; h="$(hash_of "$@")"
    local old=""; [ -f "$CACHE/fanout.$key" ] && old="$(cat "$CACHE/fanout.$key")"
    if [ "$h" = "$old" ]; then return 1; fi
    printf '%s' "$h" >"$CACHE/fanout.$key"
    return 0
}

apply_once() {
    local t0 t1
    profile "apply start $(cat "$REQ" 2>/dev/null)"
    t0=$(date +%s%N)

    # the shell palette is already live (matugen wrote it before this was
    # requested); this is the apps' surface and the baked wallpaper wash
    "$HOME/.config/lucid/app-surface-sync.sh" >/dev/null 2>&1 || true

    if changed hypr \
            "$HOME/.config/hypr/colors.conf" \
            "$HOME/.config/hypr/colors.lua"; then
        t1=$(date +%s%N)
        hyprctl reload >/dev/null 2>&1 || true
        profile "hypr reload $(( ( $(date +%s%N) - t1 ) / 1000000 ))ms"
    fi

    if changed kitty \
            "$HOME/.config/kitty/matugen-colors.conf" \
            "$HOME/.config/kitty/font-mode.conf" \
            "$HOME/.config/kitty/lucid-surface.conf"; then
        t1=$(date +%s%N)
        pkill -SIGUSR1 kitty 2>/dev/null || true
        profile "kitty signal $(( ( $(date +%s%N) - t1 ) / 1000000 ))ms"
    fi

    if changed foot "$HOME/.config/foot/foot.ini.matugen"; then
        pkill -USR1 foot 2>/dev/null || true
    fi

    if changed helium "$HOME/.local/share/helium-matugen-theme/manifest.json"; then
        [ -p "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/chromugen.fifo" ] && \
            printf '1' > "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/chromugen.fifo" 2>/dev/null || true
    fi

    # app-surface-sync.sh has now pinned the OpenCode theme to the same
    # bgOpaque as kitty/GTK. Only now signal the TUI, so its 1 s refresh reads
    # the final file rather than matugen's raw surface role.
    "$HOME/.config/lucid/opencode-theme-notify.sh" >/dev/null 2>&1 || true

    profile "apply done $(( ( $(date +%s%N) - t0 ) / 1000000 ))ms"
}

MODE="${1:-}"
if [ "$MODE" = "--request" ]; then
    snapshot >"$REQ.tmp" && mv -f "$REQ.tmp" "$REQ"
    exec 9>"$LOCK"
    # Wait for the owner instead of dropping the request when it is in its
    # final apply. The UI never waits: this runs detached. A request that
    # lands during the owner's final check would otherwise be lost.
    flock -w 5 9 2>/dev/null || exit 0
else
    exec 9>"$LOCK"
    flock 9 2>/dev/null || exit 0
fi

# The first caller for a burst owns the lock. It waits until the request has
# been quiet for SETTLE ms, so a quick picker run collapses to its last choice.
while :; do
    sig="$(cat "$REQ" 2>/dev/null || snapshot)"
    [ -f "$REQ" ] || snapshot >"$REQ"
    [ "$sig" = "$(cat "$STATE" 2>/dev/null || true)" ] && break

    while :; do
        before="$(stat -c '%y' "$REQ" 2>/dev/null || true)"
        sleep "$(awk -v ms="$SETTLE" 'BEGIN { printf "%.3f", ms/1000 }')"
        after="$(stat -c '%y' "$REQ" 2>/dev/null || true)"
        [ "$before" = "$after" ] && break
    done

    sig="$(cat "$REQ" 2>/dev/null || snapshot)"
    [ "$sig" = "$(cat "$STATE" 2>/dev/null || true)" ] && break

    apply_once

    printf '%s' "$sig" >"$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
    # If another wallpaper landed while we were applying, go round once more
    # for the newest one; otherwise stop.
    [ "$(cat "$REQ" 2>/dev/null || true)" = "$sig" ] && break
done

exit 0
