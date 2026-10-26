#!/usr/bin/env bash
# set-wallpaper.sh <path-to-image> [dark|light]
#
# sets the wallpaper, then regenerates colours if the active theme derives
# them from the image. ~/.cache/current_theme decides:
#   matugen  — matugen regenerates every template it is configured for
#   pywal    — wal extracts, gen-pywal-palette.py maps it to material roles
#   anything else — a static theme owns its palette, so colours are left alone
#
# THEME_ONLY=1 derives colours + dark/light mode from the image WITHOUT
# touching the on-screen wallpaper or restore state. Used for animated
# sources (Wallpaper Engine walls, videos) that have no static file to
# set: a cached thumbnail/frame stands in as the sampler image while the
# live backend keeps rendering.
#
# the wallpaper is set first because it is the only step you actually see.

set -euo pipefail

WALLPAPER="${1:-}"
EXPLICIT_MODE="${2:-}"
if [[ -n "$EXPLICIT_MODE" ]]; then
  MODE="$EXPLICIT_MODE"
  AUTO_MODE=0
else
  AUTO_MODE=0
  # dark-area decision: downscale to a 64x64 grid, binarize each cell
  # dark/light on a 0-255 luminance threshold (dark < 100), then dark
  # theme iff dark cells cover >=25% of the grid. No overall-brightness
  # averaging: absence of a large enough dark area means light.
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -y -i "${WALLPAPER/#\~/$HOME}" -vf "scale=64:64:flags=area" -f rawvideo -pix_fmt rgb24 /tmp/wallgrid.rgb 2>/dev/null || true
    MODE=$(python3 - << 'PY' 2>/dev/null || echo dark
try:
    with open('/tmp/wallgrid.rgb','rb') as f:
        d=f.read()
        n=len(d)//3
        if n==0:
            print('dark')
        else:
            dark=sum(1 for i in range(n) if 0.2126*d[3*i]+0.7152*d[3*i+1]+0.0722*d[3*i+2] < 100)
            print('dark' if dark/n >= 0.25 else 'light')
except: print('dark')
PY
)
  else
    MODE="dark"
  fi
  [[ "$MODE" != "light" && "$MODE" != "dark" ]] && MODE="dark"
fi
CACHE_DIR="$HOME/.cache"
CURRENT_WALL_FILE="$CACHE_DIR/current_wallpaper"
CURRENT_THEME_FILE="$CACHE_DIR/current_theme"
LUCID_DIR="$HOME/.config/lucid"

CURRENT_THEME="$(cat "$CURRENT_THEME_FILE" 2>/dev/null || echo matugen)"

usage() {
    echo "usage: $(basename "$0") <path-to-image> [dark|light]"
    exit 1
}

[[ -z "$WALLPAPER" ]] && { echo "error: no wallpaper path given" >&2; usage; }

WALLPAPER="${WALLPAPER/#\~/$HOME}"

[[ -f "$WALLPAPER" ]] || { echo "error: file not found: $WALLPAPER" >&2; exit 1; }

if [[ "$MODE" != "dark" && "$MODE" != "light" ]]; then
    echo "error: mode must be dark or light (got: $MODE)" >&2
    usage
fi
# sync theme_mode for kitty watcher (both explicit and auto measured)
touch /tmp/matugen-theme-toggle.lock
mkdir -p "$HOME/.cache/quickshell"
printf '%s' "$MODE" > "$HOME/.cache/quickshell/theme_mode.tmp" && mv -f "$HOME/.cache/quickshell/theme_mode.tmp" "$HOME/.cache/quickshell/theme_mode"
# lucid 1.20.1 reads its mode from ~/.cache/current_mode (see set-mode.sh)
printf '%s' "$MODE" > "$HOME/.cache/current_mode"
printf '%s' "$MODE" > "$HOME/.cache/hypr_last_wallpaper_mode"
if command -v gsettings >/dev/null 2>&1; then
  if [[ "$MODE" == "light" ]]; then gsettings set org.gnome.desktop.interface color-scheme 'prefer-light' 2>/dev/null || true; else gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true; fi
fi
if [[ -z "$EXPLICIT_MODE" ]]; then
  echo "→ measured dark-area for $WALLPAPER → $MODE"
fi

# wallpaper daemon: awww, falling back to swww. Skipped in THEME_ONLY
# mode — a live backend (linux-wallpaperengine, mpvpaper) owns the screen
# and setting a static image here would fight or kill it.
if [[ "${THEME_ONLY:-0}" != "1" ]]; then
if command -v awww &>/dev/null; then
    WP_CLI=awww; WP_DAEMON=awww-daemon
elif command -v swww &>/dev/null; then
    WP_CLI=swww; WP_DAEMON="swww-daemon"
else
    echo "error: neither awww nor swww is installed" >&2
    exit 1
fi

if ! "$WP_CLI" query &>/dev/null; then
    "$WP_DAEMON" &>/dev/null &
    sleep 0.5
fi

"$WP_CLI" img "$WALLPAPER" \
    --transition-type fade \
    --transition-duration 1 \
    --transition-fps 60
fi

mkdir -p "$CACHE_DIR" "$HOME/.config/hypr" "$HOME/.config/quickshell/luciddocks"
if [[ "${THEME_ONLY:-0}" != "1" ]]; then
printf '%s' "$WALLPAPER" > "$CURRENT_WALL_FILE"
# Unified state: keep hypr and lucid in sync so wallpaper-restore doesn't revert
printf '%s' "$WALLPAPER" > "$HOME/.cache/hypr_last_wallpaper"
printf '%s' "$WALLPAPER" > "$HOME/.config/hypr/current_wallpaper"
if command -v jq >/dev/null 2>&1; then
  jq -n --arg p "$WALLPAPER" '{current:$p}' > "$HOME/.config/quickshell/luciddocks/wallpaper.json.tmp" && mv -f "$HOME/.config/quickshell/luciddocks/wallpaper.json.tmp" "$HOME/.config/quickshell/luciddocks/wallpaper.json"
