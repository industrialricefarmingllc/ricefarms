#!/usr/bin/env bash
# wallpaper-mode.sh <image>
#
# prints light for a bright picture and dark for a dark one: the mean grey of a
# small copy, against the middle. Settings -> Theme -> Follow the wallpaper is
# set-wallpaper.sh asking this before it derives the colours. the answer is kept
# per picture, so browsing past one again costs nothing

set -euo pipefail

IMAGE="${1:?usage: wallpaper-mode.sh <image>}"
[[ -f "$IMAGE" ]] || exit 1
command -v magick &>/dev/null || exit 1

DIR="$HOME/.cache/lucid/wallpaper-mode"
KEY=$(printf '%s|%s' "$IMAGE" "$(stat -c %Y "$IMAGE" 2>/dev/null || echo 0)" | sha1sum | cut -c1-16)

if [[ -f "$DIR/$KEY" ]]; then
    touch "$DIR/$KEY"
    cat "$DIR/$KEY"
    exit 0
fi

# jpeg:size lets the decoder skip most of a big jpeg instead of reading it whole
MEAN=$(MAGICK_THREAD_LIMIT=2 nice -n 19 magick -define jpeg:size=128x128 "$IMAGE[0]" \
    -resize '64x64!' -colorspace Gray -format '%[fx:mean]' info: 2>/dev/null) || exit 1
MODE=$(awk -v m="$MEAN" 'BEGIN { print (m > 0.5) ? "light" : "dark" }')

mkdir -p "$DIR"
printf '%s' "$MODE" > "$DIR/$KEY"
find "$DIR" -type f -mtime +60 -delete 2>/dev/null || true
echo "$MODE"
