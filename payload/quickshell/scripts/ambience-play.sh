#!/bin/sh
# Play every track for one wallpaper at once, looping each forever.
#
# usage: ambience-play.sh <cache-dir> <gain> <id;url;volume;filter>...
#        ambience-play.sh --add <cache-dir> <group> <index> <gain> <track>
#
# The --add form starts one more player inside a group that is already running,
# so an existing running order can grow without restarting its other tracks.
#
# A track that is already cached starts immediately and loops from disk.
# A track that is not cached is streamed: yt-dlp writes the audio to stdout,
# tee keeps a copy in the cache, and mpv plays the bytes as they arrive. When
# that first pass ends, the complete cache file takes over and loops. This way
# a long video starts in a beat instead of waiting for the whole download.
#
# Every group has its own client name; an old group can fade out while the new
# one fades in. Each track fades to its own stored volume, times the automatic
# gain (three quarters under other audio, one and a half when alone), and starts with
# its own sound-mode filter. The stored volumes themselves are never changed
# here.

set -u

. "$(dirname "$0")/ambience-cookies.sh"

mode=group
if [ "${1:-}" = "--add" ]; then
    mode=add
    shift
fi

if [ "$mode" = add ]; then
    dir=$1
    shift
    group=$1
    shift
    index=$1
    shift
    gain=${1:-1}
    shift
else
    dir=$1
    shift
    gain=${1:-1}
    shift
    group=$$
    index=""
fi

case "$gain" in
    ''|*[!0-9.]*) gain=1 ;;
esac

fade="$(dirname "$0")/ambience-fade.py"
client="Lucid Ambience $group"
stopflag="$dir/ambience-$group.stop"

mkdir -p "$dir" || exit 1

kids=""
players_started=0
sockets=""
fades=""
fadepid=""

find_file() {
    for f in "$dir/$1".*; do
        case "$f" in
            *.part|*.ytdl|*.temp|*.head|*.headfmt) continue ;;
        esac
        if [ -s "$f" ]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

play_cached() {
    vol=$1
    filter=$2
    sock=$3
    file=$4
    pclient=$5

    set -- --no-video --no-config --no-terminal --input-terminal=no --force-window=no
    [ -n "$filter" ] && set -- "$@" --af="lavfi=[$filter]"
    set -- "$@" --volume-max=150 --volume=0 --loop-file=inf --input-ipc-server="$sock" --audio-client-name="$pclient" -- "$file"
    mpv "$@"
}

play_stream() {
    id=$1
    url=$2
    vol=$3
    filter=$4
    sock=$5
    pclient="$client $id"
    part="$dir/$id.part"
    final="$dir/$id.stream"
    rc="$dir/ambience-$group-$id.rc"

    rm -f "$part" "$rc"

    head="$dir/$id.head"
    headfmt="$dir/$id.headfmt"
    hsize=0
    hfmt=""
    if [ -s "$head" ] && [ -s "$headfmt" ]; then
        hsize=$(wc -c < "$head" | tr -d ' ')
        hfmt=$(cat "$headfmt" 2>/dev/null)
        case "$hsize" in
            ''|*[!0-9]*) hsize=0 ;;
        esac
    fi
    use_head=0
    [ "$hsize" -ge 262144 ] && [ -n "$hfmt" ] && use_head=1

    set -- --no-video --no-config --no-terminal --input-terminal=no --force-window=no
    [ -n "$filter" ] && set -- "$@" --af="lavfi=[$filter]"
    set -- "$@" --volume-max=150 --volume=0 --input-ipc-server="$sock" --audio-client-name="$pclient" -- -

    if [ "$use_head" -eq 1 ]; then
        # the head is the prefix of this same download. Start the real
        # download at once, drop the bytes the head already covers, and let
        # cat hand the head to mpv followed by the live remainder.
        cat "$head" <( { ambience_ytdlp --no-warnings --no-playlist --no-progress --newline \
                --no-simulate --socket-timeout 20 --retries 2 --fragment-retries 2 \
                -f "$hfmt" -o - "$url"
              echo $? > "$rc"
            } | tail -c +$((hsize + 1)) ) | tee "$part" | mpv "$@"
    else
        { ambience_ytdlp --no-warnings --no-playlist --no-progress --newline \
            --no-simulate --socket-timeout 20 --retries 2 --fragment-retries 2 \
            -f 'bestaudio/best' --print-to-file 'before_dl:%(format_id)s' "$headfmt" -o - "$url"
          echo $? > "$rc"
        } | tee "$part" | python3 "$(dirname "$0")/ambience-head.py" "$head" 1500000 | mpv "$@"
    fi

    if [ -e "$stopflag" ]; then
        rm -f "$part" "$rc"
        exit 0
    fi

    if [ "$use_head" -eq 1 ] && [ "$(cat "$rc" 2>/dev/null)" != "0" ]; then
        # the cached prefix no longer matches this source; rebuild it next time
        rm -f "$head" "$headfmt"
    fi

    if [ "$(cat "$rc" 2>/dev/null)" = "0" ] && [ -s "$part" ]; then
        mv "$part" "$final"
        rm -f "$head" "$headfmt"
    else
        rm -f "$part"
    fi
    rm -f "$rc"

    [ -e "$stopflag" ] && exit 0

    if [ -s "$final" ]; then
        set -- --no-video --no-config --no-terminal --input-terminal=no --force-window=no
        [ -n "$filter" ] && set -- "$@" --af="lavfi=[$filter]"
        set -- "$@" --volume-max=150 --volume="$vol" --loop-file=inf --input-ipc-server="$sock" --audio-client-name="$pclient" -- "$final"
        exec mpv "$@"
    fi
    exit 1
}

