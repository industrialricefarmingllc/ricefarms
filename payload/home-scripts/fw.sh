#!/usr/bin/env bash
set -euo pipefail

# fw.sh — persistent SSH port forwards to/from dev
#
# Forwards:
#   dev:80   -> localhost:80   (L: access dev's :80 locally)
#   dev:443  -> localhost:443  (L: access dev's :443 locally)
#   localhost:9222 -> dev:9222 (R: expose local Chrome DevTools to dev)
#
# The -L forwards and the -R forward run in separate SSH sessions. A busy
# dev:9222 (headless Chrome, stale tunnel, another fw.sh) can only fail the
# reverse session; the website forwards (80/443) keep running.
#
# Usage:
#   ~/fw.sh                # foreground, auto-reconnects on drop
#   ~/fw.sh --once         # single shot (no reconnect loop)
#   ~/fw.sh --unprivileged # use 8080/8443 instead of 80/443 (no cap needed)
#   ~/fw.sh --check        # dry-run, print ssh command
#
# Notes on privileged ports (80/443):
#   Binding to <1024 requires root on this machine.
#   Either run with sudo:
#     sudo ~/fw.sh
#   Or allow unprivileged binding once:
#     sudo setcap 'cap_net_bind_service=+ep' "$(readlink -f "$(which ssh)")"
#   Or change to >1024 in FORWARDS below (e.g. 8080:localhost:80).
#
# Chrome DevTools port 9222 is taken from opencode.json:
#   chrome-devtools --browser-url=http://127.0.0.1:9222
#
# Keepalive (prevents random drops / NAT timeouts):
#   ServerAliveInterval=15  send keepalive every 15s
#   ServerAliveCountMax=6   drop after 6 missed (90s)
#   TCPKeepAlive=yes        enable TCP keepalives

HOST="dev"
LOOP=1
UNPRIV=0

for arg in "$@"; do
  case "$arg" in
    --once) LOOP=0 ;;
    --no-loop) LOOP=0 ;;
    --unprivileged) UNPRIV=1 ;;
    --check|--dry-run) DRY_RUN=1 ;;
    -h|--help)
      cat <<'HELP'
fw.sh — persistent SSH port forwards to/from dev

