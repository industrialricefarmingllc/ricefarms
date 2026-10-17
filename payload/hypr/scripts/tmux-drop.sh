#!/bin/bash
# tmux-drop.sh - drop marked window onto current workspace (Ctrl+BackSpace U)
# Legacy hyprland.conf backend. Shares ~/.cache/hypr-marked-window with
# hyprland.lua's pure-lua tmuxDrop(). Uses new 0.55+ lua eval syntax because
# plain `hyprctl dispatch movetoworkspace` no longer works.
# The orange mark highlight is cleared on drop (no notification popups).
set -eu
MARK_FILE="${HOME}/.cache/hypr-marked-window"

[ -f "$MARK_FILE" ] || exit 0
ADDR=$(head -n1 "$MARK_FILE" 2>/dev/null | tr -d '[:space:]')
if [ -z "$ADDR" ]; then
  rm -f "$MARK_FILE"
  exit 0
fi
if ! hyprctl clients -j 2>/dev/null | jq -e --arg a "$ADDR" 'any(.[]; .address == $a)' >/dev/null; then
  rm -f "$MARK_FILE"
  exit 0
fi
WS=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // empty')
[ -z "$WS" ] && exit 0
hyprctl eval "hl.dispatch(hl.dsp.window.move({workspace='$WS', window='address:$ADDR'}))" >/dev/null 2>&1 || true
hyprctl eval "hl.dispatch(hl.dsp.focus({window='address:$ADDR'}))" >/dev/null 2>&1 || true
hyprctl eval "hl.dispatch(hl.dsp.window.tag({tag='-marked', window='address:$ADDR'}))" >/dev/null 2>&1 || true
rm -f "$MARK_FILE"
