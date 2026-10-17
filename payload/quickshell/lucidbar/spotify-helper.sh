#!/usr/bin/env bash
# lucid spotify-helper: exact track search + liked-songs via Spotify Web API.
# Network via curl only, JSON via jq. No secrets on the command line.
# Config lives next to this script in spotify.json (mode 600):
#   {"client_id":"...","refresh_token":"...","access_token":"...","access_expires_at":0}
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CFG="$DIR/spotify.json"
REDIRECT_URI="http://127.0.0.1:8888/callback"
SCOPE_ENC="user-library-read%20user-library-modify"

err() { printf '{"error":%s}\n' "$(printf '%s' "$1" | jq -Rs .)"; }

for dep in curl jq openssl; do
  command -v "$dep" >/dev/null 2>&1 || { err "missing dependency: $dep"; exit 1; }
done

cmd_setup() {
  cat <<EOF
Lucid Spotify setup (one time, ~2 min):
  1. Create an app at https://developer.spotify.com/dashboard
     - any name, e.g. "lucidbar"
  2. In the app settings, add this Redirect URI exactly:
       $REDIRECT_URI
  3. Copy the Client ID, then run:
       sh $DIR/spotify-helper.sh login
     (paste the Client ID when asked, approve in the browser,
      then paste back the redirect URL - no local server needed)
  4. Test: sh $DIR/spotify-helper.sh search "Gigi D'Agostino L'amour Toujours"
Notes:
  - Exact-track open + Like sync need this. Without it the bar falls
    back to search links (Shazam/Spotify) and local-only likes.
  - Tokens stay in $CFG (chmod 600). Scopes: read + modify library.
EOF
}

# Print a valid user access token (refresh when expired). force=1 bypasses cache.
get_token() {
  local force="${1:-0}"
  [ -f "$CFG" ] || { err "not_configured: run spotify-helper.sh setup, then login"; return 1; }
  local cid rt at exp now
  cid="$(jq -r '.client_id // empty' "$CFG")"
  rt="$(jq -r '.refresh_token // empty' "$CFG")"
  [ -n "$cid" ] && [ -n "$rt" ] || { err "not_configured: missing client_id/refresh_token, run login"; return 1; }
  at="$(jq -r '.access_token // empty' "$CFG")"
  exp="$(jq -r '.access_expires_at // 0' "$CFG")"
  now="$(date +%s)"
  if [ "$force" = "0" ] && [ -n "$at" ] && [ "$exp" -gt $((now + 60)) ]; then
    printf '%s' "$at"
    return 0
  fi
  local resp nat nexp tmp
  resp="$(curl -s --max-time 20 -X POST https://accounts.spotify.com/api/token \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "refresh_token=$rt" \
    --data-urlencode "client_id=$cid")" || { err "network error refreshing token"; return 1; }
  nat="$(printf '%s' "$resp" | jq -r '.access_token // empty')"
  if [ -z "$nat" ]; then
    err "token refresh failed: $(printf '%s' "$resp" | jq -c '{error,error_description}')"
    return 1
  fi
  nexp=$((now + $(printf '%s' "$resp" | jq -r '.expires_in // 3600')))
  tmp="$(mktemp)" || { err "tmpfile failed"; return 1; }
  jq --arg a "$nat" --argjson e "$nexp" '.access_token=$a | .access_expires_at=$e' "$CFG" > "$tmp" \
    && mv "$tmp" "$CFG" && chmod 600 "$CFG"
  printf '%s' "$nat"
}

cmd_login() {
  local cid="${1:-}"
  if [ -z "$cid" ] && [ -f "$CFG" ]; then cid="$(jq -r '.client_id // empty' "$CFG")"; fi
  if [ -z "$cid" ]; then printf 'Spotify Client ID: ' >&2; read -r cid; fi
  [ -n "$cid" ] || { echo "no client id given, aborting" >&2; exit 2; }
  local verifier challenge url pasted code resp rt at exp tmp now
  verifier="$(openssl rand -base64 48 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"
  challenge="$(printf '%s' "$verifier" | openssl dgst -binary -sha256 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  url="https://accounts.spotify.com/authorize?response_type=code&client_id=${cid}&scope=${SCOPE_ENC}&redirect_uri=${REDIRECT_URI}&code_challenge=${challenge}&code_challenge_method=S256"
  echo "1. Open this URL, approve, then copy the FULL redirect URL from the address bar:" >&2
  echo "$url" >&2
  echo "2. Paste the redirect URL (or just the code) here:" >&2
  read -r pasted
  code="$(printf '%s' "$pasted" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
  [ -n "$code" ] || code="$pasted"
  [ -n "$code" ] || { echo "no code given, aborting" >&2; exit 2; }
  resp="$(curl -s --max-time 20 -X POST https://accounts.spotify.com/api/token \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$REDIRECT_URI" \
    --data-urlencode "client_id=$cid" \
    --data-urlencode "code_verifier=$verifier")" || { echo "network error during exchange" >&2; exit 1; }
  rt="$(printf '%s' "$resp" | jq -r '.refresh_token // empty')"
  if [ -z "$rt" ]; then
    echo "login failed: $(printf '%s' "$resp" | jq -c '{error,error_description}')" >&2
    exit 1
  fi
  at="$(printf '%s' "$resp" | jq -r '.access_token // empty')"
  now="$(date +%s)"
  exp=$((now + $(printf '%s' "$resp" | jq -r '.expires_in // 3600')))
  tmp="$(mktemp)" || exit 1
  if [ -f "$CFG" ]; then cp "$CFG" "$tmp"; else printf '{}' > "$tmp"; fi
  jq --arg c "$cid" --arg r "$rt" --arg a "$at" --argjson e "$exp" \
    '.client_id=$c | .refresh_token=$r | .access_token=$a | .access_expires_at=$e' "$tmp" > "$tmp.new" \
    && mv "$tmp.new" "$CFG" && chmod 600 "$CFG" && rm -f "$tmp"
  echo "login ok - refresh token saved to $CFG" >&2
  printf '{"ok":true}\n'
}

