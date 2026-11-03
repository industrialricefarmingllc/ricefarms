#!/usr/bin/env bash
# workshop-remove.sh <workshop-id>
#
# Delete a Wallpaper Engine item the way the picker's Delete action means:
# unsubscribe through skwd's Steam backend (the running client does the
# ISteamUGC call), remove Steam's local content copy, and drop the preview
# caches this item left behind.
#
# It refuses to delete the folder when the unsubscribe fails, so a logged-out
# or stopped Steam client cannot leave a half-removed item that Steam would
# download again on the next launch.
set -uo pipefail

id="${1:-}"
[[ "$id" =~ ^[0-9]+$ ]] || { echo "invalid Workshop id: $id" >&2; exit 2; }

home="${HOME:-$USER}"
content="${LUCID_WORKSHOP_DIR:-$home/.local/share/Steam/steamapps/workshop/content/431960}"
item="$content/$id"
cache="${XDG_CACHE_HOME:-$home/.cache}/lucid/live-previews"
skwd_cache="${XDG_CACHE_HOME:-$home/.cache}/skwd-wall-v2"

if ! command -v skwd-steam >/dev/null 2>&1; then
    echo "skwd-steam is not installed; cannot unsubscribe from the Workshop" >&2
    exit 1
fi

out=$(skwd-steam unsub "$id" 2>&1)
code=$?
line=$(printf '%s\n' "$out" | tail -n1)
status=""
message=""
if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    status=$(printf '%s' "$line" | jq -r '.status // ""' 2>/dev/null || true)
    message=$(printf '%s' "$line" | jq -r '.message // ""' 2>/dev/null || true)
fi

if [ "$code" -ne 0 ] || { [ -n "$status" ] && [ "$status" != "unsubscribed" ]; }; then
    printf '%s\n' "${message:-${out:-could not unsubscribe Workshop item $id}}" >&2
    exit 1
fi

rm -rf -- "$item" || { echo "could not remove $item" >&2; exit 1; }

# live preview: the index entry and the files it points at. A Workshop item
# can also be a plain video, where the files are video-<hash> rather than
# we-<id>, so read the paths out of the index before dropping its key.
preview_files=()
if [ -f "$cache/index.json" ] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r p; do
        [ -n "$p" ] && [ "$p" != "null" ] && preview_files+=("$p")
    done < <(jq -r --arg k "we:$id" '(.[$k]? // {}) | (.mp4 // empty), (.gif // empty), (.jpg // empty)' \
        "$cache/index.json" 2>/dev/null || true)
    tmp="$cache/index.json.$$.tmp"
    if jq --arg k "we:$id" 'del(.[$k])' "$cache/index.json" >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$cache/index.json"
    else
        rm -f "$tmp"
    fi
fi
[ "${#preview_files[@]}" -gt 0 ] && rm -f -- "${preview_files[@]}"
rm -f "$cache/we-$id.mp4" "$cache/we-$id.gif" "$cache/we-$id.jpg"

# skwd's own thumbnails and scene block cache
rm -f "$skwd_cache/we-thumbs/$id.webp" \
      "$skwd_cache/thumbs-sm/we--$id.webp" \
      "$skwd_cache/previews/we--$id.webp" \
      "$skwd_cache/blocks/we--$id".bc* \
      "$skwd_cache/scene-thumbnails/$id.lock"

# ask the library to prune the row now, rather than waiting for the next scan
if command -v skwd-wall-scan >/dev/null 2>&1; then
    skwd-wall-scan >/dev/null 2>&1 || true
fi

printf '%s\n' "removed $id"
exit 0
