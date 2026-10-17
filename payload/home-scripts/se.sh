#!/bin/bash
# se.sh — manually open the same tmux session as .zshrc auto-attach.
# Mirrors .zshrc logic:
#   1. continuum/resurrect restore-on-boot handling (no blank `main` racing restore)
#   2. per-TTY grouped session attach to `main` (avoids multi-client overflow)

if [ -n "$TMUX" ]; then
  echo "already in tmux ($TMUX)"
  exit 1
fi

# --- step 1: restore handling (only when server has no sessions) ---
if ! tmux has-session 2>/dev/null; then
  tmux start-server 2>/dev/null
  # If server has no sessions but is running (exit-empty off), let continuum restore
  if tmux ls 2>&1 | grep -q "no server"; then
    # Server died (exit-empty on) - create dummy, restore synchronously
    if [ -f "$HOME/.local/share/tmux/resurrect/last" ] && [ -x "$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh" ]; then
      tmux new-session -d -s __restore_dummy 2>/dev/null || true
      "$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh" 2>/dev/null || true
      sleep 0.5
      tmux kill-session -t __restore_dummy 2>/dev/null || true
    else
      sleep 1.0
    fi
  else
    # Server running - continuum's background restore sleeps 1s, wait 1.5s
    sleep 1.5
    # If still no session, try synchronous restore as fallback
    if ! tmux has-session 2>/dev/null && [ -x "$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh" ]; then
      "$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh" 2>/dev/null || true
      sleep 0.5
    fi
  fi
fi

# --- step 2: attach (per-TTY grouped session off `main`, same as .zshrc) ---
if tmux has-session -t main 2>/dev/null; then
  # Fix multi-client overflow: 213x60 (tty3) vs 213x53 (pts/0) vs 139x28 (konsole)
  # sharing `main` with `window-size latest` caused 7-row overflow.
  # Use per-TTY grouped session so each terminal tracks its own active window,
  # plus `window-size smallest` in tmux.conf ensures no overflow (large gets letterbox).
  _tmux_tty_raw=$(tty 2>/dev/null)
  _tmux_sess="main"
  case "$_tmux_tty_raw" in
    /dev/*) _tmux_tty=$(echo "$_tmux_tty_raw" | sed 's|/dev/||; s|/|_|g'); _tmux_sess="main_$_tmux_tty" ;;
  esac
  if [ "$_tmux_sess" != "main" ]; then
    tmux new-session -d -t main -s "$_tmux_sess" 2>/dev/null || true
    tmux attach -t "$_tmux_sess" \; run-shell 'tmux resize-window -a 2>/dev/null || true' 2>/dev/null || tmux attach -t main
  else
    tmux attach -t main \; run-shell 'tmux resize-window -a 2>/dev/null || true' 2>/dev/null || tmux attach -t main
  fi
  unset _tmux_tty_raw _tmux_tty _tmux_sess
elif tmux has-session 2>/dev/null; then
  tmux attach \; run-shell 'tmux resize-window -a 2>/dev/null || true' 2>/dev/null || tmux attach
else
  tmux new-session -s main
fi
