#!/bin/bash
set -e
echo "=== verify_all (black+ghosting) ==="
/home/nicerice/.config/quickshell/scripts/verify_black.sh
echo ""
/home/nicerice/.config/quickshell/scripts/verify_ghosting.sh
# Also check layers
echo ""
echo "=== layers check ==="
hyprctl layers -j | python3 -c "
import json,sys
d=json.load(sys.stdin)
dp1=d.get('DP-1',{}).get('levels',{})
bg=len(dp1.get('0',[]))
top=len(dp1.get('2',[]))
print(f'DP-1 Background:{bg} Top:{top}')
if bg!=1:
    print(f'WARN expected 1 Background (awww) got {bg}')
if top!=2:
    print(f'WARN expected 2 Top (bar+dock) got {top}')
else:
    print('PASS layers')
"
echo ""
echo "=== hyprland layerrule ==="
grep layerrule /home/nicerice/.config/hypr/hyprland.conf || echo "no layerrule"
echo ""
echo "ALL PASS if above shows PASS"
