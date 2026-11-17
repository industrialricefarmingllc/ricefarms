#!/usr/bin/env bash
# remote-wall.sh - materialise one web wallpaper on demand.
#
#   remote-wall.sh wallhaven <id> <wallpaper-dir> <progress-file>
#   remote-wall.sh steam <workshop-id> <progress-file>
#
# Wallhaven: asks the API for the full image, writes it beside the local
# wallpapers as wallhaven-<id>.<ext>, then hands it to set-wallpaper.sh so the
# palette and mode work exactly as they do for a local file.
#
# Steam: if the scene is already in the workshop folder it is applied through
# skwd. Otherwise skwd-steam subscribes and downloads through the running Steam
# client, then the script applies it. Opening the item page is only the
# fallback when that backend is unavailable.
#
# The progress file is a one-line JSON document the QML card watches while the
# download is running: {state, progress, total, message}.
set -uo pipefail

HOME="${HOME:-$USER}"
PREFS="$HOME/.config/quickshell/lucidprefs/prefs.json"
SET_WALL="$HOME/.config/hypr/scripts/wallpaper/set-wallpaper.sh"
WORKSHOP_DIR="$HOME/.local/share/Steam/steamapps/workshop/content/431960"
UA="lucid-shell/1.0 (+wallpaper search)"
PROGRESS=""

notify() {
    command -v notify-send >/dev/null 2>&1 && notify-send -a "Lucid" "Wallpaper" "$1" || true
}

write_progress() { # state progress total message
    local line
    line=$(printf '{"state":"%s","progress":%s,"total":%s,"message":"%s"}' \
        "$1" "${2:-0}" "${3:-0}" "${4:-}")
    if [ -n "$PROGRESS" ]; then
        mkdir -p "$(dirname "$PROGRESS")" 2>/dev/null || true
        printf '%s\n' "$line" >"$PROGRESS" 2>/dev/null || true
    fi
    # The picker reads these lines per worker, so several downloads can report
    # at once without a shared file.
    [ "${REMOTE_WALL_PROGRESS_STDOUT:-0}" = "1" ] && printf '%s\n' "$line"
    return 0
}

fail() {
    echo "error: $1" >&2
    write_progress error 0 0 "$1"
    notify "$1"
    exit 1
}

[ -x "$SET_WALL" ] || fail "set-wallpaper.sh is missing"

