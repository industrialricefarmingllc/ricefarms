# Liquid glass — 2026-11-06 performance audit and pass

> **2026-11-12:** superseded by `PERFORMANCE-20261112.md` (blur-derived
> capture resolution, per-pill content cache, edge-band rim damage). The
> per-occurrence numbers below are still useful; the live preset changed.

Measured + theoretical cost model for `liquid-glass-hypr` on the live
machine. Supersedes the relevant numbers in `PERFORMANCE.md` (2026-11-04);
the earlier document's fast-path condition and bokeh state no longer match
the code/config.

## 0. Machine and live configuration

| Item | Value |
|---|---|
| GPU | NVIDIA GTX 1080 Ti, 11 GB, driver 580.178.04 |
| Hyprland | 0.57.0, plugin API 0.8.x |
| DP-1 | 2560x1440 **@165 Hz**, scale 4/3 = 1.3333, fb 2560x1440 |
| DP-2 / DP-3 | 3840x2160 **@60 Hz**, scale 2.0, fb 3840x2160 |
| eDP-1 | 2736x1824 @ scale 1.6 (internal) |
| Loaded build before this pass | `liquidglass-wash5.so` (0.8.34) |
| New build | `liquidglass-perf-20261106.so` (0.8.35), md5 `94d9d87288151c70e629daf4d899c54f` |

Actual material settings, including the `prefs.json` override tunnel (which
`hyprctl getoption` does **not** show):

| Key | Effective value | Source |
|---|---:|---|
| `capture_scale` | **1** (full-res L0) | hyprland.lua eval |
| `ca` | **0.5** | hyprland.lua eval |
| `detail_preserve` | 0 | hyprland.lua eval |
| `bokeh` | **0.5 (on)** | `prefs.json` |
| `blur_radius` / `blur_iters` | 0.8 / 2 | `prefs.json` |
| `noise` | 0 | `prefs.json` |
| `glow` master | off (weight 0, bias 0) | `prefs.json` |
| `fpower` / a / b / c / d | 0.5 / 0 / 0.5 / 6 / 10 | `prefs.json` |
| `opacity` | 0.55 | `prefs.json` |
| `windows` | `kitty,zen` | registered default |
| `layer_borders` / `window_borders` | 0 / 1 | config |
| `rim_light` / `glass_rim` / `frame_enable` | 1 / 1 / 0 | hyprland.lua |
| `window_active_glow` | 0 | hyprland.lua |
| `hide_window_shadows` | 0 (native shadows stay on) | hyprland.lua |
| Goo workspace morph | strength 0, smear 0 → **disabled** | config |

Important consequence: **bokeh is on**, and **capture_scale is 1**, so the
capture/Kawase/bokeh chain runs at framebuffer resolution. That is the
single most expensive configuration this plugin supports.

## 1. Where the material is evaluated

| Site | Shader / path | Trigger | Frequency gate | Current cost driver |
|---|---|---|---|---|
| Layer pills (bar, dock, OSD, launcher, widget cards) | `glass.frag` + capture blit + Kawase + bokeh | one pass element per matched layer surface | damage ∩ pill quad, and pill rect fully covered by damage | capture + chain + full-field pill lens |
| Window panes (kitty, zen) | `glass.frag` (`LG_WINDOW`) + capture/blit/chain/bokeh | `hkRenderWindow`, main pass | damage ∩ pane bounds | chain/bokeh unless content cache hits |
| Window borders / rim | `ring.frag` | `renderBorder` hooks | ring band ∩ damage, minus glassed panes | half-res full-window capture + band shader |
| Layer borders | `ring.frag` | same, layer path | disabled (`layer_borders=0`) | — |
| Wallpaper wash | `wash.frag` | after each window/layer draw, applied at `end` | damage ∩ draw box | full-window fill at 5–10 % |
| Shared pre-window backdrop | full-monitor blit | `RENDER_PRE_WINDOWS`, ≥2 glass windows | damage outside glass panes and transitions | full-monitor blit |
| Goo workspace morph | `GooPass`/tips | workspace transition | **disabled** (strength 0) | — |
| Blend overlay | `blend.frag` | never | sentinel file present; source not compiled | — |

There is no readback, PNG encode/decode, or CPU pixel path. All pixels stay
on the GPU.

## 2. Measurement method

