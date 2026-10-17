#!/bin/bash

all=false
isFullRun=false
node=false
watch=false
projects=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --watch)
      watch=true
      shift
      ;;
    --all)
      all=true
      shift
      ;;
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
[ "$node" = true ] && runner="pnpm"

testCommand="test"
watchFlag="--watch false --tuiAutoExit true --parallel=8"
[ "$watch" = true ] && watchFlag="--watch true --tuiAutoExit false"

if [ "$all" = true ]; then
  $runner nx run-many -t test --tuiAutoExit true --watch false -parallel=8 --no-cache --no-cloud
elif [ ${#projects[@]} -gt 0 ]; then
  [ "$watch" = false ] && clear
  $runner nx run-many -t $testCommand --projects="${projects[@]}" $watchFlag
else
  [ "$watch" = false ] && clear
  $runner nx affected -t $testCommand $watchFlag
fi
