#!/usr/bin/env bash
# pibble-pdf-index: index all local PDFs for the pibble app menu.
# Writes "$HOME/.cache/pibble-pdf-index.txt", one `id<TAB>path` row per PDF -
# the Index service (services/Index.qml) reads this file at daemon start, so
# a cold start parses one small text file instead of hundreds of .desktop
# files. Re-runnable and idempotent: same path -> same id (sha1).
#
# Usage:
#   pibble-pdf-index.sh [--index-file PATH] [--no-scan]
#   default: rescan the local filesystem for *.pdf (mounted volumes and
#   pseudo-filesystems excluded); --no-scan keeps the existing index file.
set -u
INDEX_FILE="${HOME}/.cache/pibble-pdf-index.txt"
SCAN=1
for a in "$@"; do
  case "$a" in
    --index-file=*) INDEX_FILE="${a#--index-file=}" ;;
    --no-scan) SCAN=0 ;;
  esac
done

if [ "$SCAN" = "1" ]; then
  mkdir -p "$(dirname "$INDEX_FILE")"
  find / -type d \( -path /proc -o -path /sys -o -path /dev -o -path /run \
    -o -path /tmp -o -path /mnt -o -path /media -o -path /boot \
    -o -path /var/tmp -o -path /var/cache \) -prune \
    -o -type f -iname "*.pdf" -print 2>/dev/null | sort -u > "$INDEX_FILE.raw"
  : > "$INDEX_FILE.tmp"
  while IFS= read -r pdf; do
    [ -n "$pdf" ] || continue
    id="pibble-pdf-$(printf '%s' "$pdf" | sha1sum | cut -c1-16)"
    printf '%s\t%s\n' "$id" "$pdf" >> "$INDEX_FILE.tmp"
  done < "$INDEX_FILE.raw"
  rm -f "$INDEX_FILE.raw"
  mv "$INDEX_FILE.tmp" "$INDEX_FILE"
fi

count=$(wc -l < "$INDEX_FILE" 2>/dev/null || echo 0)
echo "pibble-pdf-index: $count PDFs -> $INDEX_FILE"
