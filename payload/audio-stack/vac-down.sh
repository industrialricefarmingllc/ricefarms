#!/usr/bin/env bash
# Tear down VAC
set -euo pipefail
STATE="$HOME/.cache/vac-modules"
if [ -f "$STATE" ]; then
  read -r SINK_ID REMAP_ID < "$STATE" || true
  pactl unload-module "$SINK_ID" 2>/dev/null || pactl unload-module module-null-sink 2>/dev/null || true
  # remap id may be stale; try to unload by name lookup
  for id in $(pactl list short modules 2>/dev/null | grep -e remap-source -e null-sink | cut -f1); do
    # only unload VAC-related (check args contain VST_)
    if pactl list modules 2>/dev/null | grep -A2 "Module #$id" | grep -q VST_; then
      pactl unload-module "$id" 2>/dev/null || true
    fi
  done
  rm -f "$STATE"
  echo "VAC down."
else
  # fallback: unload any VST_ modules
  for id in $(pactl list short modules 2>/dev/null | grep -e null-sink -e remap-source | cut -f1); do
    pactl unload-module "$id" 2>/dev/null || true
  done
  echo "VAC down (fallback)."
fi
pw-metadata -n settings 0 clock.force-quantum 0 2>/dev/null || true
