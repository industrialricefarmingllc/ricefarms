#!/bin/bash
# agx-smooth-transition.sh — inject transitionStart = Hyprland uptime into matugen-agx.glsl for 250ms smooth
set -e
SHADER="$HOME/.config/hypr/shaders/matugen-agx.glsl"
TEMPLATE="$HOME/.config/matugen/templates/hypr-shader-agx.glsl"
# only if AgX is active
CUR=$(cat "$HOME/.cache/quickshell/current_shader" 2>/dev/null | tr -d '[:space:]' || echo "")
if [[ "$CUR" != "AgX" && "$CUR" != "AgX Map" && "$CUR" != "matugen-agx.glsl" ]]; then
  # still reload for borders etc.
  hyprctl reload 2>/dev/null || true &
  exit 0
fi
# get Hyprland uptime (seconds since Hyprland start) for time uniform
PID=$(pidof Hyprland 2>/dev/null || pgrep -x Hyprland 2>/dev/null | head -n1 || echo "")
UPTIME=0
if [[ -n "$PID" && -e "/proc/$PID/stat" ]]; then
  # etimes gives seconds since start
  UPTIME=$(ps -o etimes= -p "$PID" 2>/dev/null | tr -d ' ' || echo 0)
  # ps etimes is integer, add fractional part via uptime of process start vs now
  # use more precise: awk from /proc/uptime and process starttime
  # fallback to integer is okay — transition still ~250ms, just quantized to 1s
  # try to get fractional via /proc/$PID/stat starttime
  if command -v python3 >/dev/null 2>&1; then
    UPTIME=$(python3 -c "
import os, time
try:
  pid=int('$PID')
  with open(f'/proc/{pid}/stat') as f:
    stat=f.read().split()
  starttime=int(stat[21]) # clock ticks since boot
  clk_tck=int(os.popen('getconf CLK_TCK').read().strip() or 100)
  with open('/proc/uptime') as f:
    uptime=float(f.read().split()[0])
  btime=0
  with open('/proc/stat') as f:
    for l in f:
      if l.startswith('btime'):
        btime=int(l.split()[1])
        break
  # Hyprland start seconds since epoch
  hypr_start=btime + starttime/clk_tck
  now=time.time()
  print(f\"{now - hypr_start:.3f}\")
except Exception as e:
  print(os.popen('ps -o etimes= -p $PID').read().strip() if 'PID' else '0')
" 2>/dev/null || echo "$UPTIME")
  fi
fi
# fallback if ps failed
if ! [[ "$UPTIME" =~ ^[0-9]*\.?[0-9]+$ ]]; then UPTIME=0; fi
# inject transitionStart
# replace "const float transitionStart = 0.0;" with actual
if grep -q "const float transitionStart" "$SHADER" 2>/dev/null; then
  # use python to replace precisely
  python3 -c "
import re, pathlib
p=pathlib.Path('$SHADER')
t=p.read_text()
nt=re.sub(r'const float transitionStart = [^;]+;', f'const float transitionStart = $UPTIME;', t, count=1)
p.write_text(nt)
print(f'updated transitionStart to $UPTIME')
" 2>&1 | tail -n1
  # trigger reload without full config reload flicker? use hyprctl keyword via hl.config equivalent
  # hyprctl keyword doesn't work with Lua, so use reload but with damage_tracking 0 for smooth
  hyprctl reload 2>/dev/null || true &
  # after transition, ensure damage_tracking returns to 2 (optional) — Hyprland will handle via shader.lua
  # we keep shader as is; after 250ms, progress stays 1, no need to rewrite
fi
# also ensure borders reload
hyprctl reload 2>/dev/null || true &
