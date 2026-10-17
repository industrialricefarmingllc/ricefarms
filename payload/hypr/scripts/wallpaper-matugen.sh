#!/bin/bash
# Uniform palette from wallpaper - matugen + awww + quickshell TopBar
set -e
WALL="${1:-$HOME/Pictures/Wallpapers/wallhaven-og13vm.png}"
EXPLICIT_MODE="${2:-}"
[ -f "$WALL" ] || { echo "not found: $WALL" >&2; exit 1; }
# Save for launch restore (unified: hypr + quickshell lucid + matugen all stay in sync)
mkdir -p "$HOME/.cache" "$HOME/.config/hypr" "$HOME/.config/quickshell/luciddocks"
echo "$WALL" > "$HOME/.cache/hypr_last_wallpaper"
echo "$WALL" > "$HOME/.config/hypr/current_wallpaper"
echo "$WALL" > "$HOME/.cache/current_wallpaper"
# Lucid dock's wallpaper.json is the source for Dock.qml:wallpaperState.current
# Update it so Dock's appliedWallpaper doesn't diverge from hypr_last
if command -v jq >/dev/null 2>&1; then
  jq -n --arg p "$WALL" '{current:$p}' > "$HOME/.config/quickshell/luciddocks/wallpaper.json.tmp" && mv -f "$HOME/.config/quickshell/luciddocks/wallpaper.json.tmp" "$HOME/.config/quickshell/luciddocks/wallpaper.json"
else
  printf '{\n    "current": "%s"\n}\n' "$WALL" > "$HOME/.config/quickshell/luciddocks/wallpaper.json"
fi
# MODE handling:
# - if explicit $2 given (from theme-toggle.sh), use it and sync theme files immediately
# - else auto-detect from wallpaper luminance (measure image, default for all)
AUTO_MODE=0
if [[ -n "$EXPLICIT_MODE" ]]; then
  MODE="$EXPLICIT_MODE"
  echo "$MODE" > "$HOME/.cache/hypr_last_wallpaper_mode"
  mkdir -p "$HOME/.cache/quickshell"
  printf '%s' "$MODE" > "$HOME/.cache/quickshell/theme_mode.tmp" && mv -f "$HOME/.cache/quickshell/theme_mode.tmp" "$HOME/.cache/quickshell/theme_mode"
  if command -v gsettings >/dev/null 2>&1; then
    if [[ "$MODE" == "light" ]]; then gsettings set org.gnome.desktop.interface color-scheme 'prefer-light' 2>/dev/null || true; else gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true; fi
  fi
else
  AUTO_MODE=0
  # measure wallpaper luminance via ffmpeg 1x1 average (generic, not hardcoded)
  # lum >0.25 → light, else dark (qz9l2d 0.27→light, night 0.005→dark, qz15r7 0.47→light)
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -y -i "$WALL" -vf "scale=1:1:flags=area" -f rawvideo -pix_fmt rgb24 /tmp/onepixel.rgb 2>/dev/null || true
    MODE=$(python3 - << 'PY' 2>/dev/null || echo dark
try:
    with open('/tmp/onepixel.rgb','rb') as f:
        d=f.read()
        if len(d)>=3:
            r,g,b=d[0],d[1],d[2]
            def lin(c): return c/255/12.92 if c/255<=0.04045 else ((c/255+0.055)/1.055)**2.4
            # use sRGB relative luminance
            lum=0.2126*lin(r)+0.7152*lin(g)+0.0722*lin(b)
            # also consider simple avg brightness as fallback for very saturated images
            avg=(r+g+b)/3
            # bright enough for light if lum>0.15 or avg>140 and lum>0.15
            if lum>0.15 or (avg>135 and lum>0.15):
                print('light')
            else:
                print('dark')
        else:
            print('dark')
except: print('dark')
PY
)
  else
    MODE="dark"
  fi
  # fallback to dark if detection failed
  [[ "$MODE" != "light" && "$MODE" != "dark" ]] && MODE="dark"
  touch /tmp/matugen-theme-toggle.lock
  echo "$MODE" > "$HOME/.cache/hypr_last_wallpaper_mode"
  mkdir -p "$HOME/.cache/quickshell"
  printf '%s' "$MODE" > "$HOME/.cache/quickshell/theme_mode.tmp" && mv -f "$HOME/.cache/quickshell/theme_mode.tmp" "$HOME/.cache/quickshell/theme_mode"
  if command -v gsettings >/dev/null 2>&1; then
    if [[ "$MODE" == "light" ]]; then gsettings set org.gnome.desktop.interface color-scheme 'prefer-light' 2>/dev/null || true; else gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true; fi
  fi
  echo "→ measured luminance for $WALL → $MODE"
fi
# Also keep hyprpaper.conf in sync for compatibility
cat > "$HOME/.config/hypr/hyprpaper.conf" <<EOF2
preload = $WALL

wallpaper {
    monitor = DP-1
    path = $WALL
}

wallpaper {
    monitor =
    path = $WALL
}

