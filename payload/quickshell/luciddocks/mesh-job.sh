#!/usr/bin/env bash
# Run one mesh job in its own session so a Quickshell reload cannot kill it.
#
#   mesh-job.sh run <image> <prompts-json> <engine> <job-id>
#   mesh-job.sh resume <state-file> <job-id>
set -u

HOME_DIR="${HOME:-/home/$(id -un)}"
VENV="$HOME_DIR/src/image-to-3d/sam-3d/.venv/bin/python"
SVC="$HOME_DIR/src/image-to-3d/pipeline/lucid/mesh_service.py"
CACHE="$HOME_DIR/.cache/lucid-mesh"
mkdir -p "$CACHE"

mode="${1:-}"
shift || true

case "$mode" in
run)
    image="${1:-}"
    prompts="${2:-[]}"
    engine="${3:-local}"
    job="${4:-}"
    [ -n "$image" ] && [ -n "$job" ] || exit 2
    exec setsid "$VENV" "$SVC" --run "$image" --prompts "$prompts" \
        --engine "$engine" --job-id "$job" >>"$CACHE/job-$job.log" 2>&1
    ;;
resume)
    state="${1:-}"
    job="${2:-}"
    [ -n "$state" ] && [ -n "$job" ] || exit 2
    exec setsid "$VENV" "$SVC" --resume "$state" --job-id "$job" \
        >>"$CACHE/job-$job.log" 2>&1
    ;;
*)
    exit 2
    ;;
esac
