#!/usr/bin/env bash
# Build liblucidgtk.so — the GTK4 live gtk.css reload shim (see lucid-gtk-css.c)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HOME/.local/lib/liblucidgtk.so}"
mkdir -p "$(dirname "$OUT")"
cc -shared -fPIC -O2 -o "$OUT" "$HERE/lucid-gtk-css.c" $(pkg-config --cflags --libs gtk4) -ldl
echo "built $OUT"
