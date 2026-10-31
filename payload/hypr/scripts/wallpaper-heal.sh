#!/bin/bash
# wallpaper-heal.sh - put the skwd wallpaper back when an output returns.
#
# skwd-walld reaps the renderer of every output that goes away (VT switch,
# DPMS, unplug, a mirror toggled off) and its hotplug reconcile never spawns a
# new one when the output comes back. The desktop then stays bare until a
# wallpaper is picked again. hyprland.lua calls this on hyprland.start and
# monitor.added: the two moments where the outputs Hyprland reports and the
# layer skwd draws on can disagree.
#
# Idempotent: it applies the last wallpaper only when a connected output has no
# skwd layer surface, so the daemon's own restore at login is left to finish.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK="$RUNTIME/skwd-wall-v2/wall.sock"
CACHE="$HOME/.cache/skwd-wall-v2"

# one heal per burst: a VT return adds every output at once, so three
# monitor.added events must not become three applies
exec 9>"$RUNTIME/skwd-wall-v2/heal.lock" 2>/dev/null || exit 0
flock -n 9 || exit 0

# awww owns the desktop when skwd is off; nothing to heal then
pref=$(jq -r 'if .skwdWall == false then "false" else "true" end' \
    "$HOME/.config/quickshell/lucidprefs/prefs.json" 2>/dev/null || true)
[ "$pref" = "false" ] && exit 0

# the daemon starts with the session and only creates the socket once the
# Wayland session is up, so a hyprland.start hook can arrive first
for _ in $(seq 1 20); do
    [ -S "$SOCK" ] && break
    sleep 0.25
done
[ -S "$SOCK" ] || exit 0

command -v skwd-helm >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# outputs skwd draws nothing on. The renderer maps one layer surface per
# output: namespace skwd-paper for a still, skwd-wall* for video/scene.
bare() { # $1 = JSON array of output names
    local layers
    layers=$(hyprctl layers -j 2>/dev/null) || return 0
    [ -n "$layers" ] || return 0
    jq -r --argjson mons "$1" '
        . as $l
        | $mons[]
        | select(([$l[.].levels // {} | .[] | .[] | .namespace
                   | select(startswith("skwd"))] | length) == 0)
    ' <<<"$layers" 2>/dev/null
}

# the daemon may be restoring right now (login), so give it a moment: poll
# until every output has its layer, and only act if one never gets it
monitors=""
for _ in $(seq 1 8); do
    sleep 0.25
    next=$(hyprctl monitors -j 2>/dev/null | jq -c '[.[].name]' 2>/dev/null) || continue
    [ -n "$next" ] || continue
    monitors="$next"
    [ -z "$(bare "$monitors")" ] && exit 0
done
[ -n "$monitors" ] || exit 0

# what the daemon itself restored last: path, plus we_id for a Wallpaper Engine
# scene (which has no still of its own; the daemon addresses it as we:<id>)
target=$(jq -r '.path // empty' "$CACHE/last-wallpaper.json" 2>/dev/null)
[ -n "$target" ] || target=$(jq -r '.any.path // empty' "$CACHE/last-applied.json" 2>/dev/null)
[ -n "$target" ] || exit 0
if [ "$(jq -r '.type // "static"' "$CACHE/last-wallpaper.json" 2>/dev/null)" = "we" ]; then
    we=$(jq -r '.we_id // empty' "$CACHE/last-wallpaper.json" 2>/dev/null)
    [ -n "$we" ] && target="we:$we"
fi

echo "wallpaper-heal: no skwd layer on $(bare "$monitors" | paste -sd, -), re-applying $target" \
    >>"$CACHE/heal.log"
skwd-helm apply "$target" >/dev/null 2>&1 || true
