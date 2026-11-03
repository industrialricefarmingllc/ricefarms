#!/bin/sh
# launch-detached.sh TOKEN COMMAND
#
# Run COMMAND in its own transient systemd scope instead of leaving it in
# quickshell's cgroup. Quickshell's execDetached() uses QProcess::startDetached,
# which starts a new session but does not leave the shell's cgroup. With
# systemd's default KillMode=control-group, stopping or restarting
# quickshell.service kills every process in that cgroup, including apps the
# launcher started. A transient scope gives the app its own cgroup, so it
# survives shell restarts and crashes.
#
# TOKEN names the scope unit and is exported as LUCID_LAUNCH_TOKEN, which the
# launcher's window pinning reads from /proc/<pid>/environ. Without a systemd
# user manager (a bare TTY, for example) this falls back to a plain detached
# exec, which is the old behaviour.

set -eu

token=${1:-lucid-$(date +%s)-$$}
cmd=${2:-}

if [ -z "$cmd" ]; then
    echo "usage: $0 TOKEN COMMAND" >&2
    exit 2
fi

LUCID_LAUNCH_TOKEN=$token
export LUCID_LAUNCH_TOKEN

runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
if command -v systemd-run >/dev/null 2>&1 && [ -S "$runtime/systemd/private" ]; then
    exec systemd-run --user --scope --quiet --collect --slice=app.slice \
        --unit="$token" -- sh -c "$cmd"
fi

exec sh -c "$cmd"
