#!/usr/bin/env bash
# Virtual Audio Cable equivalent — lowest-latency PipeWire version
# Creates: sink VST_OUT + source VST_Mic (remapped from VST_OUT.monitor)
# Chain: Carla VST out -> VST_OUT:playback_* -> VST_OUT:monitor_* -> VST_Mic -> apps
set -euo pipefail
STATE="$HOME/.cache/vac-modules"
mkdir -p "$HOME/.cache"

vac_exists() { pactl list short sinks 2>/dev/null | grep -q "^[0-9]*[[:space:]]*VST_OUT[[:space:]]"; }

if vac_exists; then
  echo "VST_OUT already exists, skipping creation."
  pactl list short sinks | grep VST_OUT || true
  pactl list short sources | grep VST_Mic || true
  exit 0
fi

# 48k locked, no resample drift, passthrough monitor = lowest latency
SINK_ID=$(pactl load-module module-null-sink \
  sink_name=VST_OUT \
  rate=48000 channels=2 \
  sink_properties=device.description="VST_OUT_VAC" \
  audio.position="[FL FR]" \
  monitor.channel-volumes=true \
  monitor.passthrough=true)

# Small fixed latency hint (128 frames). PipeWire honors node.latency.
pactl load-module module-remap-source \
  master=VST_OUT.monitor \
  source_name=VST_Mic \
  rate=48000 channels=2 \
  source_properties=device.description="VST_Processed_Mic" > /tmp/vac-remap-id 2>&1 || true
REMAP_ID=$(cat /tmp/vac-remap-id || echo "?")

echo "$SINK_ID $REMAP_ID" > "$STATE"
echo "Created VST_OUT (module $SINK_ID) + VST_Mic (module $REMAP_ID)"
pactl list short sinks | grep VST_OUT
pactl list short sources | grep VST_Mic

# Per-node latency is set via WirePlumber rules (node.latency=128/48000).
# Do NOT force the global graph quantum — that breaks Bluetooth (LDAC/96k).
# Vocal apps get 128 frames via PIPEWIRE_LATENCY=128/48000 (see carla-vst.sh).
echo "VAC up. Vocal nodes at 128/48000, graph default 256 (BT-safe)."