else
  printf '{\n    "current": "%s"\n}\n' "$WALLPAPER" > "$HOME/.config/quickshell/luciddocks/wallpaper.json"
fi
# Also keep hyprpaper.conf in sync (legacy compat)
cat > "$HOME/.config/hypr/hyprpaper.conf" <<EOF2
preload = $WALLPAPER

wallpaper {
    monitor = DP-1
    path = $WALLPAPER
}

wallpaper {
    monitor =
    path = $WALLPAPER
}

splash = false
ipc = on
EOF2
fi # THEME_ONLY: restore state keeps the last static wallpaper

case "$CURRENT_THEME" in
matugen)
    if ! command -v matugen &>/dev/null; then
        echo "warning: matugen not installed, colours unchanged" >&2
        exit 0
    fi
    # Non-interactive via config `prefer` (currently "saturation", so the
    # vivid subject color wins). Do NOT pass --source-color-index: an
    # explicit index bypasses `prefer` and pins index 0 (most dominant),
    # which picked a cyan background over a red subject (observed live).
    matugen image "$WALLPAPER" -m "$MODE"
    hyprctl reload &>/dev/null || true
    # soften light theme fonts (same as wallpaper-matugen.sh)
    if [[ "$MODE" == "light" ]]; then
      python3 - << 'PY' 2>/dev/null || true
import json, pathlib, re
mj = pathlib.Path.home() / ".cache/quickshell/matugen.json"
kp = pathlib.Path.home() / ".config/kitty/matugen-colors.conf"
try:
    d=json.load(open(mj))
    soft = d.get('on_surface_variant') or d.get('on_surface') or '#44474e'
    hard = d.get('on_surface') or '#191c20'
    if soft and soft != hard:
        text = kp.read_text()
        text = re.sub(r'^foreground\s+.*', f'foreground            {soft}', text, flags=re.M)
        text = re.sub(r'^cursor\s+.*', f'cursor                {soft}', text, flags=re.M)
        text = re.sub(r'^color7\s+.*', f'color7                {soft}', text, flags=re.M)
        kp.write_text(text)
except: pass
PY
      pkill -SIGUSR1 kitty 2>/dev/null || true
    fi
    # boost saturation for kitty — only strong primary/secondary/tertiary
    python3 - << 'PY' 2>/dev/null || true
import pathlib, re, colorsys, json
kp = pathlib.Path.home() / ".config/kitty/matugen-colors.conf"
mj = pathlib.Path.home() / ".cache/quickshell/matugen.json"
try:
    text = kp.read_text()
    d=json.load(open(mj))
    keys = ["primary","on_primary","primary_container","on_primary_container",
            "secondary","on_secondary","secondary_container","on_secondary_container",
            "tertiary","on_tertiary","tertiary_container","on_tertiary_container",
            "primary_fixed","on_primary_fixed","primary_fixed_dim","on_primary_fixed_variant",
            "secondary_fixed","on_secondary_fixed","secondary_fixed_dim","on_secondary_fixed_variant",
            "tertiary_fixed","on_tertiary_fixed","tertiary_fixed_dim","on_tertiary_fixed_variant"]
    strong=set()
    for k in keys:
        v=d.get(k)
        if v and isinstance(v,str) and v.startswith('#'):
            strong.add(v.lower())
    def boost(hexcol, factor=4.0, min_s=1.0):
        if hexcol.lower() not in strong:
            return hexcol
        h=hexcol.lstrip('#')
        if len(h)!=6: return hexcol
        r=int(h[0:2],16)/255; g=int(h[2:4],16)/255; b=int(h[4:6],16)/255
        hl,l,s = colorsys.rgb_to_hls(r,g,b)
        if s < 0.05 or l < 0.05 or l > 0.97:
            return hexcol
        ns = min(1.0, s * factor)
        if ns < min_s:
            ns = min_s
        r2,g2,b2 = colorsys.hls_to_rgb(hl, l, ns)
        return f"#{int(r2*255):02x}{int(g2*255):02x}{int(b2*255):02x}"
    new_text = re.sub(r'#[0-9a-fA-F]{6}', lambda m: boost(m.group(0)), text)
    if new_text != text:
        kp.write_text(new_text)
except: pass
PY
    pkill -SIGUSR1 kitty 2>/dev/null || true
    ;;
pywal)
    if ! command -v wal &>/dev/null; then
        echo "warning: pywal not installed, colours unchanged" >&2
        exit 0
    fi
    # -n leaves the wallpaper alone, it is already set above
    wal -i "$WALLPAPER" -n -s -t -e -q || echo "warning: wal failed" >&2
    if "$LUCID_DIR/gen-pywal-palette.py"; then
        "$LUCID_DIR/apply-theme.sh" pywal
    else
        echo "warning: pywal palette generation failed" >&2
    fi
    hyprctl reload &>/dev/null || true
    ;;
*)
    echo "static theme ($CURRENT_THEME) — colours unchanged"
    ;;
esac

if [[ "${THEME_ONLY:-0}" == "1" ]]; then
    echo "done: $WALLPAPER ($MODE, theme: $CURRENT_THEME, theme-only - wallpaper untouched)"
else
    echo "done: $WALLPAPER ($MODE, theme: $CURRENT_THEME)"
fi
