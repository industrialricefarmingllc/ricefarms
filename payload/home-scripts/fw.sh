#!/usr/bin/env bash
set -euo pipefail

# fw.sh — persistent SSH port forwards to/from dev
#
# Forwards:
#   dev:80   -> localhost:80   (L: access dev's :80 locally)
#   dev:443  -> localhost:443  (L: access dev's :443 locally)
#   localhost:9222 -> dev:9222 (R: expose local Chrome DevTools to dev)
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

Env:
  FW_NO_AUTOSSH=1  force manual reconnect loop (re-cleans stale remote
                   forwards after every failure; set this under systemd)
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

# cleanup stale remote forward (dev:9222 held by dead ssh)
cleanup_stale_remote() {
  # only if we have a remote forward for 9222
  has_remote9222=0
  for ((i=0; i<${#FORWARDS[@]}; i+=2)); do
    if [[ "${FORWARDS[i]}" == "-R" && "${FORWARDS[i+1]}" == *"9222"* ]]; then
      has_remote9222=1; break
    fi
  done
  (( has_remote9222 )) || return 0

  # check remote 9222 listening (independent connection, never a mux slave)
  if ! ssh "${MUX_OFF[@]}" -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "$HOST" "ss -tlnH 2>/dev/null | grep -q ':9222'" 2>/dev/null; then
    return 0
  fi
  # check if remote forward is healthy (curl to dev:9222 should proxy to local Chrome)
  is_healthy=0
  if ssh "${MUX_OFF[@]}" -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "$HOST" "curl -s --max-time 3 http://127.0.0.1:9222/json/version 2>/dev/null | grep -q 'Browser\|webSocketDebuggerUrl'" 2>/dev/null; then
    is_healthy=1
    echo "info: remote 127.0.0.1:9222 already listening and healthy (existing tunnel) — will fail to bind" >&2
    # healthy tunnel means another fw.sh is already running - don't auto-kill, just warn
    # but still return to let caller decide (retry will fail again)
    return 0
  else
    echo "warn: remote 127.0.0.1:9222 is listening but not responding (stale tunnel), attempting cleanup..." >&2
  fi
  # kill stale sshd: dev that holds the forward (dev-owned, not current session)
  # only when unhealthy - kill all matching sshd: dev not in current session (regardless of age, stale is dead)
  # NOTE: only bare "sshd: dev" (a -N forward holder like us). "sshd: dev@..."
  # are live exec sessions (other users' shells, tools) — never touch those.
  # This ssh itself must be independent (MUX_OFF) so the kill scan sees a
  # distinct remote sshd for this session and can't match our own holder.
  ssh "${MUX_OFF[@]}" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$HOST" '
    my_pid=$$
    exclude=" $my_pid "
    pid=$my_pid
    # build exclude list of ancestors (so we dont kill our own sshd)
    while [ "$pid" != "1" ] && [ -n "$pid" ]; do
      ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d " ")
      [ -z "$ppid" ] && break
      exclude="$exclude $ppid "
      pid=$ppid
      # safety: avoid infinite loop
      case "$exclude" in *" $pid "*) break;; esac
    done
    for pid in $(ps -o pid= -C sshd 2>/dev/null); do
      pid=$(echo "$pid" | tr -d " ")
      [ -z "$pid" ] && continue
      case "$exclude" in *" $pid "*) continue;; esac
      cmd=$(ps -o cmd= -p "$pid" 2>/dev/null)
      # stale holder is exactly "sshd: dev" (no [priv], no @notty) - the unpriv child that holds forwards
      if [ "$cmd" = "sshd: dev" ]; then
        echo "  killing stale sshd pid $pid" >&2
        kill "$pid" 2>/dev/null && echo "  killed $pid" >&2 || echo "  failed to kill $pid" >&2
      fi
    done
    sleep 1
    if ss -tlnH 2>/dev/null | grep -q ":9222"; then
      echo "warn: remote 9222 still listening after cleanup (may need manual kill)" >&2
    else
      echo "info: remote 9222 cleared" >&2
    fi
  ' 2>&1 | sed "s/^/[cleanup] /" >&2 || true
  sleep 1
}

# warn if local chrome port not listening
if ! ss -tlnH 2>/dev/null | grep -qE "[: ]9222\b" && ! netstat -tln 2>/dev/null | grep -qE "[: ]9222\b"; then
  echo "warn: local 127.0.0.1:9222 not listening (is Chrome running with --remote-debugging-port=9222?)" >&2
  echo "  Chrome forwards will still be established; dev:9222 will fail until Chrome starts." >&2
