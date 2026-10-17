#!/bin/bash

node=false
projects=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --node)
      node=true
      shift
      ;;
    *)
      projects+=("$1")
      shift
      ;;
  esac
done

runner="bun"
verboseFlag=""
[ "$node" = true ] && runner="pnpm" && verboseFlag="--verbose"

if [ ${#projects[@]} -gt 0 ]; then
  $runner nx format:write --parallel=8 && \
  $runner nx run-many -t typecheck --projects="${projects[*]}" --parallel=8 --tuiAutoExit true && \
  $runner nx run-many -t lint --fix --projects="${projects[*]}" --parallel=8 --tuiAutoExit true
else
  $runner nx format:write $verboseFlag --parallel=8 && \
  $runner nx affected -t typecheck --parallel=8 --tuiAutoExit true && \
  $runner nx affected -t lint --fix --parallel=8 --tuiAutoExit true
fi