Offscreen EGL/GLES 3.2 context on the same GPU, real shader sources from
`shaders/`, representative uniforms from the live `prefs.json`/config, real
draw sizes. Each sample is a batch of 20 draws followed by one `glFinish`;
median and p10 over 20–30 batches are reported. The GPU was shared with
Quickshell, Helium and Discord (70 % SM at times), so absolute medians move
by 20–50 %; p10/relative A/B numbers are stable. `p10` is the closest thing
to an uncontended GPU time.

Quality checks use pixel readback with identical uniforms:
`old` vs `patched` `glass.frag`, and full-res vs half-res bokeh.

## 3. Measured per-occurrence cost (1920x1080 reference)

Reference area: 1920x1080 = **2,073,600 px**. Per-pixel rates are the useful
scaling unit for other monitors/windows.

| Work | Measured | Rate |
|---|---:|---:|
| Window pane, old shader, ca=0.5 (slow interior) | 0.273 ms | 0.132 ns/px |
| Window pane, **patched**, ca=0.5 | **0.149 ms** | **0.072 ns/px** |
| Window pane, patched, ca=0 (fast-path upper bound) | 0.133 ms | 0.064 ns/px |
| Pill glass, 1920x1080 full-field lens | 0.210 ms | 0.101 ns/px |
| Pill glass, 427x640 (DP-1 widget at 1.333x) | 0.045 ms | 0.116 ns/px of quad |
| Pill glass, 267x53 (DP-1 bar pill) | 0.040 ms | overhead-bound |
| Bokeh 17 taps, full L0 (old) | 0.103 ms | 0.050 ns/px |
| Bokeh 17 taps, **half-res output** | **0.049 ms** | 0.024 ns/px of L0 |
| Kawase 2-iteration chain, capture_scale=1 | 0.140 ms | 0.068 ns/px |
| Kawase 2-iteration chain, capture_scale=2 | 0.075 ms | 0.036 ns/px of screen |
| Wash, full 1080p | 0.023 ms | 0.011 ns/px |
| Ring, band + shadow (actual window) | ~0.10 ms per 0.36 Mpx | 0.28 ns/px |
| Full-res capture blit | ~0.02–0.03 ms per 1080p | 0.010–0.015 ns/px |

Frame-level totals for the live geometry:

| Scenario | Per frame | Per second |
|---|---:|---:|
| Video/full repaint in one DP-2 kitty (7.66 Mpx), 60 Hz, cache hit | 0.64 ms | 38 ms/s (3.8 % GPU) |
| Drag/resize one DP-2 kitty, 60 Hz, cache miss | 1.46 ms | 87 ms/s (8.7 %) |
| Drag/resize one DP-1 window (3.69 Mpx), 165 Hz, cache miss | 0.70 ms | 116 ms/s (11.6 %) |
| 5 widget cards morphing, 60 Hz | 0.43 ms | 26 ms/s (2.6 %) |
| 3 bar pills animating, 60 Hz | 0.12 ms | 7 ms/s (0.7 %) |
| Workspace slide, 5 tiled kitties on DP-2, 60 Hz | 1.54 ms | 92 ms/s (9.2 %) |
| Ring on a non-glass DP-2 window, full damage, 60 Hz | 0.35 ms | 21 ms/s (2.1 %) |

These percentages are “fraction of one GPU-second consumed by this workload
alone”; they add across concurrent effects.

The frame total is dominated by the **capture + Kawase + bokeh** path, not
by the glass shader itself:

```
DP-2 window, 7.66 Mpx, cache miss:
  glass          0.55 ms
  Kawase chain   0.52 ms
  bokeh (half)   0.18 ms
  capture blit   0.12 ms
  wash           0.09 ms
  ----------------------
  total          1.46 ms
```

At full L0 the bokeh line is ~0.38 ms vs ~0.18 ms at half; a new-glass frame
with full-res bokeh would be ~1.65 ms. The larger single saving was the
window fast path (~0.46 ms on this pane); together they take the DP-2 frame
from ~2.11 ms (old shader + full-res bokeh) to ~1.46 ms, a 31 % reduction.

## 4. Frequency model

Let `F` be the monitor refresh (165 or 60), `D` the fraction of frames with
damage intersecting the pane, `A` the framebuffer area, `C` the fraction of
damaged frames that need a fresh capture (move/resize/backdrop change, i.e.
content-cache miss), `B` bokeh on, `W` wash on:

```
GPU_ms/s ≈ F·D·[ glass(A) + C·(blit(A) + chain(A) + B·bokeh(A))
                  + W·wash(A) ]
```

For layer pills, `C` is effectively 1 whenever the pill draws (no content
cache); for windows, `C≈0` on typing/video after the cache fix below. Borders
replace `glass(A)` with `ring(A_band)` and always pay a half-res capture when
damaged.

