#!/bin/bash
# keyboard-hotplug.sh - keep Hyprland binds alive across USB replug
# Hyprland 0.56 + Skeletyl/Glorious hotplug: hyprctl devices shows empty after replug, binds need reload
set -e

LOG="/tmp/keyboard-hotplug.log"
# one watcher only: Hyprland start handlers and manual runs can otherwise
# stack copies that each reload and act on the same hotplug event
LOCK="/tmp/keyboard-hotplug.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "[$(date '+%F %T')] another watcher holds $LOCK, exiting (pid $$)" | tee -a "$LOG"
  exit 0
fi
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
last_action=0
eval $UDEV_CMD 2>/dev/null | while read -r line; do
  # udevadm lines contain "add" or "remove" for input devices
  if echo "$line" | grep -qE "add|remove"; then
    now=$(date +%s)
    # one physical replug emits an event per interface and per device node
    # (kbd, consumer control, ...). Settle on one reload instead of running
    # the whole block once per event.
    if [ $((now - last_action)) -lt 3 ]; then
      continue
    fi
    last_action=$now
    echo "[$(date '+%F %T')] input hotplug: $line" | tee -a "$LOG"
    sleep 0.7
    # Refresh Hyprland - re-apply binds (super left/right, F15) for new device
    HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -n1)
    export HYPRLAND_INSTANCE_SIGNATURE
    export WAYLAND_DISPLAY=wayland-1
    export XDG_RUNTIME_DIR=/run/user/1000
    hyprctl reload >/dev/null 2>&1 || echo "hyprctl reload failed" | tee -a "$LOG"
    echo "[$(date '+%F %T')] hyprctl reload done after hotplug" | tee -a "$LOG"
    # Also ensure qs is still running (quickshell workspace pill).
    # The shell runs from qs-web, so its process is /usr/local/bin/quickshell;
    # the old '^/usr/bin/qs$' check never matched and this block used to
    # restart (SIGKILL) a perfectly healthy shell on every hotplug event,
    # because Quickshell handles input hotplug itself. Only start it when it
    # is really gone -- never restart it here.
    # gt / lucid-gamemode park the shell on purpose: its marker means "leave
    # it down", even after the hyprctl reload above.
    if [ ! -f "$HOME/.cache/lucid/gt/shell-paused" ] \
       && ! systemctl --user is-active --quiet quickshell.service \
       && ! pgrep -f '^(/usr/local/bin/(qs|quickshell)|/usr/bin/qs)$' >/dev/null 2>&1; then
      if ! systemctl --user start quickshell.service >/dev/null 2>&1; then
        nohup /usr/local/bin/qs >/tmp/qs_hotplug.log 2>&1 &
      fi
      echo "[$(date '+%F %T')] qs started (was not running)" | tee -a "$LOG"
    fi
  fi
done
