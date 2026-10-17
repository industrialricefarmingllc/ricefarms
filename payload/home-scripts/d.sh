#!/bin/bash
# dev shell with predictive local echo - shows typing immediately despite lag
# - tries mosh first (instant local echo, roaming, survives disconnects)
# - falls back to et then ssh if mosh unavailable/blocked
# install: sudo pacman -S mosh          # local (Arch)
#          ssh dev "sudo apt update && sudo apt install -y mosh"  # remote (Debian)
# force ssh: MOSH=0 d.sh  or  d.sh --no-mosh

SSH_OPTS="-o ServerAliveInterval=30 -o ServerAliveCountMax=120 -o TCPKeepAlive=yes"
# Non-blocking theme sync: push the local matugen palette in the background
# so the connection starts immediately (~0ms added) and live changes apply
# with no reconnect (same mechanism as the d()/ssh() wrappers in ~/.zshrc).
# Covers direct ~/d.sh invocations that bypass the shell function; the
# flock in matugen-sync-dev.sh collapses double-triggers (wrapper + here)
# to a single upload. Failures only land in the log, never block connect.
# Also ensures the realtime watcher daemon for in-session wallpaper changes.
if [ -z "${MATUGEN_SYNC_IN_PROGRESS:-}" ]; then
  if [ -x "$HOME/matugen-sync-dev.sh" ]; then
    SYNC_TTY="$(tty 2>/dev/null || true)" nohup "$HOME/matugen-sync-dev.sh" --background >>"$HOME/.cache/matugen-sync-dev.log" 2>&1 &
    disown 2>/dev/null || true
  fi
  if [ -x "$HOME/matugen-watch-dev.sh" ]; then
    ("$HOME/matugen-watch-dev.sh" --ensure >>"$HOME/.cache/matugen-sync-dev-watch.log" 2>&1 &) 2>/dev/null || true
  fi
fi
MOSH_SSH="ssh $SSH_OPTS"
PREDICT="adaptive" # -> "always" for most aggressive immediate echo, "experimental" even more (can mis-predict in vim)

# allow forcing ssh fallback
if [ "$MOSH" = "0" ] || [ "$1" = "--no-mosh" ]; then
  [ "$1" = "--no-mosh" ] && shift
  exec ssh $SSH_OPTS dev "$@"
fi

# propagate kitty/no-tmux flag so remote .zshrc can skip auto-tmux (matches local kitty.conf: env NO_TMUX=1 and local ~/.zshrc guard)
# mosh doesn't forward env via SendEnv, inject via --server; ssh path relies on TERM=xterm-kitty forwarding (always sent)
if [ -n "$KITTY_WINDOW_ID" ] || [ "$TERM" = "xterm-kitty" ] || [ -n "$NO_TMUX" ]; then
  export NO_TMUX=1
  # keep $HOME literal for remote expansion, but expand local KITTY_WINDOW_ID/TERM now
  MOSH_SERVER='env NO_TMUX=1 KITTY_WINDOW_ID='"${KITTY_WINDOW_ID:-1}"' TERM='"$TERM"' $HOME/bin/mosh-server'
else
  MOSH_SERVER='$HOME/bin/mosh-server'
fi
# try mosh (UDP 60000-61000 must be open) - only if interactive tty (mosh needs tty)
# uses user-local ~/bin/mosh-server on dev if system mosh-server not installed
if [ -t 0 ] && [ -t 1 ] && command -v mosh >/dev/null 2>&1; then
  if [ $# -eq 0 ]; then
    mosh --predict="$PREDICT" --server="$MOSH_SERVER" --ssh="$MOSH_SSH" dev
  else
    mosh --predict="$PREDICT" --server="$MOSH_SERVER" --ssh="$MOSH_SSH" dev -- "$@"
  fi
  MOSH_EXIT=$?
  # exit 0 = clean mosh session, don't fallback
  [ $MOSH_EXIT -eq 0 ] && exit $MOSH_EXIT
  echo "mosh failed (exit $MOSH_EXIT) - UDP blocked or mosh-server missing on dev, falling back to ssh..." >&2
  echo "hint: ssh dev \"sudo apt install -y mosh\" && sudo pacman -S mosh" >&2
  sleep 1
fi

# try Eternal Terminal if available (TCP-based alternative)
if command -v et >/dev/null 2>&1; then
  if [ $# -eq 0 ]; then
    et dev
  else
    et dev -c "$@"
  fi
  ET_EXIT=$?
  [ $ET_EXIT -eq 0 ] && exit $ET_EXIT
fi

exec ssh $SSH_OPTS dev "$@"
