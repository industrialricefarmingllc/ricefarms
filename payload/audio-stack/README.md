# Audio vocal chain — RODE NT-USB → VST → VAC → apps (Hyprland / PipeWire)

```
MIC IN (RODE NT-USB, 48kHz hw)
  │
  ▼
??? #1 — CAPTURE CONDITIONER (this was the gap)
  • PipeWire locks RODE to 48kHz, 128 frames, no suspend
  • conf: ~/.config/pipewire/pipewire.conf.d/10-lowlatency.conf
  •      ~/.config/wireplumber/wireplumber.conf.d/50-rode-vac.conf
  • no resampling, RT prio 900, headroom 128
  │
  ▼
VST PROCESSING (low latency, native)
  • launcher: ./carla-vst.sh  →  PIPEWIRE_LATENCY=128/48000 pw-jack -p 128 carla-rack
  • use native VST3/LV2 (LSP gate/comp/EQ, x42, RNNoise). ~2.7ms @128/48k.
  • Windows VSTs via yabridge work but add ~8-15ms + Wine jitter — avoid for live voice.
  • EasyEffects (installed) is the zero-config alternative: input → RNNoise → compressor → VST_OUT
  │
  ▼
VIRTUAL AUDIO CABLE (lowest-latency equivalent)
  • sink VST_OUT + source VST_Mic (remap of VST_OUT.monitor), 48k locked, passthrough
  • up/down: ./vac-up.sh / ./vac-down.sh  (systemd: vac.service)
  • ports: VST_OUT:monitor_FL/FR , VST_Mic:capture_FL/FR
  • measured: 128 frames = 2.7ms + Carla DSP (~1-3ms). Total mic→VAC ~5-8ms wired.
  │
  ▼
??? #2 — ROUTER / MONITOR SPLIT (this was the gap)
  • VST_OUT.monitor → wired out (Starship analog/HDMI) for zero-latency monitoring
  • VST_Mic → target apps ONLY (Discord/OBS/Browser select "VST_Processed_Mic")
  • DO NOT monitor via WH-1000XM6 Bluetooth (adds 150-250ms, defeats the chain)
  • helper: ./chain-connect.sh  • visual: qpwgraph / pavucontrol
  │
  ▼
EXCLUSIVE ACCESS GUI (python + GTK4)
  • ./vac-gui.py  (toggle Enforce ON, tick allowed apps)
  • policy: whitelisted → ONLY VST_Mic (auto-moved off RODE)
  •         others → NEVER VST_Mic (auto-moved to RODE)
  • headless: ./vac-gui.py --enforce  (systemd: vac-enforcer.service)
  • config: ~/.config/vac-gui/whitelist.json
```

## Quick start
1. `systemctl --user daemon-reload; systemctl --user restart pipewire pipewire-pulse wireplumber`
2. `./vac-up.sh` (creates VST_OUT/VST_Mic) — enable autostart: `systemctl --user enable --now vac.service`
3. `./carla-vst.sh` — in Carla: add plugins, wire RODE:capture → plugins → VST_OUT:playback (see chain-connect.sh, or use qpwgraph)
4. In Discord/OBS/etc mic select **VST_Processed_Mic**, never RODE NT-USB.
5. `./vac-gui.py` — tick allowed apps, Enforce ON. Optional daemon: `systemctl --user enable --now vac-enforcer.service`
6. Hyprland autostart (add to hyprland.conf):
   ```
   exec-once = systemctl --user start vac.service
   exec-once = python3 ~/audio-stack/vac-gui.py --enforce
   ```

## Latency notes
- `pw-metadata -n settings 0 clock.force-quantum 128` forces 128 now; `0` clears. Config defaults to 128 already.
- Verify: `pw-top`, `pw-dump | grep quantum`, `pactl list sinks | grep -i -A2 VST`.
- RODE NT-USB is 16-bit/48k USB — keep everything 48k to avoid resampling.
- Bluetooth output runs 96kHz on this box — keep it OUT of the vocal chain.

## Files
- vac-up.sh / vac-down.sh — VAC create/destroy
- carla-vst.sh — RT Carla launcher
- chain-connect.sh — port overview + suggested links
- vac-gui.py — exclusive-access GUI + enforcer
- ~/.config/pipewire/pipewire.conf.d/10-lowlatency.conf
- ~/.config/wireplumber/wireplumber.conf.d/50-rode-vac.conf
- ~/.config/systemd/user/vac.service / vac-enforcer.service
