# lucidcap

The recorder behind LucidShot. It captures the **active workspace** on one
output using Hyprland's `hyprland_workspace_image_capture_source_v1` and
`ext_image_copy_capture_v1`, and pipes raw BGRA frames to `ffmpeg` (video plus
the PulseAudio monitor the shell mixes).

## Why not wf-recorder / grim

Those use `wlr-screencopy`, where Hyprland blits the monitor's
already-composited texture. Everything on screen is in that frame, and the
`no_screen_share` rule only paints **black rectangles** over flagged surfaces
(`src/managers/screenshare/ScreenshareFrame.cpp`, `renderMonitor`). The
workspace capture path re-renders the scene with the capture flag set
(`render/Context.cpp:38`), so flagged layers are skipped cleanly instead of
blacked out.

That is what keeps the LucidShot toolbar visible on screen but out of the
video: `SnapOverlay` reports the layer namespace `quickshell-snap`, and the
shell enables the `lucid-snap-rec` layer rule only while a take is running
(`hyprland.lua`). The rule has to stay off otherwise — `grim` (screenshots,
the overlay's re-freeze) and `hyprpicker` go through screencopy and would see
a black screen.

## Build and install

```sh
make            # generates the protocol code under gen/, builds ./lucidcap
make install    # ~/.local/bin/lucidcap
```

`wayland-scanner` and `wayland-client` development files are needed. The
protocol XMLs are vendored in `protocols/` so the build does not depend on the
system's wayland-protocols layout.

## Usage

```
lucidcap --monitor DP-1 --output take.mp4 \
         --fps 30 --audio wfrec_combined.monitor
```

- Records the active workspace on `--monitor`, and follows workspace switches
  for the duration of the take.
- `--crop x,y,w,h --logical WxH` crops in logical pixels (scaled to the
  buffer). The shell records full frames and lets the final encode crop, so it
  does not pass these.
- `--encoder h264_vaapi --device /dev/dri/renderD128` if VAAPI works; the
  shell probes it and falls back to libx264.
- SIGINT/SIGTERM stop the take: capture ends, the ffmpeg child finalises the
  file, then the process exits.
- `--list` prints outputs and workspaces (handy when the compositor or the
  protocol support is in doubt).

The shell runs it from `~/.local/bin` by absolute path because the user
service PATH does not include that directory.
