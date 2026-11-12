#!/bin/sh
# Wire the QML into the running lucid shell and the CLI into ~/.local/bin.
set -eu
exec python3 "$(dirname "$0")/scripts/install.py" "$@"
