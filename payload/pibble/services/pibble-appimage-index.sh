#!/usr/bin/env bash
# pibble-appimage-index: expose every AppImage under /opt in the pibble app
# menu (which reads XDG .desktop files). Re-runnable and duplicate-safe: an
# AppImage whose path already appears in any existing .desktop Exec= line is
# skipped, so the hand-maintained ComfyUI entry (comfy-desktop-nogpu.desktop,
# with its --disable-gpu workaround) never gains a second tile.
#
# Usage: pibble-appimage-index.sh [--dir DIR] (default DIR=/opt)
set -u
DIR="/opt"
case "${1:-}" in --dir=*) DIR="${1#--dir=}" ;; /*) DIR="$1" ;; esac
APP_DIR="${HOME}/.local/share/applications"
mkdir -p "$APP_DIR"

# All Exec= targets currently known, one per line (first token only, unquoted)
known=$(mktemp)
for d in "$HOME/.local/share/applications" /usr/share/applications /usr/local/share/applications; do
  [ -d "$d" ] || continue
  for f in "$d"/*.desktop; do
    [ -f "$f" ] || continue
    line=$(sed -n 's/^Exec=//p' "$f" | head -n 1)
    [ -n "$line" ] || continue
    # first token, honoring double quotes
    first=$(printf '%s' "$line" | sed -n 's/^ *"\([^"]*\)".*/\1/p')
    [ -z "$first" ] && first=$(printf '%s' "$line" | awk '{print $1}')
    # resolve env wrappers (env FOO=bar /real/bin): keep last absolute token
    for tok in $line; do
      t=$(printf '%s' "$tok" | sed 's/^"//; s/"$//')
      case "$t" in /*) first="$t" ;; esac
    done
    printf '%s\n' "$first" >> "$known"
  done
done

added=0
skipped=0
while IFS= read -r img; do
  [ -n "$img" ] || continue
  real=$(realpath "$img" 2>/dev/null || printf '%s' "$img")
  # dedup: already launched by some .desktop entry (e.g. ComfyUI)?
  dup=0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    kr=$(realpath "$k" 2>/dev/null || printf '%s' "$k")
    if [ "$kr" = "$real" ]; then dup=1; break; fi
  done < "$known"
  if [ "$dup" = "1" ]; then
    echo "skip (already indexed): $img"
    skipped=$((skipped + 1))
    continue
  fi
  chmod +x "$img" 2>/dev/null || true
  base=$(basename "$img" .AppImage)
  safe=$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-')
  f="$APP_DIR/pibble-appimage-${safe}.desktop"
  esc=$(printf '%s' "$img" | sed 's/\\/\\\\/g; s/"/\\"/g; s/`/\\`/g; s/\$/\\$/g')
  name=$(printf '%s' "$base" | sed 's/[-_]/ /g; s/  */ /g')
  cat > "$f" <<EOF
[Desktop Entry]
Type=Application
Name=${name}
Comment=AppImage: ${esc}
Exec="${esc}" %U
Icon=application-x-executable
Terminal=false
Categories=Utility;
NoDisplay=false
StartupNotify=true
X-Pibble-Source=appimage-index
X-Pibble-Path=${esc}
EOF
  printf '%s\n' "$img" >> "$known"
  echo "added: $img -> $(basename "$f")"
  added=$((added + 1))
done < <(find "$DIR" -type f -iname "*.AppImage" 2>/dev/null | sort -u)

rm -f "$known"
update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
echo "pibble-appimage-index: $added added, $skipped skipped (already indexed)"
