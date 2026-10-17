#!/bin/bash
# apply-liquidglass-rules.sh - window rules for the kitty glass takeover.
#
# WHY THIS EXISTS: windowrule entries in hyprland.conf (both the one-liner
# and the named block form) silently fail to apply on Hyprland 0.56 here
# (empty configerrors, zero effect: native blur kept frosting over the
# refraction). hl.window_rule via eval provably works, so rules live here
# instead. Runs at startup via exec-once AND on demand (idempotent: same
# rule names re-applied).
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -n1)
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || [ ! -e "/run/user/$(id -u)/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock" ]; then
  SIG=$(hyprctl instances 2>/dev/null | grep -oP 'instance \K[^:]+' | tail -n1 || true)
  [ -n "$SIG" ] && export HYPRLAND_INSTANCE_SIGNATURE="$SIG" || true
fi
LOG="$HOME/.cache/liquid-glass-hypr/rules.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
# QUIET=1 (systemd timer): log only failures, not every successful re-apply.
[ "${QUIET:-0}" = "1" ] || echo "$(date '+%F %T') started (sig ${HYPRLAND_INSTANCE_SIGNATURE:-none})" >> "$LOG"
# no_blur: the compositor blur pass frosts OVER the plugin refraction and
# buries it (the plugin owns the backdrop). rounding feeds the glass corners.
# Retry: at startup the socket/lua state may not be ready on the first try.
for i in $(seq 1 15); do
  OUT=$(hyprctl eval 'hl.window_rule({ name = "lg-kitty-glass", match = { class = "kitty" }, no_blur = true, rounding = 12 })' 2>&1 | head -n 2)
  case "$OUT" in
    ok*)
      # Recency marker (checked headlessly): proves the timer fired AND the
      # rule applied, without spamming the log every 60s.
      date '+%F %T' > "$HOME/.cache/liquid-glass-hypr/rules.last"
      [ "${QUIET:-0}" = "1" ] || echo "$(date '+%F %T') attempt $i: $OUT" >> "$LOG"
      break
      ;;
    *) echo "$(date '+%F %T') attempt $i: $OUT" >> "$LOG" ;;
  esac
  sleep 2
done
