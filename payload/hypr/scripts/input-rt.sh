#!/bin/bash
# input-rt.sh - Windows RIT/SHIQ equivalent for Hyprland.
# Goal: keep input:repeat_rate=125 (8ms interval) + repeat_delay=125 usable under load
# by shrinking press->release delivery latency (t2-t1) from 50-200ms to <10ms.
#
# Why this exists (Wayland vs Windows):
# - Wayland repeat is CLIENT-side speculative timer: toolkit arms timer on
#   wl_keyboard.key[pressed] and keeps firing until key[released] arrives.
#   Under CPU starvation both compositor (drains libinput) and client (drains
#   Wayland socket + fires timer) stall, so releases arrive late and timer
#   fires phantom repeats in [physical_release, processed_release].
# - Windows repeat is SYSTEM-owned typematic: driver/RIT generates WM_KEYDOWN
#   with coalesced repeat-count + KF_REPEAT flag at interrupt-time priority,
#   timestamped. Apps can check GetAsyncKeyState() ground truth. Release stops
#   generation at interrupt time, not at app-dequeue time.
# - This script emulates the Windows priority part: Hyprland (the release
#   witness + forwarder) preempts bulk builders like rustc/opencode, so the
#   release is forwarded before the client timer fires many extra times.
# - It does NOT change repeat_rate/delay (kept at 125/125 per request). At 8ms
#   interval even 20ms stall = 2 phantoms, so this reduces but cannot fully
#   eliminate phantoms. Full parity needs timestamp-gated repeat (see NOTES).
#
# NOTES on full Windows parity at 125Hz:
# - Windows caps at ~30Hz + coalesces repeats into one message with count.
#   125Hz is 4x Windows max; no Windows machine exhibits 125Hz behavior.
# - True fix: disable compositor/client repeat (repeat_rate=0) + run a
#   SCHED_FIFO evdev->uinput repeater that checks EVIOCGKEY physical state
#   before each 8ms emission (GetAsyncKeyState equivalent). Ask if you want
#   that daemon (winrepeatd) as follow-up.

set -u
LOG=/tmp/input-rt.log
{
echo "=== $(date -Is) input-rt start ==="

# 1) Find Hyprland PID without pgrep (pidof is precise here)
HYPR_PIDS=$(pidof Hyprland 2>/dev/null || true)
if [ -z "$HYPR_PIDS" ]; then
  echo "Hyprland not running, nothing to prioritize"
  exit 0
fi
# pidof may list multiple; take first (newest compositor)
HYPR_PID=$(echo "$HYPR_PIDS" | awk '{print $1}')
echo "Hyprland PID=$HYPR_PID PIDS=$HYPR_PIDS"

# 2) Negative nice = CPU preemption over nice-0 builders (needs limits.d nice -10, gamemode already grants this)
if renice -n -10 -p "$HYPR_PID" 2>&1; then
  echo "renice Hyprland -> -10 OK"
else
  echo "renice Hyprland failed (need @gamemode nice -10, you are in gamemode group, relogin if needed)"
fi

# 3) IO priority: realtime needs root; fallback to best-effort highest (works unprivileged)
if ionice -c1 -n0 -p "$HYPR_PID" 2>/dev/null; then
  echo "ionice Hyprland -> realtime OK"
elif ionice -c2 -n0 -p "$HYPR_PID" 2>&1; then
  echo "ionice Hyprland -> best-effort prio 0 OK (realtime needs root, best-effort is enough vs bulk builds at idle class)"
else
  echo "ionice failed"
fi

# 4) NO SCHED_RR for Hyprland (reverted 2026-09-11): RR prio 20 on the main
# thread (64% CPU, sustained) starved wireplumber/pipewire CFS threads and
# wedged `wpctl` (120s hang, empty `wpctl status`) breaking volume keys.
# Windows RIT is high-prio but microsecond bursts, not 64% sustained.
# Safe equivalent is nice -10 + containment (build.slice + cargo jobs=8),
# which preempts builders without starving audio. Keep RT for PipeWire itself
# (via rtkit) if you install/start rtkit-daemon, not for the compositor.

# 5) Nudge all Hyprland threads to nice -10 (input + render share the process;
# isolating just the input thread needs thread-name filtering and still risks
# audio starvation, so keep it to nice only, no RT).
if [ -d "/proc/$HYPR_PID/task" ]; then
  for tid in /proc/"$HYPR_PID"/task/*; do
    t=$(basename "$tid")
    renice -n -10 -p "$t" >/dev/null 2>&1 || true
  done
  echo "boosted $(ls /proc/$HYPR_PID/task | wc -l) threads nice -10 (no RT)"
fi

# 6) Current scheduler state for verification
chrt -p "$HYPR_PID" 2>&1 || true
ps -o pid,ni,cls,pri,rtprio,comm -p "$HYPR_PID" 2>&1 || ps -o pid,ni,pri,comm -p "$HYPR_PID" 2>&1 || true

echo "=== input-rt done ==="
} >>"$LOG" 2>&1
# Also echo tail to stdout for hyprctl exec / manual runs
tail -n 20 "$LOG"
