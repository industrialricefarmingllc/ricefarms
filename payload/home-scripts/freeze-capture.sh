#!/bin/bash
# freeze-capture — run DURING a frozen display (inputs/SSH still work),
# BEFORE any reboot. All state below is lost on reboot (/run is tmpfs).
# Paste the full output when reporting.
echo "=== date/VT ==="
date; echo "VT=$(cat /sys/class/tty/tty0/active 2>/dev/null)"
echo "=== sessions ==="
loginctl list-sessions --no-legend 2>&1
for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
  echo "sess $s: $(loginctl show-session "$s" -p VTNr -p Active -p State 2>/dev/null | tr '\n' ' ')"
done
echo "=== DRM masters (want: kmscon on tty1, Hyprland on tty7) ==="
sudo cat /sys/kernel/debug/dri/1/clients 2>&1 | awk 'NR==1 || $4=="y"'
echo "=== toggle journal (last 5 min) ==="
journalctl -t desktop-toggle --since "5 minutes ago" --no-pager 2>&1 | tail -n 12
echo "=== kmscon errors (last 5 min) ==="
journalctl -b -u kmsconvt@tty1 --since "5 minutes ago" --no-pager 2>&1 | grep -v -E 'modepin' | tail -n 10
echo "=== Hyprland procs ==="
pgrep -a Hyprland | head -n 3; pgrep -a kmscon | head -n 2
echo "=== Hyprland log tail ==="
SIG=$(ls /run/user/1000/hypr/ 2>/dev/null | head -n1)
if [ -n "$SIG" ]; then
  grep -a -i -E 'error|fail|EPERM|denied|vt|session|pause|release|master|timeout|stall|atomic|commit' "/run/user/1000/hypr/$SIG/hyprland.log" 2>/dev/null | tail -n 12 | cut -c1-200
else
  echo "(no live hypr instance dir)"
fi
echo "=== dmesg tail ==="
dmesg 2>&1 | tail -n 6
