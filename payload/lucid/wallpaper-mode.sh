#!/usr/bin/env bash
# wallpaper-mode.sh <image>
#
# prints dark when either more than half of a 64×64 sample sits below luma 100,
# or at least a fifth sits below luma 32 (a large true-black region); light
# otherwise. This is the same rule set-wallpaper.sh uses, so the "Follow the
# wallpaper" switch and a normal wallpaper change agree. A <stem>.json sidecar
# can pin the answer with {"themeMode":"dark"} (or {"mode":"dark"}). The answer
# is kept per picture, so browsing past one again costs nothing.

set -euo pipefail

IMAGE="${1:?usage: wallpaper-mode.sh <image>}"
[[ -f "$IMAGE" ]] || exit 1
DARK_LUMA="${DARK_LUMA:-100}"
DARK_THRESHOLD="${DARK_THRESHOLD:-0.5}"
BLACK_LUMA="${BLACK_LUMA:-32}"
BLACK_THRESHOLD="${BLACK_THRESHOLD:-0.2}"

# A per-wallpaper config wins over the measurement. Check it before magick so a
# video or a backend thumbnail can still carry an override.
SIDECAR="${IMAGE%.*}.json"
if [[ -f "$SIDECAR" ]] && command -v jq &>/dev/null; then
    OVERRIDE=$(jq -r '(.themeMode // .mode // "") | tostring | ascii_downcase' "$SIDECAR" 2>/dev/null || true)
    case "$OVERRIDE" in
        dark | light)
            echo "$OVERRIDE"
            exit 0
            ;;
    esac
fi

# A moving wallpaper is only handed here for its sidecar; magick cannot measure
# it. set-mode.sh falls back to the still frame.
case "${IMAGE,,}" in
    *.mp4 | *.webm | *.mkv | *.mov | *.m4v) exit 1 ;;
esac

command -v magick &>/dev/null || exit 1

DIR="$HOME/.cache/lucid/wallpaper-mode"
KEY=$(printf '%s|%s|%s|%s|%s|%s' "$IMAGE" "$(stat -c %Y "$IMAGE" 2>/dev/null || echo 0)" \
    "$DARK_LUMA" "$DARK_THRESHOLD" "$BLACK_LUMA" "$BLACK_THRESHOLD" | sha1sum | cut -c1-16)

if [[ -f "$DIR/$KEY" ]]; then
    touch "$DIR/$KEY"
    cat "$DIR/$KEY"
    exit 0
fi

# Count dark pixels in the same 64×64 sample set-wallpaper.sh uses. ImageMagick
# turns anything below the cutoff white; the remaining mean is the light share.
# (Do not use $IMAGE[0] here: the frame selector breaks PNG decoding.)
MID_THRESH=$(awk -v l="$DARK_LUMA" 'BEGIN { printf "%.4f%%", l * 100 / 255 }')
BLACK_THRESH=$(awk -v l="$BLACK_LUMA" 'BEGIN { printf "%.4f%%", l * 100 / 255 }')
MID_LIGHT=$(MAGICK_THREAD_LIMIT=2 nice -n 19 magick -define jpeg:size=128x128 "$IMAGE" \
    -alpha off -resize '64x64!' -colorspace Gray -threshold "$MID_THRESH" \
    -format '%[fx:mean]' info: 2>/dev/null) || exit 1
BLACK_LIGHT=$(MAGICK_THREAD_LIMIT=2 nice -n 19 magick -define jpeg:size=128x128 "$IMAGE" \
    -alpha off -resize '64x64!' -colorspace Gray -threshold "$BLACK_THRESH" \
    -format '%[fx:mean]' info: 2>/dev/null) || exit 1
MODE=$(awk -v ml="$MID_LIGHT" -v bl="$BLACK_LIGHT" \
    -v mt="$DARK_THRESHOLD" -v bt="$BLACK_THRESHOLD" \
    'BEGIN { print ((1 - ml) > mt || (1 - bl) > bt) ? "dark" : "light" }')

mkdir -p "$DIR"
printf '%s' "$MODE" > "$DIR/$KEY"
find "$DIR" -type f -mtime +60 -delete 2>/dev/null || true
echo "$MODE"
