#!/bin/bash
# watch-theme-mode.sh - apply mode changes made by tools other than set-wallpaper.
#
# The normal path (Settings, the SUPER+ALT+T toggle, set-mode.sh) calls
# set-wallpaper.sh directly, which already writes every state file and starts
# the coalesced fanout. This watcher only exists for the remaining case: some
# tool writes ~/.cache/quickshell/theme_mode by hand.
#
# It is event-driven when inotifywait is available, so an idle desktop costs
# zero wakeups. The old 0.8 s poll woke up ~108k times a day for a file that
# changes a handful of times. The poll fallback is deliberately slow (2 s).
set -u
CACHE="$HOME/.cache"
THEME_FILE="$CACHE/quickshell/theme_mode"
WALL_FILE="$CACHE/current_wallpaper"
SET_WALL="$HOME/.config/hypr/scripts/wallpaper/set-wallpaper.sh"
mkdir -p "$CACHE/quickshell"

apply_if_needed() {
    local mode wall cur_sig sig
    # set-wallpaper.sh is authoritative while it runs; its /tmp lock also
    # covers the window before apply.sig is written.
    pgrep -f 'wallpaper/set-wallpaper.sh' >/dev/null 2>&1 && return 0
    if [[ -f /tmp/matugen-theme-toggle.lock ]]; then
        local age
        age=$(( $(date +%s) - $(stat -c %Y /tmp/matugen-theme-toggle.lock 2>/dev/null || echo 0) ))
        (( age < 3 )) && return 0
    fi
    mode=$(cat "$THEME_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [[ "$mode" == "light" || "$mode" == "dark" ]] || return 0
    wall=$(cat "$WALL_FILE" 2>/dev/null | tr -d '\n' | xargs || true)
    [[ -n "$wall" && -f "$wall" ]] || return 0

    # Already applied by set-wallpaper? Its fast-path signature covers the
    # wallpaper, mode, theme and prefs, so this is exact, not a time window.
    cur_sig=$(cat "$CACHE/lucid/apply.sig" 2>/dev/null || true)
    sig=$(printf '%s|%s|%s|%s|%s' \
        "$wall" "$(stat -c '%y|%s' "$wall" 2>/dev/null)" "$mode" \
        "$(cat "$CACHE/current_theme" 2>/dev/null || echo matugen)" \
        "$(stat -c '%y|%s' "$HOME/.config/matugen/config.toml" 2>/dev/null)|$(stat -c '%y|%s' "$HOME/.config/quickshell/lucidprefs/prefs.json" 2>/dev/null)" \
        | sha1sum | cut -d' ' -f1)
    [[ "$cur_sig" == "$sig" ]] && return 0

    "$SET_WALL" "$wall" "$mode" >/dev/null 2>&1 || true
}

if command -v inotifywait >/dev/null 2>&1; then
    # theme_mode is written atomically (rename), hence moved_to plus create.
    inotifywait -m -q -e close_write,moved_to,create --format '%w%f' \
        "$CACHE/quickshell" 2>/dev/null | while read -r ev; do
        case "${ev##*/}" in theme_mode) ;; *) continue ;; esac
        # let set-wallpaper finish its own state writes before we look
        sleep 0.15
        apply_if_needed
    done
else
    last=""
    while true; do
        sleep 2
        cur="$(cat "$THEME_FILE" 2>/dev/null || true)"
        [[ "$cur" == "$last" ]] && continue
        last="$cur"
        apply_if_needed
    done
fi
