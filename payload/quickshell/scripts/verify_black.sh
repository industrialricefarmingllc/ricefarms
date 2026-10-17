#!/bin/bash
# verify_black.sh - black behind elements
set -e
echo "=== verify_black ==="
read DP1_X DP1_Y DP1_W DP1_H <<< $(hyprctl monitors -j | python3 -c "import json,sys; d=json.load(sys.stdin); m=[x for x in d if x['name']=='DP-1'][0]; print(f\"{int(m['x'])} {int(m['y'])} {int(m['width']/m['scale'])} {int(m['height']/m['scale'])}\")")
BAR_Y=$((DP1_Y+22))
BAR_H=35
echo "DP-1 $DP1_X,$DP1_Y bar $DP1_X,$BAR_Y"
TMP_WALL="/tmp/verify_black_wall.png"
python3 -c "from PIL import Image; Image.new('RGB',(3840,2160),(0,255,0)).save('$TMP_WALL')"
ORIG=$(cat /home/nicerice/.cache/current_wallpaper 2>/dev/null | head -n1)
awww img "$TMP_WALL" >/dev/null 2>&1
sleep 2.2
OUT="/tmp/verify_black_bar.png"
grim -g "${DP1_X},${BAR_Y} ${DP1_W}x${BAR_H}" "$OUT" 2>/dev/null
python3 << PY
from PIL import Image
import sys
im=Image.open("/tmp/verify_black_bar.png")
w,h=im.size
scale=w/1600 if w>1600 else 1.0
gap_y=int(10*scale)
samples=[im.getpixel((int(x*scale),gap_y))[:3] for x in [10,200,800,1200]]
print(f"samples gap 10,200,800,1200: {samples}")
blacks=sum(1 for p in samples if p==(0,0,0))
step=int(20*scale)
black_count=sum(1 for x in range(0,w,step) if im.getpixel((x,gap_y))[:3]==(0,0,0))
print(f"black in gap row: {black_count}/{w//step}")
if black_count>0:
    print("FAIL black")
    sys.exit(1)
print("PASS no black")
PY
RC=$?
if [ -n "$ORIG" ] && [ -f "$ORIG" ]; then awww img "$ORIG" >/dev/null 2>&1; else awww img /home/nicerice/Pictures/wallpapers/matugen/wallhaven-o5dj1p.jpg >/dev/null 2>&1; fi
sleep 1
exit $RC
