#!/usr/bin/env bash
# tobii-elite-focus.sh — Tobii Eye Tracker 5 awake ONLY while Elite Dangerous is focused.
#
# How it works:
#   The hub (tobii-gtk --background) keeps the IR sensor dark unless something
#   holds a subscription on its IPC socket. `tobii game -- <child>` holds one
#   for as long as <child> lives. This watcher holds a placeholder
#   subscription (`tobii game -- sleep ...`) exactly while Elite's Hyprland
#   window is focused, and kills it the moment focus leaves.
#   Tracker wakes ~instantly on focus, sleeps ~3s after defocus (driver standby).
#
# Requirements (already configured):
#   tobii games: enabled=true, keep_awake=false,
#                wake_for_joystick=false, wake_for_opentrack=false
#   hub running resident (exec-once = tobii-gtk --background)
#   "Preview my gaze" overlay OFF in the hub (it holds its own claim)
#
# Match: Elite Dangerous via Proton => class "steam_app_359320".
# Override for testing: MATCH_CLASS="kitty" tobii-elite-focus.sh

set -u
MATCH_CLASS="${MATCH_CLASS:-steam_app_359320}"
POLL="${POLL:-0.5}"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}/tobii-elite-focus"
LOCK="$RUNTIME/lock"
SUBPID="$RUNTIME/sub.pid"
SUBHUB="$RUNTIME/sub.hubpid"
LOG="$RUNTIME/watch.log"

mkdir -p "$RUNTIME"
exec 9>"$LOCK"
flock -n 9 || { echo "$(date +%T) already running, exiting" >>"$LOG"; exit 0; }

log() { echo "$(date +%T) $*" >>"$LOG"; }

hub_pid() { pidof tobii-gtk 2>/dev/null || true; }

sub_alive() {
  [ -f "$SUBPID" ] || return 1
  kill -0 "$(cat "$SUBPID")" 2>/dev/null
}

start_sub() {
  local hub
  hub="$(hub_pid)"
  [ -n "$hub" ] || return 1
  tobii game -- sleep 1000000 >/dev/null 2>&1 &
  echo "$!" >"$SUBPID"
  echo "$hub" >"$SUBHUB"
  log "focus gained -> subscription pid $(cat "$SUBPID") (hub $hub), sensor waking"
}

stop_sub() {
  local pid
  pid="$(cat "$SUBPID" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    log "focus lost -> killed subscription pid $pid, sensor sleeping (~3s)"
  fi
  rm -f "$SUBPID" "$SUBHUB"
}

cleanup() { stop_sub; }
trap cleanup EXIT INT TERM

log "watcher started (match class: $MATCH_CLASS)"

while true; do
  focused="$(hyprctl activewindow -j 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("class",""))' 2>/dev/null || true)"
  hub="$(hub_pid)"

  want=0
  if [ "$focused" = "$MATCH_CLASS" ] && [ -n "$hub" ]; then
    want=1
  fi

  if [ "$want" = 1 ]; then
    if ! sub_alive || [ "$(cat "$SUBHUB" 2>/dev/null || true)" != "$hub" ]; then
      stop_sub 2>/dev/null || true
      start_sub || true
    fi
  else
    if sub_alive; then
      stop_sub
    fi
  fi
  sleep "$POLL"
done
