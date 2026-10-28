#!/usr/bin/env bash
# opencode-theme-notify.sh [--early]
#
# Tell a running OpenCode TUI that the custom `matugen` theme changed. The TUI's
# built-in theme source listens for SIGUSR2, re-discovers ~/.config/opencode/themes,
# and swaps the resolved tokens in place. Do NOT call the plugin/theme `set()`
# API: that writes cli.json and makes OpenCode reconcile its whole config/plugin
# tree (the old 4 s reload).
#
# --early starts OpenCode's 1 s refresh window before the render when the scheme
# is already cached. The normal call then only updates the content hash, so it
# does not reset the timer. If the final write took longer than 900 ms, the
# normal call signals again rather than leaving the TUI on stale colours.
#
# `pkill -x` is essential: opencode.exe is the shared service and does NOT
# handle SIGUSR2; a plain `pkill opencode` terminates it and forces a full
# reconnect.
set -u
THEME="${1:-$HOME/.config/opencode/themes/matugen.json}"
HASH_FILE="$HOME/.cache/lucid/opencode-theme.hash"
EARLY_FILE="$HOME/.cache/lucid/opencode-early.stamp"
mkdir -p "$(dirname "$HASH_FILE")"

if [ "${1:-}" = "--early" ]; then
    date +%s%N >"$EARLY_FILE.tmp" && mv -f "$EARLY_FILE.tmp" "$EARLY_FILE"
    [ "${LUCID_PROFILE:-0}" = "1" ] && \
        printf '%s opencode early\n' "$(date '+%H:%M:%S.%3N')" >>"$HOME/.cache/lucid/fanout.log" || true
    pkill -x -SIGUSR2 opencode 2>/dev/null || true
    exit 0
fi

[ -s "$THEME" ] || exit 0

hash=$(sha1sum "$THEME" 2>/dev/null | cut -d' ' -f1)
[ -n "$hash" ] || exit 0
old=$(cat "$HASH_FILE" 2>/dev/null || true)
[ "$hash" = "$old" ] && { rm -f "$EARLY_FILE"; exit 0; }

printf '%s' "$hash" >"$HASH_FILE.tmp" && mv -f "$HASH_FILE.tmp" "$HASH_FILE"

skip_signal=0
if [ -f "$EARLY_FILE" ]; then
    stamp=$(cat "$EARLY_FILE" 2>/dev/null || echo 0)
    now=$(date +%s%N)
    if [ "$stamp" -gt 0 ] 2>/dev/null; then
        age_ms=$(( (now - stamp) / 1000000 ))
        [ "$age_ms" -lt 900 ] && skip_signal=1
    fi
    rm -f "$EARLY_FILE"
fi
[ "$skip_signal" = "1" ] && exit 0

[ "${LUCID_PROFILE:-0}" = "1" ] && \
    printf '%s opencode signal (%s)\n' "$(date '+%H:%M:%S.%3N')" "${hash:0:8}" >>"$HOME/.cache/lucid/fanout.log" || true
pkill -x -SIGUSR2 opencode 2>/dev/null || true
exit 0
