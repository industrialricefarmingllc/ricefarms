#!/usr/bin/env bash
# pibble-zen-domains-index: expose domains visited in Zen (not specific pages)
# to the pibble app menu. Zen-specific by design: there is no generic history
# API, and Zen/Firefox keep this in places.sqlite's moz_origins table.
# Writes "$HOME/.cache/pibble-zen-domains.txt", one `id<TAB>url` row per host -
# the Index service (services/Index.qml) reads this file at daemon start, so
# a cold start parses one small text file instead of hundreds of .desktop
# files. Re-runnable and idempotent: same host -> same id (sha1).
set -u

ZEN_DIR="${HOME}/.config/zen"
INDEX_FILE="${HOME}/.cache/pibble-zen-domains.txt"

# Resolve the default profile dir from profiles.ini (Install* Default wins,
# else the ProfileN block with Default=1).
profile=$(awk -F= '
  /^\[Install/ { in_install=1; next }
  /^\[/ { in_install=0 }
  in_install && $1 == "Default" { install_default=$2 }
  END { print install_default }
' "$ZEN_DIR/profiles.ini" 2>/dev/null)
if [ -z "$profile" ]; then
  profile=$(awk -F= '
    /^\[Profile/ { is_default=0; path=""; next }
    $1 == "Default" && $2 == "1" { is_default=1 }
    $1 == "Path" { path=$2 }
    is_default && path != "" { print path; exit }
  ' "$ZEN_DIR/profiles.ini" 2>/dev/null)
fi
if [ -z "$profile" ]; then
  echo "pibble-zen-domains-index: no default Zen profile found" >&2
  exit 1
fi
case "$profile" in /*) PROF_DIR="$profile" ;; *) PROF_DIR="$ZEN_DIR/$profile" ;; esac
DB="$PROF_DIR/places.sqlite"
if [ ! -f "$DB" ]; then
  echo "pibble-zen-domains-index: no places.sqlite in $PROF_DIR" >&2
  exit 1
fi

# Zen may be running (DB locked): query a throwaway copy.
TMPDB=$(mktemp)
trap 'rm -f "$TMPDB"' EXIT
cp -f "$DB" "$TMPDB"

mkdir -p "$(dirname "$INDEX_FILE")"
python3 - "$TMPDB" "$INDEX_FILE" <<'PYEOF'
import hashlib, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
# One row per host (a host can appear under both http and https in
# moz_origins); keep the https origin when both exist.
seen = {}
for prefix, host in db.execute(
    "select prefix, host from moz_origins where prefix in ('http://','https://')"):
    if not host or ' ' in host or '/' in host:
        continue
    prev = seen.get(host)
    if prev is None or prefix == 'https://':
        seen[host] = prefix
rows = []
for host in sorted(seen):
    digest = hashlib.sha1(host.encode()).hexdigest()[:16]
    rows.append("pibble-web-%s\t%s%s\n" % (digest, seen[host], host))
with open(sys.argv[2], "w") as f:
    f.writelines(rows)
print("pibble-zen-domains-index: %d domains -> %s" % (len(rows), sys.argv[2]))
PYEOF
