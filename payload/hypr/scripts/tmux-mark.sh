#!/bin/bash
# tmux-mark.sh - mark active window for tmux-style drop (Ctrl+BackSpace M / Ctrl+BackSpace U)
# Legacy hyprland.conf backend. Active lua config (hyprland.lua) uses pure-lua
# tmuxMark() with the same ~/.cache/hypr-marked-window file, so marks are
# shared between both paths. Feedback is the orange border from the
# tag:marked window rule (no notification popups). M on a marked window
# toggles the mark off.
set -eu
MARK_FILE="${HOME}/.cache/hypr-marked-window"

ADDR=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')
[ -z "$ADDR" ] && exit 0

# toggle: already marked -> unmark
if hyprctl clients -j 2>/dev/null | jq -e --arg a "$ADDR" '.[] | select(.address == $a) | .tags // [] | index("marked")' >/dev/null; then
  hyprctl eval "hl.dispatch(hl.dsp.window.tag({tag='-marked', window='address:$ADDR'}))" >/dev/null 2>&1 || true
  rm -f "$MARK_FILE"
  exit 0
fi

# clear highlight from previously marked window
if [ -f "$MARK_FILE" ]; then
  OLD=$(head -n1 "$MARK_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$OLD" ] && [ "$OLD" != "$ADDR" ]; then
    hyprctl eval "hl.dispatch(hl.dsp.window.tag({tag='-marked', window='address:$OLD'}))" >/dev/null 2>&1 || true
  fi
fi

hyprctl eval "hl.dispatch(hl.dsp.window.tag({tag='+marked'}))" >/dev/null 2>&1 || true
TITLE=$(hyprctl activewindow -j 2>/dev/null | jq -r '.title // empty')
CLASS=$(hyprctl activewindow -j 2>/dev/null | jq -r '.class // empty')
WS=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // empty')
{
  echo "$ADDR"
  echo "title=$TITLE"
  echo "class=$CLASS"
  echo "workspace=$WS"
} > "$MARK_FILE"