cmd_search() {
  [ $# -ge 1 ] || { err "usage: search <query>"; exit 1; }
  local q="$*" tok resp code body item
  tok="$(get_token)" || { [ -n "$tok" ] && printf '%s\n' "$tok"; exit 1; }
  resp="$(curl -s --max-time 20 -G "https://api.spotify.com/v1/search" \
    --data-urlencode "q=$q" --data-urlencode "type=track" --data-urlencode "limit=1" \
    -H "Authorization: Bearer $tok" -w '\n%{http_code}')" || { err "network error (search)"; exit 1; }
  code="$(printf '%s' "$resp" | tail -n 1)"
  body="$(printf '%s' "$resp" | head -n -1)"
  if [ "$code" = "401" ]; then
    tok="$(get_token 1)" || { [ -n "$tok" ] && printf '%s\n' "$tok"; exit 1; }
    resp="$(curl -s --max-time 20 -G "https://api.spotify.com/v1/search" \
      --data-urlencode "q=$q" --data-urlencode "type=track" --data-urlencode "limit=1" \
      -H "Authorization: Bearer $tok" -w '\n%{http_code}')" || { err "network error (search)"; exit 1; }
    code="$(printf '%s' "$resp" | tail -n 1)"
    body="$(printf '%s' "$resp" | head -n -1)"
  fi
  [ "$code" = "200" ] || { err "search failed (http $code)"; exit 1; }
  item="$(printf '%s' "$body" | jq -c '.tracks.items[0] // empty')"
  [ -n "$item" ] || { err "not_found"; exit 1; }
  printf '%s' "$item" | jq -c '{id, name, artists: ([.artists[].name] | join(", ")), url: .external_urls.spotify, uri}'
}

cmd_contains() {
  [ $# -ge 1 ] || { err "usage: like-status <trackId>"; exit 1; }
  local id="$1" tok resp code body
  tok="$(get_token)" || { [ -n "$tok" ] && printf '%s\n' "$tok"; exit 1; }
  resp="$(curl -s --max-time 20 -G "https://api.spotify.com/v1/me/tracks/contains" \
    --data-urlencode "ids=$id" -H "Authorization: Bearer $tok" -w '\n%{http_code}')" \
    || { err "network error (like-status)"; exit 1; }
  code="$(printf '%s' "$resp" | tail -n 1)"
  body="$(printf '%s' "$resp" | head -n -1)"
  [ "$code" = "200" ] || { err "like-status failed (http $code)"; exit 1; }
  printf '{"liked":%s}\n' "$(printf '%s' "$body" | jq -r '.[0] // false')"
}

cmd_set_saved() {
  local method="$1"; shift
  [ $# -ge 1 ] || { err "usage: like|unlike <trackId>"; exit 1; }
  local id="$1" tok code
  tok="$(get_token)" || { [ -n "$tok" ] && printf '%s\n' "$tok"; exit 1; }
  code="$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' -X "$method" \
    "https://api.spotify.com/v1/me/tracks?ids=$(printf '%s' "$id" | jq -sRr @uri)" \
    -H "Authorization: Bearer $tok" -H "Content-Length: 0")" \
    || { err "network error (save)"; exit 1; }
  [ "$code" = "200" ] || { err "save failed (http $code)"; exit 1; }
  printf '{"ok":true}\n'
}

case "${1:-}" in
  setup) cmd_setup ;;
  login) shift; cmd_login "${1:-}" ;;
  search) shift; cmd_search "$@" ;;
  like-status) shift; cmd_contains "$@" ;;
  like) shift; cmd_set_saved PUT "$@" ;;
  unlike) shift; cmd_set_saved DELETE "$@" ;;
  *)
    echo "usage: $(basename "$0") {setup|login [client-id]|search <query>|like-status <id>|like <id>|unlike <id>}" >&2
    exit 2
    ;;
esac
