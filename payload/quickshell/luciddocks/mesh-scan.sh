#!/usr/bin/env bash
# One JSON line per known job, plus the last finished one.
#
# The widget cannot ask the kernel whether a pid is alive, so each record
# carries that answer; it is what tells a live detached job apart from one
# interrupted by a shell reload or a reboot.
set -u
D="${HOME:-/home/$(id -un)}/.cache/lucid-mesh"
for f in "$D"/active-*.json; do
    [ -e "$f" ] || continue
    p=$(basename "$f" .json)
    p=${p#active-}
    if kill -0 "$p" 2>/dev/null; then
        alive=true
    else
        alive=false
    fi
    jq -c --argjson alive "$alive" --arg file "$f" \
        '. + {alive: $alive, file: $file}' "$f" 2>/dev/null || true
done
if [ -f "$D/last.json" ]; then
    jq -c '. + {alive: false, file: "last.json"}' "$D/last.json" 2>/dev/null || true
fi

