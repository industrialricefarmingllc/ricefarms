#!/bin/bash
# matugen-watch-dev.sh - realtime local watcher that pushes matugen theme
# changes to dev WITHOUT a reconnect, reusing the same background sync
# mechanism as d()/ssh().
#
#   matugen-watch-dev.sh --ensure       start daemon if not running (used by d()/ssh())
#   matugen-watch-dev.sh --status      check daemon
#   matugen-watch-dev.sh --stop        stop daemon
#   matugen-watch-dev.sh --daemon      run loop (internal, daemonized by --ensure)
#   matugen-watch-dev.sh --foreground  run loop in foreground (debugging)
#
# How it works: polls the mtimes of the matugen source files every 2s (or
# uses inotifywait when available). When a source is newer than
# ~/.cache/matugen-sync-dev.last, it runs:
#     ~/matugen-sync-dev.sh --background
# which uploads in 2 multiplexed SSH connections, applies the palette to
# the current terminal immediately via OSC, and lets remote opencode pick
# up matugen.json through its tui-matugen-live.ts watcher. No reconnect.
# Singleton via pidfile; sync-side flock collapses overlapping runs.
set -u
WATCH_FILES=(
  "$HOME/.config/kitty/matugen-colors.conf"
  "$HOME/.config/opencode/themes/matugen.json"
  "$HOME/.config/opencode/tui-matugen-live.ts"
  "$HOME/.config/btop/themes/matugen.theme"
)
STAMP="$HOME/.cache/matugen-sync-dev.last"
PIDFILE="$HOME/.cache/matugen-sync-dev-watch.pid"
LOG="$HOME/.cache/matugen-sync-dev-watch.log"
SYNC="$HOME/matugen-sync-dev.sh"
INTERVAL=2

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }
alive() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

cmd="${1:---ensure}"
case "$cmd" in
  --status)
    if alive; then echo "matugen-watch: running (pid $(cat "$PIDFILE"))"; exit 0
    else echo "matugen-watch: stopped"; exit 1; fi
    ;;
  --stop)
    if alive; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; echo "matugen-watch: stopped"
    else rm -f "$PIDFILE"; echo "matugen-watch: not running"; fi
    exit 0
    ;;
  --ensure)
    if alive; then exit 0; fi
    rm -f "$PIDFILE"
    mkdir -p "$HOME/.cache"
    # Daemonize detached from the connecting shell so mosh/exit can't kill it.
    setsid nohup "$0" --daemon >>"$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    sleep 0.3
    if alive; then exit 0; else echo "matugen-watch: failed to start, see $LOG" >&2; exit 1; fi
    ;;
  --daemon|--foreground)
    if [ "$cmd" = "--daemon" ]; then
      # Second singleton gate for the daemon itself (pidfile race).
      if alive; then exit 0; fi
      echo $$ >"$PIDFILE"
      # Clean pidfile on exit, but only if it's ours.
      trap '[ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"' EXIT
      trap '' HUP
    fi
    log "watch started (pid $$, interval ${INTERVAL}s)"
    export MATUGEN_SYNC_IN_PROGRESS=1
    if command -v inotifywait >/dev/null 2>&1; then
      # Event-driven path (instant). Dirs must be watched because matugen
      # writes atomically (temp + rename), which changes directory mtime.
      DIRS="$(printf '%s\n' "${WATCH_FILES[@]}" | xargs -n1 dirname | sort -u)"
      # shellcheck disable=SC2086
      inotifywait -m -q -e close_write,moved_to,create --format '%w%f' $DIRS 2>/dev/null | while read -r _ev; do
        # one palette render writes every watched file; drain the burst so a
        # single wallpaper change is one upload attempt, not eleven
        while read -r -t 0.15 _ev2; do :; done
        if [ -x "$SYNC" ]; then
          "$SYNC" --background >>"$LOG" 2>&1 || log "sync failed (will retry on next event)"
        fi
      done
    else
      # Portable polling path (no extra deps): trigger when any source is
      # newer than the last-successful-sync stamp.
      while true; do
        _need=
        for _f in "${WATCH_FILES[@]}"; do
          if [ -f "$_f" ] && { [ ! -f "$STAMP" ] || [ "$_f" -nt "$STAMP" ]; }; then _need=1; break; fi
        done
        if [ -n "$_need" ] && [ -x "$SYNC" ]; then
          "$SYNC" --background >>"$LOG" 2>&1 || log "sync failed (will retry)"
        fi
        sleep "$INTERVAL"
      done
    fi
    ;;
  *) echo "usage: $0 [--ensure|--status|--stop|--foreground|--daemon]" >&2; exit 2 ;;
esac
