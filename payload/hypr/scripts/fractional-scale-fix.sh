#!/bin/sh
# Hyprland 0.57 regression: after the switch to the Lua config format,
# clients on a fractional-scale output start with buffers at the wrong scale
# (blurry/low-res text, and client edges no longer matching compositor
# logical geometry). Re-applying the monitor config forces every client to
# re-render at the correct scale. Nudge the scale and restore it so the
# re-apply is guaranteed to be a real change.
#
# Only fractional outputs are touched; integer-scale outputs are fine.
# Silent and idempotent: safe on every start, a no-op if DP-1 is absent.

set -u
hyprctl monitors -j 2>/dev/null | grep -q '"name":"DP-1"' || exit 0

# read the current mode/position so the nudge preserves the setup
MODE=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.name=="DP-1") | "\(.width)x\(.height)@\(.refreshRate|floor)"')
POS=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.name=="DP-1") | "\(.x)x\(.y)"')
SCALE=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.name=="DP-1") | .scale')
[ -n "$MODE" ] && [ "$MODE" != "null" ] || exit 0
[ -n "$POS" ] && [ "$POS" != "null" ] || exit 0
[ -n "$SCALE" ] && [ "$SCALE" != "null" ] || exit 0

# leave integer-scale outputs alone
case "$SCALE" in
    *.0|*.00|1|2|3) exit 0 ;;
esac

hyprctl eval "hl.monitor({output=\"DP-1\", mode=\"$MODE\", position=\"$POS\", scale=1.34})" >/dev/null 2>&1
sleep 0.35
hyprctl eval "hl.monitor({output=\"DP-1\", mode=\"$MODE\", position=\"$POS\", scale=$SCALE})" >/dev/null 2>&1
