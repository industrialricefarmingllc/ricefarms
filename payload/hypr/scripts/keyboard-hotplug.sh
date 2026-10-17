#!/bin/bash
# keyboard-hotplug.sh - keep Hyprland binds alive across USB replug
# Hyprland 0.56 + Skeletyl/Glorious hotplug: hyprctl devices shows empty after replug, binds need reload
set -e

LOG="/tmp/keyboard-hotplug.log"
echo "[$(date '+%F %T')] keyboard-hotplug watcher started (pid $$)" | tee -a "$LOG"

# Ensure initial state is correct
sleep 1
HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -n1)
export HYPRLAND_INSTANCE_SIGNATURE
export WAYLAND_DISPLAY=wayland-1
export XDG_RUNTIME_DIR=/run/user/1000
hyprctl reload >/dev/null 2>&1 || true

# Monitor udev for input subsystem add/remove
# Use stdbuf to get line-buffered output
if command -v stdbuf >/dev/null 2>&1; then
  UDEV_CMD="stdbuf -oL -eL udevadm monitor --udev --subsystem-match=input"
else
  UDEV_CMD="udevadm monitor --udev --subsystem-match=input"
fi

# Also watch via inotify if available as fallback (for manual trigger)
# Main loop: udev monitor
eval $UDEV_CMD 2>/dev/null | while read -r line; do
  # udevadm lines contain "add" or "remove" for input devices
  if echo "$line" | grep -qE "add|remove"; then
    echo "[$(date '+%F %T')] input hotplug: $line" | tee -a "$LOG"
    sleep 0.7
    # Refresh Hyprland - re-apply binds (super left/right, F15) for new device
    HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -n1)
    export HYPRLAND_INSTANCE_SIGNATURE
    export WAYLAND_DISPLAY=wayland-1
    export XDG_RUNTIME_DIR=/run/user/1000
    hyprctl reload >/dev/null 2>&1 || echo "hyprctl reload failed" | tee -a "$LOG"
    echo "[$(date '+%F %T')] hyprctl reload done after hotplug" | tee -a "$LOG"
    # Also ensure qs is still running (quickshell workspace pill)
    if ! pgrep -x qs >/dev/null 2>&1; then
      nohup qs >/tmp/qs_hotplug.log 2>&1 &
      echo "[$(date '+%F %T')] qs restarted" | tee -a "$LOG"
    fi
  fi
done