Forwards:
  dev:80   -> localhost:80   (L: access dev's :80 locally)
  dev:443  -> localhost:443  (L: access dev's :443 locally)
  localhost:9222 -> dev:9222 (R: expose local Chrome DevTools to dev)

Usage:
  ~/fw.sh                # foreground, auto-reconnects on drop
  ~/fw.sh --once         # single shot (no reconnect loop)
  ~/fw.sh --unprivileged # use 8080->80, 8443->443 (avoids needing cap/sudo)
  ~/fw.sh --check        # dry-run, print ssh command

Notes on privileged ports (80/443):
  Binding to <1024 requires root. Script auto-tries:
    sudo setcap 'cap_net_bind_service=+ep' "$(readlink -f "$(which ssh)")"
  Fallbacks:
    ~/fw.sh --unprivileged
    sudo -E env HOME=$HOME ~/fw.sh

Chrome DevTools port 9222 from opencode.json --browser-url=http://127.0.0.1:9222
Keepalive: ServerAliveInterval=15 ServerAliveCountMax=6 TCPKeepAlive=yes ExitOnForwardFailure=yes

Forwarding behaviour:
  HTTP forwards (80/443) have their own SSH session and always reconnect.
  The Chrome reverse forward (-R 9222) is a separate best-effort session: if
  dev:9222 is already busy it waits and retries without touching HTTP.

Env:
  FW_NO_AUTOSSH=1      force manual reconnect loop (preferred under systemd)
  FW_REVERSE_CHROME=0  do not expose local Chrome to dev at all
HELP
      exit 0
      ;;
  esac
done

# SSH keepalive + robustness options
# NOTE: never multiplex (ControlMaster=no). The user ssh_config may set
# ControlMaster auto, and a lingering master (e.g. from a boot probe) would
# turn every connection below into a slave: ExitOnForwardFailure then reports
# the MASTER's state, slaves can't reliably (re)bind -R, and cleanup would run
# inside the very session it tries to clean. Each connection must stand alone.
MUX_OFF=(
  -o ControlMaster=no
  -o ControlPath=none
)
SSH_OPTS=(
  "${MUX_OFF[@]}"
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=6
  -o TCPKeepAlive=yes
  -o ExitOnForwardFailure=yes
  -o StrictHostKeyChecking=accept-new
)

# Port forwards
# -L [bind_addr:]port:host:hostport  (remote -> local)
# -R [bind_addr:]port:host:hostport  (local -> remote)
FORWARDS=(
  -L 127.0.0.1:80:127.0.0.1:80
  -L 127.0.0.1:443:127.0.0.1:443
  -R 127.0.0.1:9222:127.0.0.1:9222
  # If dev's sshd has GatewayPorts yes and you need 9222 on 0.0.0.0:
  # -R 0.0.0.0:9222:localhost:9222
)

# --unprivileged: use high ports to avoid needing cap/sudo
if (( UNPRIV )); then
  FORWARDS=(
    -L 127.0.0.1:8080:127.0.0.1:80
    -L 127.0.0.1:8443:127.0.0.1:443
    -R 127.0.0.1:9222:127.0.0.1:9222
  )
fi

# handle privileged ports (<1024) without root via cap_net_bind_service
if [[ ${EUID:-$(id -u)} -ne 0 ]] && (( ! UNPRIV )); then
  needs_priv=0
  for ((i=0; i<${#FORWARDS[@]}; i+=2)); do
    opt="${FORWARDS[i]}"
    spec="${FORWARDS[i+1]:-}"
    if [[ "$opt" == "-L" && "$spec" =~ ^[^:]*:([0-9]+): ]]; then
      port="${BASH_REMATCH[1]}"
      (( port < 1024 )) && needs_priv=1 && break
    fi
  done
  if (( needs_priv )); then
    ssh_bin="$(readlink -f "$(which ssh)")"
    if ! getcap "$ssh_bin" 2>/dev/null | grep -q "cap_net_bind_service"; then
      echo "info: privileged port 80/443 needs cap_net_bind_service — trying to set it..." >&2
      if sudo setcap 'cap_net_bind_service=+ep' "$ssh_bin" 2>/dev/null; then
        echo "info: granted cap_net_bind_service to $ssh_bin" >&2
      else
        echo "warn: could not setcap (no sudo / failed). Fallbacks:" >&2
        echo "  1) run once: sudo setcap 'cap_net_bind_service=+ep' \"\$(readlink -f \$(which ssh))\"" >&2
        echo "  2) run with sudo (preserves HOME): sudo -E env HOME=\$HOME ~/fw.sh" >&2
        echo "  3) use unprivileged ports: ~/fw.sh --unprivileged  (8080->80, 8443->443)" >&2
        echo "attempting to continue anyway (will fail with 'Permission denied' if cap missing)..." >&2
      fi
    fi
  fi
fi

# Clean up a *stale* SSH reverse forward on dev:9222. Only the process that
# actually owns the 9222 listener is considered, so the separate HTTP session
# (also a bare "sshd: dev", but not listening on 9222) is never touched.
cleanup_stale_remote() {
  local listener pid

  listener="$(remote_9222_listener)"
  [[ -n "$listener" ]] || return 0

  if [[ "$listener" != *sshd* ]]; then
    echo "info: dev:9222 is held by a non-SSH process; leaving it alone" >&2
    return 0
  fi

  # A healthy tunnel answers with Chrome's DevTools JSON. Don't kill it:
  # another fw.sh (or a live reverse session) may own it.
  if ssh "${MUX_OFF[@]}" -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "$HOST" \
       "curl -s --max-time 3 http://127.0.0.1:9222/json/version 2>/dev/null | grep -q 'Browser\|webSocketDebuggerUrl'" 2>/dev/null; then
    echo "info: dev:9222 is a healthy SSH tunnel; leaving it alone" >&2
    return 0
  fi

  pid="$(printf '%s\n' "$listener" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n1)"
  if [[ -z "$pid" ]]; then
    echo "warn: dev:9222 is a stale SSH tunnel but its listener pid could not be determined" >&2
    return 0
  fi

  echo "warn: dev:9222 is an unresponsive SSH tunnel (pid $pid); cleaning it up..." >&2
  ssh "${MUX_OFF[@]}" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$HOST" "
    cmd=\$(ps -o cmd= -p '$pid' 2>/dev/null)
    case \"\$cmd\" in
      sshd:*)
        kill '$pid' 2>/dev/null && echo 'killed stale sshd pid $pid' || echo 'failed to kill pid $pid'
        ;;
      '')
        echo 'pid $pid already gone'
        ;;
      *)
        echo 'refusing to kill non-sshd pid $pid:' \"\$cmd\"
        ;;
    esac
  " 2>&1 | sed "s/^/[cleanup] /" >&2 || true

  sleep 1
  if [[ -n "$(remote_9222_listener)" ]]; then
    echo "warn: dev:9222 still listening after cleanup (may need manual kill)" >&2
  else
    echo "info: dev:9222 cleared" >&2
  fi
}

# warn if local chrome port not listening
if ! ss -tlnH 2>/dev/null | grep -qE "[: ]9222\b" && ! netstat -tln 2>/dev/null | grep -qE "[: ]9222\b"; then
  echo "warn: local 127.0.0.1:9222 not listening (is Chrome running with --remote-debugging-port=9222?)" >&2
  echo "  Chrome forwards will still be established; dev:9222 will fail until Chrome starts." >&2
fi

# Always run the optional Chrome reverse-forward in its own SSH session.
# A busy dev:9222 (headless Chrome, stale tunnel, another fw.sh, ...) can then
# only fail that session — the -L 80/443 session, and the website, stay up.
remote_9222_listener() {
  ssh "${MUX_OFF[@]}" -o ConnectTimeout=3 -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new "$HOST" \
    "ss -ltnpH 'sport = :9222' 2>/dev/null" 2>/dev/null || true
}

HTTP_FORWARDS=()
REVERSE_FORWARDS=()
for ((i=0; i<${#FORWARDS[@]}; i+=2)); do
  opt="${FORWARDS[i]}"
  spec="${FORWARDS[i+1]:-}"
  case "$opt" in
    -R) REVERSE_FORWARDS+=("$opt" "$spec") ;;
    *)  HTTP_FORWARDS+=("$opt" "$spec") ;;
  esac
done

# FW_REVERSE_CHROME=0 disables exposing local Chrome to dev entirely.
if [[ "${FW_REVERSE_CHROME:-1}" == 0 ]]; then
  REVERSE_FORWARDS=()
fi

CMD=(ssh -N "${SSH_OPTS[@]}" "${HTTP_FORWARDS[@]}" "$HOST")
REV_CMD=(ssh -N "${SSH_OPTS[@]}" "${REVERSE_FORWARDS[@]}" "$HOST")

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  echo "http:    ${CMD[*]}"
  if (( ${#REVERSE_FORWARDS[@]} )); then
    echo "reverse: ${REV_CMD[*]}"
  fi
  exit 0
fi

# pretty banner
echo "==> fw: $HOST"
for ((i=0; i<${#HTTP_FORWARDS[@]}; i+=2)); do
  echo "    L ${HTTP_FORWARDS[i+1]}  (dev -> local)"
done
if (( ${#REVERSE_FORWARDS[@]} )); then
  for ((i=0; i<${#REVERSE_FORWARDS[@]}; i+=2)); do
    echo "    R ${REVERSE_FORWARDS[i+1]}  (local -> dev) Chrome DevTools [separate, best-effort]"
  done
else
  echo "    R disabled (FW_REVERSE_CHROME=0)"
fi
echo "    keepalive: ServerAliveInterval=15 ServerAliveCountMax=6 TCPKeepAlive=yes"
echo "    ExitOnForwardFailure=yes  (fail fast if port busy)"
if [[ "$LOOP" == 1 ]]; then
  echo "    mode: persistent (auto-reconnect, Ctrl-C to stop)"
else
  echo "    mode: single shot (--once)"
fi
echo ""

# Best-effort reverse Chrome forward. This is a separate SSH process: if
# dev:9222 is busy or the reverse bind fails for any reason, only this loop
# reacts. The -L 80/443 session is never affected.
reverse_chrome_loop() {
  local log=/tmp/fw-reverse-last.log rev_child="" state=""

  trap 'kill "${rev_child:-}" 2>/dev/null; exit 0' INT TERM
  note() {
    [[ "$1" == "$state" ]] && return 0
    state="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
  }

  while true; do
    if ! ss -tlnH 2>/dev/null | grep -qE "[: ]9222\b"; then
      note "local Chrome 9222 is not listening — reverse forward paused"
      sleep 10
      continue
    fi

    listener="$(remote_9222_listener)"
    if [[ -n "$listener" && "$listener" != *sshd* ]]; then
      note "dev:9222 is held by a non-SSH process — reverse forward paused (${listener})"
      sleep 30
      continue
    fi

    if [[ -n "$listener" ]]; then
      note "dev:9222 is held by sshd — checking whether the tunnel is stale"
      cleanup_stale_remote || true
      if [[ -n "$(remote_9222_listener)" ]]; then
        note "dev:9222 is still in use by a healthy SSH tunnel — reverse forward paused"
        sleep 15
        continue
      fi
    fi

    note "connecting reverse Chrome forward..."
    set +e
    "${REV_CMD[@]}" >"$log" 2>&1 &
    rev_child=$!
    wait "$rev_child"
    rc=$?
    set -e
    cat "$log" >&2
    state=""
    note "reverse Chrome forward exited (code $rc), retrying in 5s..."
    sleep 5
  done
}

if [[ "$LOOP" == 1 ]]; then
  trap 'jobs -p | xargs -r kill 2>/dev/null; pkill -P $$ 2>/dev/null; echo ""; echo "interrupted."; exit 130' INT TERM
  if (( ${#REVERSE_FORWARDS[@]} )); then
    reverse_chrome_loop &
    echo "    reverse Chrome forward: independent session (pid $!)"
  fi
elif (( ${#REVERSE_FORWARDS[@]} )); then
  echo "    note: reverse Chrome forward skipped in --once mode"
fi

# use autossh if available (more robust), else manual loop
# (set FW_NO_AUTOSSH=1 to force the manual loop — simple, explicit reconnect
# logging; preferred under systemd which supervises restarts)
if command -v autossh >/dev/null 2>&1 && [[ "$LOOP" == 1 ]] && [[ "${FW_NO_AUTOSSH:-0}" != 1 ]]; then
  echo "using autossh for auto-reconnect..."
  # autossh monitors via ServerAlive; AUTOSSH_GATETIME=0 to retry immediately
  export AUTOSSH_GATETIME=0
  export AUTOSSH_POLL=15
  while true; do
    set +e
    autossh -M 0 -N "${SSH_OPTS[@]}" "${HTTP_FORWARDS[@]}" "$HOST" &
    autossh_pid=$!
    wait $autossh_pid
    rc=$?
    set -e
    if (( rc == 0 )); then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] autossh exited cleanly, reconnecting in 2s..." >&2
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] autossh exited with code $rc, reconnecting in 2s..." >&2
    fi
    sleep 2
  done
  exit 0
fi

if [[ "$LOOP" == 1 ]]; then
  # manual reconnect loop
  while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] connecting to $HOST..."
    # run ssh in background so we can trap and kill it, capture output to file
    set +e
    "${CMD[@]}" > /tmp/fw-last.log 2>&1 &
    ssh_pid=$!
    wait $ssh_pid
    rc=$?
    cat /tmp/fw-last.log >&2
    set -e
    if (( rc == 0 )); then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ssh exited cleanly (code $rc), reconnecting in 2s..."
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ssh exited with code $rc, reconnecting in 2s..."
    fi
    sleep 2
  done
else
  # single shot: run the HTTP forwards once (reverse Chrome is skipped)
  # ensure child ssh is killed when this shell is killed (for --once bg test)
  trap 'jobs -p | xargs -r kill 2>/dev/null; exit 130' INT TERM
  set +e
  "${CMD[@]}" > /tmp/fw-last.log 2>&1 &
  ssh_pid=$!
  wait $ssh_pid
  rc=$?
  cat /tmp/fw-last.log >&2
  set -e
  trap - INT TERM
  exit $rc
fi
