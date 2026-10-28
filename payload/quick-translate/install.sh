#!/usr/bin/env bash
set -euo pipefail

# Install quick-translate into the running Hyprland session. It does not touch
# Lucid's tree: the widget is its own Quickshell config and its own daemon.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYPR="$HOME/.config/hypr"
CUSTOM_LUA="$HYPR/custom.lua"
CONF="$HYPR/quick-translate.conf"
NO_HYPR=0
NO_START=0

for arg in "$@"; do
    case "$arg" in
        --no-hypr) NO_HYPR=1 ;;
        --no-start) NO_START=1 ;;
        -h|--help)
            sed -n '2,22p' "$0"
            exit 0
            ;;
        *)
            printf 'unknown option: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

say() { printf '  %s\n' "$*"; }

printf '\nquick-translate\n---------------\n'
say "repo: $DIR"

if ! command -v qs >/dev/null 2>&1; then
    printf '\nquickshell (qs) is required.\n' >&2
    exit 1
fi

if ! command -v opencode >/dev/null 2>&1; then
    say "warning: opencode is not on PATH; translations will fail until it is."
fi

mkdir -p "$HOME/.config/quick-translate"

if [[ $NO_HYPR -eq 0 ]]; then
    if [[ -f $CUSTOM_LUA ]]; then
        say "binding SUPER+T in $CUSTOM_LUA"
        cp -a "$CUSTOM_LUA" "$CUSTOM_LUA.bak.$(date +%Y%m%d_%H%M%S)"
        python3 - "$CUSTOM_LUA" "$DIR" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
repo = sys.argv[2]
text = path.read_text() if path.exists() else ""
start = "-- >>> quick-translate >>>"
end = "-- <<< quick-translate <<<"
block = f"""{start}
-- SUPER+T toggles the quick-translate widget; Escape closes it.
hl.bind("SUPER + T", hl.dsp.exec_cmd("qs -p {repo} ipc call quick-translate toggle"), {{ description = "Quick translate (SUPER+T)" }})
-- Start it with the compositor. -n leaves an already-running daemon alone.
hl.exec_cmd("qs -p {repo} -n -d")
{end}
"""
if start in text:
    text = re.sub(re.escape(start) + r".*?" + re.escape(end) + r"\n?", block, text, flags=re.S)
else:
    text = text.rstrip() + "\n\n" + block
path.write_text(text)
PY
    elif [[ -f "$HYPR/hyprland.conf" ]]; then
        say "writing $CONF and sourcing it from hyprland.conf"
        cat > "$CONF" <<EOF
# quick-translate: SUPER+T opens, Escape closes
exec-once = qs -p $DIR -n -d
bind = SUPER, T, exec, qs -p $DIR ipc call quick-translate toggle
EOF
        if ! python3 -c 'import pathlib,sys; wanted="source = "+sys.argv[2]; raise SystemExit(0 if wanted in (line.strip() for line in pathlib.Path(sys.argv[1]).read_text().splitlines()) else 1)' "$HYPR/hyprland.conf" "$CONF"; then
            cp -a "$HYPR/hyprland.conf" "$HYPR/hyprland.conf.bak.$(date +%Y%m%d_%H%M%S)"
            printf '\nsource = %s\n' "$CONF" >> "$HYPR/hyprland.conf"
        fi
    else
        say "no custom.lua or hyprland.conf found; add hypr/quick-translate.lua yourself"
    fi

    # Lucid opens the launcher on a bare Super release. A SUPER+T chord must
    # clear that tap intent, or the same release opens the launcher too.
    if [[ -f "$HYPR/hyprland.lua" ]]; then
        say "disarming the bare-Super launcher tap for SUPER+T"
        cp -a "$HYPR/hyprland.lua" "$HYPR/hyprland.lua.bak.$(date +%Y%m%d_%H%M%S)"
        python3 - "$HYPR/hyprland.lua" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
start = "-- >>> quick-translate tap disarm >>>"
end = "-- <<< quick-translate tap disarm <<<"
block = f"""{start}
-- SUPER+T is a chord, not a bare Super tap. Clear the tap intent before the
-- Super release bind can open Lucid's launcher as well.
hl.bind("SUPER + T", super_tap_disarm, {{ transparent = true, non_consuming = true, description = "disarm launcher tap (SUPER+T)" }})
{end}
"""
anchor = "local function super_tap_disarm() super_tap_armed = false tmux_super_armed = false end\n"
if start in text:
    text = re.sub(re.escape(start) + r".*?" + re.escape(end) + r"\n?", block, text, flags=re.S)
elif anchor in text:
    text = text.replace(anchor, anchor + "\n" + block, 1)
else:
    print("  note: no Lucid super_tap_disarm in hyprland.lua; add SUPER+T to your tap-disarm list by hand")
    raise SystemExit(0)
path.write_text(text)
PY
    fi

    if command -v hyprctl >/dev/null 2>&1 && hyprctl version >/dev/null 2>&1; then
        say "reloading Hyprland"
        hyprctl reload >/dev/null 2>&1 || true
    fi
fi

if [[ $NO_START -eq 0 ]]; then
    say "starting the widget daemon"
    qs -p "$DIR" -n -d >/dev/null 2>&1 || true
fi

if command -v hyprctl >/dev/null 2>&1; then
    # A Lucid default keybind file may still call the theme picker on SUPER+T.
    if [[ -f "$HOME/.config/lucid/keybinds.json" ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); raise SystemExit(0 if any(b.get("keys") == "SUPER + T" for b in d.get("binds", [])) else 1)' "$HOME/.config/lucid/keybinds.json" 2>/dev/null; then
        say "note: ~/.config/lucid/keybinds.json also binds SUPER+T to the theme picker."
        say "      move that bind in Settings > Keybinds if both open at once."
    fi
fi

printf '\nPress SUPER+T. Escape closes it.\n\n'