Static desktop: **zero** glass/blur/wash work. Hyprland does not render when
nothing is damaged, and the plugin never self-damages without a visible
change. This is the correct floor.

Per-hour examples (one effect at a time):

| Activity | Draws/hour | GPU time/hour |
|---|---:|---:|
| Cursor parked / static | 0 | 0 |
| Cursor moving over a widget (alternating pill redraw at ~82/s) | 297 k | ~26 s |
| Typing in one window, 10 keys/s, cache hit | 36 k glass draws (tiny scissored areas) | <0.02 s |
| Video in one DP-2 kitty, 60 Hz, cache hit | 216 k glass + 216 k wash | ~137 s |
| Dragging one DP-2 kitty for 60 s | 3.6 k full pipeline frames | ~5.2 s |
| One workspace slide (0.37 s) | ~22 full-screen frames | ~34 ms |
| 10 workspace slides | — | ~0.75 s |

The expensive events are therefore **full-window/full-screen motion**, not
typing, cursor motion, or idle time. This is why the content cache and the
“don't force a frame” rules are the most important frequency controls.

## 5. What was changed in this pass

### 5.1 Window interior fast path actually runs (`glass.frag`)

The window fast path was gated on `uCA < 0.001`. The live preset has
`ca = 0.5`, so **the whole pane always took the slow path**, even though at
`sdPx < -edgePx`:

- `lensMask = 0`, hence `refractVec = 0`, hence the CA vector is 0 and the
  24-tap CA block is skipped by its own `|caVec|² > 2.5e-7` test;
- the detail term compares the same taps and is exactly 0;
- the angular glow is edge-masked to 0;
- rim/shadow/bevel are edge-local or gated by `pillA`.

The condition is now `uOverRim < 0.5 && sdPx < -edgePx`. Output diff against
the old shader at identical uniforms: **PSNR 55.8–63.6 dB, max 2/255** on
window cases, i.e. not visible. Measured full-pane cost: **0.273 → 0.149 ms
(45 % less)**.

### 5.2 Rim/glow normals only where they can contribute (`glass.frag`)

The four extra SDF taps that produce `glowN` were evaluated over the entire
slow-path band (`edgePx`, ~175 px on a 1080p window), although the rim terms
are `exp(-distance/rimW)` and the glow mask is zero past the bevel band.
They are now gated by `-sdPx < max(bevW, 8·rimW)`. Output diff: **PSNR 56–999
dB, max 0–2/255**. Large-pane pill cost dropped 13–25 % (0.052→0.045 ms for
the 427x640 widget, 0.279→0.210 ms for the 1080p pill); on windows the
fast-path-only case improves ~10 % on top of 5.1.

### 5.3 Bokeh at half capture resolution (`Glass.cpp`, `WindowGlass.cpp`, `BorderGlass.cpp`)

Bokeh is a 17-tap low-frequency disc scatter. It now renders at half of L0
(both dimensions) and is sampled bilinearly by the glass/ring shader with the
same normalized UVs. Output fragments drop 4x; measured **0.103 → 0.049 ms** (2.1x) for
the 1080p bokeh pass. A synthetic smooth L0 (representative of the Kawase
output) gives **PSNR 59.9 dB, mean 0.14/255, max 7/255** between full-res and
half-res results. The glass/ring `uTexel` is kept at L0 density so dither and
CA spacing do not change.

### 5.4 Tiled-window content cache no longer defeated by the 32 px bleed (`WindowGlass.cpp`)

`reuse` used to require `useShared`, which is false whenever an earlier
window intersects the padded 32 px capture bleed. Two touching tiled windows
always do, so **every window after the first recaptured + ran Kawase + bokeh
on every typed character or video frame**. The cache now only requires that
no earlier window overlaps the *pane itself* (not the bleed). A content-only
damage inside the pane cannot change the bleed outside it, so the cached
capture is still exact; if an earlier window really overlaps the pane, the
old conservative path remains.

Expected effect on a 5-window tiled DP-2 desktop, for a window that is not
the first drawn:

- video frame: **1.46 → 0.64 ms/frame** (56 % less, ~49 ms/s saved for one
  window);
- typing: **1.46 ms/key → <0.001 ms**.

This is a frequency reduction, not just a per-frame reduction: the chain and
bokeh simply stop running on content-only frames.

### 5.5 Build/version

- `LG_VERSION` 0.8.35.
- Built and installed as `liquidglass-perf-20261106.so` (never over a mapped
  inode).