if [ "$mode" = add ]; then
    pair=${1:-}
    [ -n "$pair" ] || exit 1
    id=${pair%%;*}
    rest=${pair#*;}
    url=${rest%%;*}
    rest=${rest#*;}
    vol=${rest%%;*}
    filter=${rest#*;}
    case "$vol" in
        ''|*[!0-9]*) vol=50 ;;
    esac
    [ "$vol" -gt 150 ] && vol=150
    eff=$(awk -v v="$vol" -v g="$gain" 'BEGIN { x = v * g; if (x < 0) x = 0; if (x > 150) x = 150; printf "%d", x + 0.5 }')
    case "$eff" in
        ''|*[!0-9]*) eff=$vol ;;
    esac

    case "$index" in
        ''|*[!0-9]*) exit 1 ;;
    esac

    sock="$dir/ambience-$group-$index.sock"
    rm -f "$sock"
    addpid=""
    addcleanup() {
        trap - EXIT TERM INT
        if [ -n "$fadepid" ]; then
            kill "$fadepid" 2>/dev/null
            wait "$fadepid" 2>/dev/null
            fadepid=""
        fi
        if [ -n "$addpid" ]; then
            kill "$addpid" 2>/dev/null
        fi
        rm -f "$sock"
    }
    trap addcleanup EXIT TERM INT

    # the group may have been switched away while this was being launched
    if [ -e "$stopflag" ] || ! kill -0 "$group" 2>/dev/null; then
        exit 0
    fi

    if f=$(find_file "$id"); then
        play_cached "$eff" "$filter" "$sock" "$f" "$client $id" &
    else
        play_stream "$id" "$url" "$eff" "$filter" "$sock" &
    fi
    addpid=$!

    i=0
    while [ ! -S "$sock" ] && [ "$i" -lt 100 ]; do
        sleep 0.05
        i=$((i + 1))
    done

    python3 "$fade" in "$sock:$eff" &
    fadepid=$!
    wait "$fadepid"
    fadepid=""
    wait "$addpid"
    exit 0
fi

rm -f "$stopflag"

cleanup() {
    trap - EXIT TERM INT
    touch "$stopflag"
    if [ -n "$fadepid" ]; then
        kill "$fadepid" 2>/dev/null
        wait "$fadepid" 2>/dev/null
        fadepid=""
    fi
    if [ "$players_started" -eq 1 ] && [ -n "$fades" ]; then
        python3 "$fade" out $fades
    fi
    pkill -f -- "--audio-client-name=$client" 2>/dev/null
    for p in $kids; do
        kill "$p" 2>/dev/null
    done
    for s in $sockets; do
        rm -f "$s"
    done
    rm -f "$stopflag"
}
trap cleanup EXIT TERM INT

n=0
for pair in "$@"; do
    id=${pair%%;*}
    rest=${pair#*;}
    url=${rest%%;*}
    rest=${rest#*;}
    vol=${rest%%;*}
    filter=${rest#*;}
    case "$vol" in
        ''|*[!0-9]*) vol=50 ;;
    esac
    [ "$vol" -gt 150 ] && vol=150
    # the widget's row is the stored mix; this target is only for the fade and
    # the player's starting level, the helper applies the same gain afterwards
    eff=$(awk -v v="$vol" -v g="$gain" 'BEGIN { x = v * g; if (x < 0) x = 0; if (x > 150) x = 150; printf "%d", x + 0.5 }')
    case "$eff" in
        ''|*[!0-9]*) eff=$vol ;;
    esac

    sock="$dir/ambience-$group-$n.sock"
    rm -f "$sock"
    sockets="$sockets $sock"
    fades="$fades $sock:$eff"

    if f=$(find_file "$id"); then
        play_cached "$eff" "$filter" "$sock" "$f" "$client $id" &
        kids="$kids $!"
    else
        play_stream "$id" "$url" "$eff" "$filter" "$sock" &
        kids="$kids $!"
    fi
    n=$((n + 1))
done
players_started=1

# mpv creates the control socket as it starts; give every player a moment
for s in $sockets; do
    i=0
    while [ ! -S "$s" ] && [ "$i" -lt 100 ]; do
        sleep 0.05
        i=$((i + 1))
    done
done

# count the players that actually survived; a failed download leaves no mpv
# behind, and reporting every requested track as ready hid that
alive=0
for p in $kids; do
    if kill -0 "$p" 2>/dev/null; then
        alive=$((alive + 1))
    fi
done

echo "@@group:$group@@"
echo "@@ready:$alive@@"

python3 "$fade" in $fades &
fadepid=$!
wait "$fadepid"
fadepid=""

# keep reporting how many players are still alive; a download can fail after
# the first count, and the widget should stop claiming that layer is playing.
# (Lucid's sh is bash, so wait -n is available.)
while [ "$alive" -gt 0 ]; do
    wait -n 2>/dev/null
    now=0
    for p in $kids; do
        if kill -0 "$p" 2>/dev/null; then
            now=$((now + 1))
        fi
    done
    if [ "$now" -ne "$alive" ]; then
        alive=$now
        echo "@@alive:$alive@@"
    fi
done

players_started=0