case "${1:-}" in
wallhaven)
    id="${2:-}"
    dir="${3:-}"
    PROGRESS="${4:-}"
    [[ "$id" =~ ^[A-Za-z0-9]+$ ]] || fail "bad Wallhaven id"
    [ -n "$dir" ] || fail "no wallpaper folder"
    mkdir -p "$dir" || fail "cannot create $dir"

    key=$(jq -r '.wallhavenApiKey // ""' "$PREFS" 2>/dev/null || true)
    api="https://wallhaven.cc/api/v1/w/$id"

    # curl reads the key from a config on stdin so it never appears in `ps`
    if [ -n "$key" ]; then
        meta=$(printf 'url = "%s"\nheader = "X-API-Key: %s"\n' "$api" "$key" |
            curl -4 -fsSL --max-time 20 -A "$UA" --config -) || fail "Wallhaven did not answer"
    else
        meta=$(curl -4 -fsSL --max-time 20 -A "$UA" "$api") || fail "Wallhaven did not answer"
    fi
    url=$(printf '%s' "$meta" | jq -r '.data.path // ""' 2>/dev/null || true)
    total=$(printf '%s' "$meta" | jq -r '.data.file_size // 0' 2>/dev/null || echo 0)
    [ -n "$url" ] && [ "$url" != "null" ] || fail "no image for $id"

    ext="${url##*.}"
    ext="${ext%%[?&]*}"
    [[ "$ext" =~ ^[A-Za-z0-9]{2,5}$ ]] || ext=jpg
    out="$dir/wallhaven-$id.$ext"
    sidecar="${out%.*}.json"

    # Keep the Wallhaven metadata beside the image so local search can use the
    # tags and a readable name without asking the network again.
    tags=$(printf '%s' "$meta" | jq -c '[.data.tags[]?.name // empty] | map(select(. != ""))' 2>/dev/null || echo '[]')
    name=$(printf '%s' "$meta" | jq -r '[(.data.tags // [])[]?.name // empty] | map(select(. != "")) | join(", ")' 2>/dev/null || true)
    [ -n "$name" ] || name="wallhaven-$id"
    # Keep a user's per-wallpaper mode override when this download rewrites
    # the metadata file.
    existing_mode=$(jq -r '(.themeMode // .mode // empty)' "$sidecar" 2>/dev/null || true)
    case "$existing_mode" in
        dark | light) ;;
        *) existing_mode="" ;;
    esac
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg id "$id" --arg name "$name" --argjson tags "$tags" \
            --arg url "$(printf '%s' "$meta" | jq -r '.data.url // ""' 2>/dev/null || true)" \
            --arg source "$(printf '%s' "$meta" | jq -r '.data.source // ""' 2>/dev/null || true)" \
            --arg purity "$(printf '%s' "$meta" | jq -r '.data.purity // ""' 2>/dev/null || true)" \
            --arg category "$(printf '%s' "$meta" | jq -r '.data.category // ""' 2>/dev/null || true)" \
            --arg resolution "$(printf '%s' "$meta" | jq -r '.data.resolution // ""' 2>/dev/null || true)" \
            --argjson fileSize "$total" \
            --argjson colors "$(printf '%s' "$meta" | jq -c '.data.colors // []' 2>/dev/null || echo '[]')" \
            --arg themeMode "$existing_mode" \
            '{id:$id,name:$name,tags:$tags,url:$url,source:$source,purity:$purity,category:$category,resolution:$resolution,fileSize:$fileSize,colors:$colors} + (if $themeMode == "" then {} else {themeMode:$themeMode} end)' \
            >"$sidecar.tmp" 2>/dev/null && mv -f "$sidecar.tmp" "$sidecar"
    fi

    if [ ! -s "$out" ]; then
        lock="$HOME/.cache/lucid/remote-wall-$id.lock"
        mkdir -p "$(dirname "$lock")"
        # One writer per image. A helper left over from a shell restart holds
        # this lock, so the resumed job waits for it instead of racing it.
        if command -v flock >/dev/null 2>&1; then
            exec 9>"$lock"
            flock -w 180 9 || fail "timed out waiting for another download of this image"
        fi
        if [ ! -s "$out" ]; then
            # A stable part name lets a restarted download continue instead of
            # throwing away everything it already fetched.
            tmp="$out.part"
            have=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
            if [ "$total" -gt 0 ] 2>/dev/null && [ "$have" = "$total" ]; then
                :
            else
                write_progress downloading 0 "$total" "Downloading"
                curl -4 -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 600 \
                    -A "$UA" -C - -o "$tmp" "$url" &
                dl=$!
                while kill -0 "$dl" 2>/dev/null; do
                    now=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
                    pct=0
                    [ "$total" -gt 0 ] 2>/dev/null && pct=$((now * 100 / total))
                    write_progress downloading "$pct" "$total" "Downloading"
                    sleep 0.25
                done
                if ! wait "$dl"; then
                    # keep the partial: the next attempt resumes it
                    write_progress error 0 "$total" "Download failed"
                    fail "could not download the image"
                fi
            fi
            [ -s "$tmp" ] || fail "downloaded image is empty"
            have=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
            if [ "$total" -gt 0 ] 2>/dev/null && [ "$have" != "$total" ]; then
                fail "downloaded image is incomplete"
            fi
            mv -f "$tmp" "$out" || fail "could not write $out"
        fi
    fi

    if [ "${REMOTE_WALL_SKIP_APPLY:-0}" = "1" ]; then
        write_progress done 100 "$total" "Downloaded"
        printf '%s\n' "$out"
        exit 0
    fi
    write_progress applying 100 "$total" "Applying"
    "$SET_WALL" "$out" || fail "could not apply $out"
    write_progress done 100 "$total" "Applied"
    ;;