- `~/.config/hypr/hyprland.lua` now points at that file; takes effect on the
  next Hyprland restart. Revert that one line to `liquidglass-wash5.so` to
  roll back.

## 6. Validation

- `glass.frag` A/B pixel readback, identical uniforms:
  - pill 427x640: PSNR ∞, max 0/255
  - pill 267x53: PSNR 91 dB, max 1/255
  - window 1820x980: PSNR 55.8 dB, max 2/255
  - window 500x400: PSNR 63.6 dB, max 2/255
- Bokeh full vs half: PSNR 59.9 dB, mean 0.14/255, max 7/255.
- Shaders compile in the embedded build; plugin links successfully.
- Live A/B of the new `.so` requires a restart (the running process has the
  old file mapped); the offscreen numbers above are the pre-restart gate.

## 7. Remaining levers

### 7.1 Configuration (no code)

| Lever | Saving | Trade-off |
|---|---:|---|
| `capture_scale=2` | ~4x less capture/chain/bokeh fill; measured chain 0.140→0.075 ms at 1080p (more at 4K) | backdrop is half-res instead of full |
| `capture_scale=4` | ~16x less chain fill | visibly softer |
| `bokeh=0` | 0.05 ms per 1080p capture; 0.38 ms per DP-2 window | loses disc scatter |
| `windows="kitty"` | removes background zen panes | zen loses glass |
| `window_borders=0` | removes ring pass for non-glass windows (~0.35 ms/frame under full damage) | flat borders on those windows |
| `hide_window_shadows=1` | removes native shadow pass (not plugin) | no native shadows |
| `glass_rim=0` | removes rim normals/exp on slow fragments | no Apple edge light |

### 7.2 Adaptive quality during motion

The dominant cost is full-window motion. Two optional policies would preserve
the static look exactly:

- use `capture_scale=2` only while `m_motionStretch > 0` / resizing, then
  return to 1;
- skip bokeh while dragging/resizing/workspace-sliding.

Both remove work from the exact frames where responsiveness matters most.
They need an explicit user decision because the final look during motion
changes subtly.

### 7.3 Architectural

- **Pill capture cache with z-order awareness.** Window glass has a content
  cache; pills do not. A pill on top of a static backdrop could reuse its
  blurred capture when damage is only content, but proving “static backdrop”
  requires z-order/damage source information the plugin does not currently
  have. High value, higher risk.
- **Batch small pills.** Each bar/dock pill is a separate capture, FBO bind,
  ~50 uniforms and draw call. A shared atlas + instanced/UBO batch would
  collapse 3–8 small draws into one, but requires a substantial shader/ABI
  refactor.
- **Ring band-only capture.** `drawRing` blits the whole window at half res
  even though only a thin band + shadow is shaded. Four strip blits (or a
  band atlas) would cut that capture by ~90 %, at the cost of a new UV
  contract.
- **Shared-backdrop union capture.** At `capture_scale=1` the pre-window
  backdrop is a full-monitor blit. Capturing only the union of glass-pane
  rects + padding would reduce it to the tiled area, but moving/re-stacking
  windows makes invalidation subtler.
- **Goo pass scissor.** Currently disabled (strength 0). If re-enabled, its
  fullscreen 9-tap pass is a pure passthrough outside the incoming window
  rects; scissoring to the rect union + smear would be exactly equivalent.
- **Layer pass `undiscardable=true`.** Forces traversal of every glass layer
  pass every frame even when static. Moving tune/bounds detection into the
  render hook would allow discardable passes and remove the per-frame
  allocation/traversal. CPU-only, small.

## 8. Bottom line

- The material is **damage-gated**: idle desktop costs zero; typing costs
  microseconds; the real cost is full-window and full-screen motion.
- Before this pass, the live `ca=0.5` preset silently disabled the window
  interior fast path, and bokeh ran at full capture resolution. Those were
  the two largest avoidable GPU costs; both are fixed with pixel-level A/B
  evidence.
- The tiled-window bleed bug made the content cache miss on 4 of 5 tiled
  windows, so video/typing paid a full capture + Kawase + bokeh every frame.
  Fixed by separating “shared backdrop eligibility” from “per-window cache
  validity”.
- Remaining measured cost is concentrated in `capture_scale=1` motion frames:
  ~1.46 ms per DP-2 window per frame, ~9 % of a GPU-second during a drag.
  The highest-leverage remaining choices are `capture_scale=2`, bokeh off
  during motion, and the pill/ring capture refactors above.