splash = false
ipc = on
EOF2
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -n1)
# Fallback via hyprctl instances if ls fails
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || [ ! -e "/run/user/$(id -u)/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock" ]; then
  SIG=$(hyprctl instances 2>/dev/null | grep -oP 'instance \K[^:]+' | tail -n1 || true)
  [ -n "$SIG" ] && export HYPRLAND_INSTANCE_SIGNATURE="$SIG" || true
fi
# 1) set wallpaper via awww (matugen wallpaper set=false, so we do it here)
awww img "$WALL" --transition-type wipe --transition-duration 1.2 2>/dev/null || awww img "$WALL" 2>/dev/null || true
# 1b) save old AgX shader for smooth 250ms transition (agx-smooth-transition.sh needs old)
cp -f "$HOME/.config/hypr/shaders/matugen-agx.glsl" "/tmp/matugen-agx-old.glsl" 2>/dev/null || true
# 2) generate uniform palette (hyprland borders, foot, dunst via matugen templates)
matugen image "$WALL" -m "$MODE" 2>&1 | tail -n 20
# 2b) GTK system elements: pure-black in dark, stock in light (Nautilus/Loupe)
"$HOME/.config/hypr/scripts/apply-gtk-mode.sh" "$MODE" 2>&1 | tail -n 5 || true
# Softer font colors for light theme (matugen light is harsh #191c20 on #f9f9ff)
if [[ "$MODE" == "light" ]]; then
  python3 - << 'PY' 2>/dev/null || true
import json, pathlib, re
mj = pathlib.Path.home() / ".cache/quickshell/matugen.json"
kp = pathlib.Path.home() / ".config/kitty/matugen-colors.conf"
try:
    d=json.load(open(mj))
    # use on_surface_variant as softer foreground for light
    soft = d.get('on_surface_variant') or d.get('on_surface') or '#44474e'
    # fallback if soft is same as hard, keep it
    hard = d.get('on_surface') or '#191c20'
    # only soften if soft != hard
    if soft and soft != hard:
        text = kp.read_text()
        # foreground, cursor, color7 are the harsh black-on-white entries
        text = re.sub(r'^foreground\s+.*', f'foreground            {soft}', text, flags=re.M)
        text = re.sub(r'^cursor\s+.*', f'cursor                {soft}', text, flags=re.M)
        # color7 is traditional white but in light theme it's dark hard
        text = re.sub(r'^color7\s+.*', f'color7                {soft}', text, flags=re.M)
        kp.write_text(text)
        print(f"softened {hard} -> {soft}")
except Exception as e:
    print(f"soften failed {e}")
PY
  pkill -SIGUSR1 kitty 2>/dev/null || true
  echo "→ softened kitty light theme (foreground → on_surface_variant)"
fi
# Much more saturated kitty — only strong primary/secondary/tertiary (not neutrals/error)
python3 - << 'PY' 2>/dev/null || true
import pathlib, re, colorsys, json
kp = pathlib.Path.home() / ".config/kitty/matugen-colors.conf"
mj = pathlib.Path.home() / ".cache/quickshell/matugen.json"
try:
    text = kp.read_text()
    d=json.load(open(mj))
    # strong colors to boost — primary/secondary/tertiary families
    keys = ["primary","on_primary","primary_container","on_primary_container",
            "secondary","on_secondary","secondary_container","on_secondary_container",
            "tertiary","on_tertiary","tertiary_container","on_tertiary_container",
            "primary_fixed","on_primary_fixed","primary_fixed_dim","on_primary_fixed_variant",
            "secondary_fixed","on_secondary_fixed","secondary_fixed_dim","on_secondary_fixed_variant",
            "tertiary_fixed","on_tertiary_fixed","tertiary_fixed_dim","on_tertiary_fixed_variant"]
    strong = set()
    for k in keys:
        v=d.get(k)
        if v and isinstance(v,str) and v.startswith('#'):
            strong.add(v.lower())
            strong.add(v.upper())
    # also include without case
    strong_lower = {s.lower() for s in strong}
    def boost(hexcol, factor=4.0, min_s=1.0):
        lc=hexcol.lower()
        if lc not in strong_lower:
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
        print(f"boosted {len([1 for a,b in zip(text.split(), new_text.split()) if a!=b])} strong colors")
    else:
        print("no strong colors to boost")
except Exception as e:
    print(f"boost failed {e}")
PY
pkill -SIGUSR1 kitty 2>/dev/null || true
echo "→ boosted primary/secondary/tertiary saturation"
echo "→ hyprland borders reloaded from $WALL ($MODE)"
# 3) quickshell Theme now watches ~/.cache/quickshell/matugen.json directly (Theme.qml FileView)
#    -> no need to patch old lib/usersettings.json (removed in lucid migration) and no need to HUP/restart qs.
#    matugen's post_hook already does `hyprctl reload` for borders; Theme.qml auto-reloads via watchChanges.
if [ -f "$HOME/.cache/quickshell/matugen-colors.txt" ]; then
  PRIMARY=$(grep -oP 'primary=\K#[0-9a-fA-F]+' ~/.cache/quickshell/matugen-colors.txt 2>/dev/null | head -n1)
  [ -n "$PRIMARY" ] && echo "→ quickshell accent $PRIMARY (via matugen.json watch, no restart needed)"
fi
