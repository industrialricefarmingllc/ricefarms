#!/usr/bin/env bash
# Low-latency Carla VST host launcher
# Usage: ./carla-vst.sh [project.carxp]
# Chain to wire manually (or via chain-connect.sh):
#   RODE capture -> carla:capture_* -> [VSTs] -> carla:playback_* -> VST_OUT:playback_*
set -euo pipefail
PROJECT="${1:-$HOME/audio-stack/carla/vst-mic.carxp}"
mkdir -p "$HOME/audio-stack/carla"
export PIPEWIRE_LATENCY="128/48000"
export PIPEWIRE_QUANTUM="128/48000"
# Qt5 on Hyprland/Wayland: prefer wayland, fall back to xcb (XWayland).
# (qt5-wayland installed; the ';xcb' fallback covers headless/odd sessions.)
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"
# RT priority for the DSP thread (needs realtime group / rtkit — you have both)
if [ -n "${PROJECT:-}" ] && [ -f "$PROJECT" ]; then
  exec pw-jack -p 128 carla-rack --load "$PROJECT"
else
  [ -n "${PROJECT:-}" ] && [ ! -f "$PROJECT" ] && echo "No project yet at $PROJECT — starting empty rack." >&2
  exec pw-jack -p 128 carla-rack
fi
