#!/usr/bin/env bash
# skwd-previews.sh
#
# Cut the short animated WebP previews that skwd's picker and lucid's live
# wallpaper cards play for videos. skwd-helm list already knows where each one
# belongs, so this only asks its scanner for the missing ones, one at a time,
# niced, and stops after a few so opening the picker never becomes a batch job.
set -uo pipefail

command -v skwd-helm >/dev/null 2>&1 || exit 0
command -v skwd-wall-scan >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/skwd-wall-v2"
LOCK="$CACHE/.lucid-previews.lock"
mkdir -p "$CACHE"

# a picker opened twice must not queue the same work twice
exec 9>"$LOCK"
flock -n 9 || exit 0

LOW=(nice -n 19)
command -v ionice >/dev/null 2>&1 && LOW+=(ionice -c 3)

while IFS=$'\t' read -r key video preview; do
    [[ -n "$key" && -n "$video" && -f "$video" ]] || continue
    [[ -n "$preview" && -s "$preview" ]] && continue
    # the scanner has already made it by the time a later run sees the path
    [[ -n "$preview" ]] || continue

    "${LOW[@]}" skwd-wall-scan --preview "$key" "$video" </dev/null &>/dev/null || true
done < <(skwd-helm list --json 2>/dev/null | jq -r '
    .wallpapers[]?
    | select(.type == "video")
    | [ (.key // ""), (.video_file // ""), (.preview // "") ]
    | @tsv' 2>/dev/null)

exit 0