steam)
    id="${2:-}"
    PROGRESS="${3:-}"
    [[ "$id" =~ ^[0-9]+$ ]] || fail "bad Workshop id"
    item="$WORKSHOP_DIR/$id"

    apply_scene() {
        if [ "${REMOTE_WALL_SKIP_APPLY:-0}" = "1" ]; then
            write_progress done 100 0 "Installed"
            printf '%s\n' "skwd:we:$id"
            exit 0
        fi
        write_progress applying 0 0 "Applying"
        # the library may not have scanned the new folder yet; list forces a
        # rescan. Prefer the author preview as the palette sample so a just
        # downloaded scene does not race the thumbnail scanner.
        skwd-helm list >/dev/null 2>&1 || true
        sample=""
        for f in "$item/preview.gif" "$item/preview.jpg" "$item/preview.png"; do
            if [ -f "$f" ]; then sample="$f"; break; fi
        done
        if [ -n "$sample" ]; then
            SKWD_SAMPLE="$sample" "$SET_WALL" "skwd:we:$id" || skwd-helm apply "we:$id" >/dev/null 2>&1 || fail "could not apply Workshop item $id"
        elif ! "$SET_WALL" "skwd:we:$id"; then
            skwd-helm apply "we:$id" >/dev/null 2>&1 || fail "could not apply Workshop item $id"
        fi
        write_progress done 100 0 "Applied"
    }

    if [ -d "$item" ]; then
        apply_scene
        exit 0
    fi

    # skwd's own Steam backend (skwd-deck-steamworks): it subscribes through the
    # running Steam client and downloads with ISteamUGC. This is the preferred
    # path; the Steam page below is only the fallback.
    if command -v skwd-steam >/dev/null 2>&1; then
        if ! pgrep -x steam >/dev/null 2>&1; then
            nohup steam -silent >/dev/null 2>&1 &
            sleep 5
        fi

        steam_log="$HOME/.cache/lucid/skwd-steam-$id.log"
        mkdir -p "$(dirname "$steam_log")"
        write_progress waiting 0 100 "Preparing Steam"
        skwd-steam "$id" >"$steam_log" 2>&1 &
        spid=$!
        last=""
        last_status=""
        last_message=""
        while kill -0 "$spid" 2>/dev/null; do
            line=$(tail -n1 "$steam_log" 2>/dev/null || true)
            if [ -n "$line" ] && [ "$line" != "$last" ] && printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
                last="$line"
                st=$(printf '%s' "$line" | jq -r '.status // ""' 2>/dev/null || true)
                pr=$(printf '%s' "$line" | jq -r '.progress // 0' 2>/dev/null || echo 0)
                msg=$(printf '%s' "$line" | jq -r '.message // ""' 2>/dev/null || true)
                folder=$(printf '%s' "$line" | jq -r '.folder // ""' 2>/dev/null || true)
                last_status="$st"
                last_message="$msg"
                [ -n "$folder" ] && [ -d "$folder" ] && item="$folder"
                pct=$(awk -v p="$pr" 'BEGIN { x = p <= 1 ? p * 100 : p; if (x < 0) x = 0; if (x > 100) x = 100; printf "%.0f", x }')
                case "$st" in
                error) write_progress error 0 100 "$msg" ;;
                installed | complete) write_progress applying 100 100 "$msg" ;;
                subscribed | downloading | installing) write_progress downloading "$pct" 100 "$msg" ;;
                *) [ -n "$msg" ] && write_progress waiting "$pct" 100 "$msg" ;;
                esac
            fi
            sleep 0.3
        done
        wait "$spid" 2>/dev/null || true
        sleep 0.5
        if [ -d "$item" ]; then
            apply_scene
            exit 0
        fi
        # Parallel subscriptions can collide inside the Steam client; one
        # clean retry is cheaper than surfacing a transient failure.
        if [ "$last_status" = "error" ]; then
            write_progress waiting 0 100 "Retrying Steam"
            sleep 2
            if skwd-steam "$id" >>"$steam_log" 2>&1; then
                sleep 0.5
                if [ -d "$item" ]; then
                    apply_scene
                    exit 0
                fi
            fi
            fail "${last_message:-could not install Workshop item $id}"
        fi
    fi

    write_progress waiting 0 0 "Subscribe in Steam"
    command -v xdg-open >/dev/null 2>&1 && xdg-open "steam://url/CommunityFilePage/$id" >/dev/null 2>&1 || true
    notify "Subscribe to this scene in Steam; it will apply when it finishes."
    for _ in $(seq 1 45); do
        sleep 2
        [ -d "$item" ] && apply_scene && exit 0
    done
    write_progress error 0 0 "Not installed"
    fail "Workshop item $id was not installed"
    ;;

*)
    echo "usage: $(basename "$0") wallhaven <id> <dir> [progress] | steam <id> [progress]" >&2
    exit 2
    ;;
esac
