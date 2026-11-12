#!/bin/sh
# usage: ambience-title.sh <url>
#
# Print the title of a YouTube video through the same cookie-aware yt-dlp
# launcher the players use; a title fetch that runs anonymously can fail even
# when playback would work.

set -u

. "$(dirname "$0")/ambience-cookies.sh"

url=${1:-}
[ -n "$url" ] || exit 1

ambience_ytdlp --no-warnings --skip-download --no-playlist \
    --socket-timeout 12 --print '%(title)s' "$url"
