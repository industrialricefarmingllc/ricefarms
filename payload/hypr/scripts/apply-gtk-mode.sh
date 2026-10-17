#!/bin/bash
# apply-gtk-mode.sh - swap GTK CSS overrides based on dark/light mode.
# dark  -> pure-black system elements (Nautilus, Loupe, libadwaita)
# light -> stock Adwaita (no overrides)
# Usage: apply-gtk-mode.sh [dark|light]  (defaults to theme_mode file, then dark)
set -euo pipefail
MODE="${1:-}"
if [[ -z "$MODE" ]]; then
  MODE=$(cat "$HOME/.cache/quickshell/theme_mode" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || echo dark)
fi
[[ "$MODE" != "light" && "$MODE" != "dark" ]] && MODE="dark"

for ver in "gtk-3.0" "gtk-4.0"; do
  SRC="$HOME/.config/$ver/gtk-$MODE.css"
  DST="$HOME/.config/$ver/gtk.css"
  if [[ -f "$SRC" ]]; then
    cp -f "$SRC" "$DST"
    echo "GTK $ver -> $MODE"
  else
    echo "missing $SRC" >&2
  fi
done

# keep portals/GTK in sync (libadwaita reads color-scheme)
# NOTE: Everforest-Light/Dark themes are not installed (only Default/Emacs
# in /usr/share/themes), so use built-in Adwaita as the predictable base.
# Our gtk.css black override sits on top in dark mode.
if command -v gsettings >/dev/null 2>&1; then
  if [[ "$MODE" == "light" ]]; then
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-light' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita' 2>/dev/null || true
  else
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita' 2>/dev/null || true
  fi
fi

# keep settings.ini base in sync so GTK3 uses the dark variant (prevents
# white-base widgets + white text = white-on-white)
for ver in "gtk-3.0" "gtk-4.0"; do
  INI="$HOME/.config/$ver/settings.ini"
  if [[ "$MODE" == "light" ]]; then
    PREF=0
    THEME="Adwaita"
  else
    PREF=1
    THEME="Adwaita"
  fi
  if [[ -f "$INI" ]]; then
    # update in place if keys exist, else append
    if grep -q "^gtk-application-prefer-dark-theme" "$INI"; then
      sed -i "s/^gtk-application-prefer-dark-theme.*/gtk-application-prefer-dark-theme=$PREF/" "$INI"
    else
      printf 'gtk-application-prefer-dark-theme=%s\n' "$PREF" >> "$INI"
    fi
    if grep -q "^gtk-theme-name" "$INI"; then
      sed -i "s/^gtk-theme-name.*/gtk-theme-name=$THEME/" "$INI"
    else
      printf 'gtk-theme-name=%s\n' "$THEME" >> "$INI"
    fi
  fi
done
