#!/bin/sh
# usage: ambience-heads.sh <cache-dir> <id;url>...
#
# Build a small prefix file for every track that has neither a full cache nor
# a head yet. The prefix lets a later stream start without waiting for yt-dlp:
# the player reads the head immediately, and the live download skips that many
# bytes and continues the same stream. Run this in the background, politely.

set -u

. "$(dirname "$0")/ambience-cookies.sh"

dir=$1
shift
mkdir -p "$dir" || exit 1

limit=1500000
minimum=1350000

has_full() {
    for f in "$dir/$1".*; do
        case "$f" in
            *.part|*.ytdl|*.temp|*.head|*.headfmt) continue ;;
        esac
        if [ -s "$f" ]; then
            return 0
        fi
    done
    return 1
}

for pair in "$@"; do
    id=${pair%%;*}
    url=${pair#*;}
    [ -n "$id" ] && [ -n "$url" ] || continue

    head="$dir/$id.head"
    fmt="$dir/$id.headfmt"

    if [ -s "$head" ] && [ -s "$fmt" ]; then
        size=$(wc -c < "$head" | tr -d ' ')
        case "$size" in
            ''|*[!0-9]*) size=0 ;;
        esac
        [ "$size" -ge "$minimum" ] && continue
    fi

    if has_full "$id"; then
        rm -f "$head" "$headfmt"
        continue
    fi

    tmp="$dir/$id.head.temp"
    ftmp="$dir/$id.headfmt.temp"
    rm -f "$tmp" "$ftmp"

    { ambience_ytdlp --no-warnings --no-playlist --no-progress --newline \
        --no-simulate --socket-timeout 20 --retries 2 --fragment-retries 2 \
        -f 'bestaudio/best' --print-to-file 'before_dl:%(format_id)s' "$ftmp" \
        -o - "$url" 2>/dev/null
    } | head -c "$limit" > "$tmp"

    if [ -s "$tmp" ] && [ -s "$ftmp" ]; then
        mv "$tmp" "$head"
        mv "$ftmp" "$fmt"
    else
        rm -f "$tmp" "$ftmp"
    fi
done
