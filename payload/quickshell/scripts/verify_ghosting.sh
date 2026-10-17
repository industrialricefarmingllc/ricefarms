#!/bin/bash
# verify_ghosting.sh - accurate replication for feedback/ghosting
# Captures bar at high frequency, checks brightness drift (ghost) and black
set -e
echo "=== verify_ghosting (accurate) ==="
read DP1_X DP1_Y DP1_W DP1_H <<< $(hyprctl monitors -j | python3 -c "import json,sys; d=json.load(sys.stdin); m=[x for x in d if x['name']=='DP-1'][0]; print(f\"{int(m['x'])} {int(m['y'])} {int(m['width']/m['scale'])} {int(m['height']/m['scale'])}\")")
BAR_Y=$((DP1_Y+22))
BAR_H=35
echo "DP-1 $DP1_X,$DP1_Y ${DP1_W}x${DP1_H} bar $DP1_X,$BAR_Y"

# Use dark mid-tone to avoid clipping (255 saturation hides drift)
TMP_WALL="/tmp/verify_ghost_wall.png"
python3 -c "from PIL import Image; Image.new('RGB',(3840,2160),(40,60,80)).save('$TMP_WALL')"
ORIG=$(cat /home/nicerice/.cache/current_wallpaper 2>/dev/null | head -n1)
awww img "$TMP_WALL" >/dev/null 2>&1
sleep 2.5

N=20
INTERVAL=0.2
OUTDIR="/tmp/verify_ghost_frames"
mkdir -p "$OUTDIR"
echo "capturing $N frames interval $INTERVAL"
for i in $(seq 1 $N); do
  grim -g "${DP1_X},${BAR_Y} ${DP1_W}x${BAR_H}" "$OUTDIR/frame_$i.png" 2>/dev/null
  sleep $INTERVAL
done

python3 << PY
import sys
from PIL import Image
N=20
frames=[Image.open(f"/tmp/verify_ghost_frames/frame_{i}.png") for i in range(1,N+1)]
w,h=frames[0].size
scale=w/1600 if w>1600 else 1.0
print(f"frame {w}x{h} scale {scale:.2f}")
# logical positions: gap outside pills, pill center (white), pill edge (sensitive), dock-like
positions={"gap":10, "pill_center":120, "pill_edge":300, "inter":410}
pill_y=int(18*scale)
gap_y=int(10*scale)
vals={k:[] for k in positions}
for im in frames:
    for name, xl in positions.items():
        x=int(xl*scale)
        y=gap_y if name=="gap" else pill_y
        vals[name].append(sum(im.getpixel((min(x,w-5), y))[:3])/3)

for k,v in vals.items():
    print(f"{k:12} {[round(x,1) for x in v]} rng {max(v)-min(v):.1f}")

def slope(arr):
    n=len(arr)
    x=list(range(n))
    mx=sum(x)/n
    my=sum(arr)/n
    den=sum((xi-mx)**2 for xi in x)
    num=sum((x[i]-mx)*(arr[i]-my) for i in range(n))
    return num/den if den else 0

FAIL=False
for name, arr in vals.items():
    s=slope(arr)
    rng=max(arr)-min(arr)
    print(f"{name:12} slope {s:.3f}/frame rng {rng:.1f}")
    # Ghost: monotonic drift >0.7 per frame and rng>5
    if abs(s)>0.7 and rng>5:
        inc=sum(1 for i in range(1,N) if arr[i] > arr[i-1]+0.2)
        dec=sum(1 for i in range(1,N) if arr[i] < arr[i-1]-0.2)
        if inc>=9 or dec>=9:
            print(f"FAIL ghost {name} slope {s:.2f}")
            FAIL=True

# Black check
blacks=0
for im in frames:
    for xl in [10,410]:
        x=int(xl*scale)
        if im.getpixel((min(x,w-5), gap_y))[:3]==(0,0,0):
            blacks+=1
print(f"black samples {blacks}")
if blacks>0:
    print("FAIL black")
    FAIL=True
if not FAIL:
    print("PASS no ghosting, no black (stable)")
    sys.exit(0)
sys.exit(1)
PY
RC=$?
if [ -n "$ORIG" ] && [ -f "$ORIG" ]; then awww img "$ORIG" >/dev/null 2>&1; else awww img /home/nicerice/Pictures/wallpapers/matugen/wallhaven-o5dj1p.jpg >/dev/null 2>&1; fi
sleep 1
exit $RC
