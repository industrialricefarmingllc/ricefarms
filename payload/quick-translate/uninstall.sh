#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYPR="$HOME/.config/hypr"
CUSTOM_LUA="$HYPR/custom.lua"
CONF="$HYPR/quick-translate.conf"

printf '\nquick-translate uninstall\n-------------------------\n'

if [[ -f $CUSTOM_LUA ]]; then
    python3 - "$CUSTOM_LUA" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
start = "-- >>> quick-translate >>>"
end = "-- <<< quick-translate <<<"
text = re.sub(re.escape(start) + r".*?" + re.escape(end) + r"\n?", "", text, flags=re.S)
path.write_text(text.rstrip() + "\n")
PY
    printf '  removed the Lua bind from %s\n' "$CUSTOM_LUA"
fi

if [[ -f $CONF ]]; then
    rm -f "$CONF"
    printf '  removed %s\n' "$CONF"
    printf '  (hyprland.conf may keep a harmless source = line for it)\n'
fi

if [[ -f "$HYPR/hyprland.lua" ]]; then
    python3 - "$HYPR/hyprland.lua" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
start = "-- >>> quick-translate tap disarm >>>"
end = "-- <<< quick-translate tap disarm <<<"
text = re.sub(re.escape(start) + r".*?" + re.escape(end) + r"\n?", "", text, flags=re.S)
path.write_text(text.rstrip() + "\n")
PY
    printf '  removed the tap-disarm bind from %s\n' "$HYPR/hyprland.lua"
fi

if command -v pkill >/dev/null 2>&1; then
    pkill -f -- "qs -p $DIR" 2>/dev/null || true
    printf '  stopped the widget daemon\n'
fi

if command -v hyprctl >/dev/null 2>&1 && hyprctl version >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 || true
fi

printf '\nThe remembered language stays in ~/.config/quick-translate/state.json.\n\n'