fi

CMD=(ssh -N "${SSH_OPTS[@]}" "${FORWARDS[@]}" "$HOST")

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  echo "${CMD[@]}"
  exit 0
fi

# pretty banner (dynamic from FORWARDS - handles paired -L/-R entries)
echo "==> fw: $HOST"
for ((i=0; i<${#FORWARDS[@]}; i+=2)); do
  opt="${FORWARDS[i]}"
  spec="${FORWARDS[i+1]:-}"
  case "$opt" in
    -L) echo "    L $spec  (dev -> local)" ;;
    -R) echo "    R $spec  (local -> dev) Chrome DevTools" ;;
    *) echo "    $opt $spec" ;;
  esac
done
echo "    keepalive: ServerAliveInterval=15 ServerAliveCountMax=6 TCPKeepAlive=yes"
echo "    ExitOnForwardFailure=yes  (fail fast if port busy)"
if [[ "$LOOP" == 1 ]]; then
  echo "    mode: persistent (auto-reconnect, Ctrl-C to stop)"
else
  echo "    mode: single shot (--once)"
fi
echo ""

# use autossh if available (more robust), else manual loop
# (set FW_NO_AUTOSSH=1 to force the manual loop — it re-runs stale-remote
# cleanup after every forward failure, while autossh hides ssh exit codes
# and never re-cleans; preferred under systemd which supervises restarts)
if command -v autossh >/dev/null 2>&1 && [[ "$LOOP" == 1 ]] && [[ "${FW_NO_AUTOSSH:-0}" != 1 ]]; then
  echo "using autossh for auto-reconnect..."
  # autossh monitors via ServerAlive; AUTOSSH_GATETIME=0 to retry immediately
  export AUTOSSH_GATETIME=0
  export AUTOSSH_POLL=15
  # clean stale remote before starting (covers case where previous fw.sh died holding 9222)
  cleanup_stale_remote || true
  trap 'jobs -p | xargs -r kill 2>/dev/null; pkill -P $$ 2>/dev/null; echo ""; echo "interrupted."; exit 130' INT TERM
  # autossh doesn't re-clean on retry, so wrap in loop that cleans on remote-forward failure
  # we use a small wrapper: if autossh exits with 255, check and clean then retry
  while true; do
    set +e
    autossh -M 0 -N "${SSH_OPTS[@]}" "${FORWARDS[@]}" "$HOST" &
    autossh_pid=$!
    wait $autossh_pid
    rc=$?
    set -e
    if (( rc == 0 )); then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] autossh exited cleanly, reconnecting in 2s..." >&2
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] autossh exited with code $rc, checking for stale remote..." >&2
      # peek remote 9222 - if still busy, try cleanup
      if ssh "${MUX_OFF[@]}" -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "$HOST" "ss -tlnH 2>/dev/null | grep -q ':9222'" 2>/dev/null; then
        echo "remote 9222 still busy after autossh failure, running cleanup..." >&2
        cleanup_stale_remote || true
      fi
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] reconnecting in 2s..." >&2
    fi
    sleep 2
  done
  exit 0
fi

if [[ "$LOOP" == 1 ]]; then
  # manual reconnect loop
  trap 'jobs -p | xargs -r kill 2>/dev/null; pkill -P $$ 2>/dev/null; echo ""; echo "interrupted."; exit 130' INT TERM
  # initial cleanup before first connect
  cleanup_stale_remote || true
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
      if grep -qE "remote (port )?forward.*fail" /tmp/fw-last.log 2>/dev/null; then
        echo "detected remote forward failure, running cleanup..." >&2
        cleanup_stale_remote || true
      fi
    fi
    sleep 2
  done
else
  # single shot: try once, if remote forward failure try cleanup and retry once
  # also try initial cleanup if stale is obvious (avoids first failure)
  cleanup_stale_remote || true
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
  if (( rc != 0 )) && grep -qE "remote (port )?forward.*fail" /tmp/fw-last.log 2>/dev/null; then
    echo "remote forward failed, attempting cleanup and retry..." >&2
    cleanup_stale_remote || true
    echo "retrying once after cleanup..." >&2
    exec "${CMD[@]}"
  fi
  exit $rc
fi
