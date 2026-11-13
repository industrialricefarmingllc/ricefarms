# Liquid glass — 2026-11-12 full cost audit and frequency pass

Measured + theoretical model for every place the material is evaluated on
this machine, plus the optimizations applied in this pass (0.8.36).

Supersedes the cost numbers in `PERFORMANCE-20261106.md` where they differ:
the live preset changed (radius 0.8, bokeh on, `squircle_f` 0.8, cursor rim)
and the plugin now auto-selects the capture resolution from the requested
blur, caches layer-pill captures across content-only frames, and confines
cursor-rim damage to the edge band.

## 0. Machine and live configuration

| Item | Value |
|---|---|
| GPU | NVIDIA GTX 1080 Ti, 11 GB, driver 580.178.04, 1480-1911 MHz |
| Hyprland | 0.57.0, plugin API 0.8.x, live build before this pass `liquidglass-rimwidgets-20261112c.so` |
| New build | `liquidglass-perf-20261113.so` (0.8.36), md5 `6debb06fadd2e94301c0f577ac3ad6ca` |
| DP-1 | 2560x1440 **@165 Hz**, scale 4/3, framebuffer 2560x1440 |
| DP-2 | 3840x2160 @60 Hz, scale 2.0 |
| DP-3 | 3840x2160 @60 Hz, scale 2.0 |
| Live pills | DP-1: 4 bar pills + 4 widget cards (1 x 320x480, 3 x 152x152 logical); DP-2/3 widgets currently empty |
| Window glass | `windows="kitty,zen"`; 4 kitty + 1 chrome window mapped |
| Borders | `window_borders=1`, `layer_borders=0`, `frame_enable=0`, `rim_light=1` |

Effective material settings (prefs.json overrides the registered values; the
plugin's prefs tunnel is authoritative — `hyprctl getoption` does **not** show
these):

| Key | Effective |
|---|---:|
| `blur_radius` / `blur_iters` | **0.8 / 2** |
| `capture_scale` | **1** |
| `bokeh` | **0.5 (on)** |
| `ca` / `detail_preserve` / `noise` | **0.5 / 0 / 0** |
| `a, b, c, d, fpower` | 0, 0.5, 6, 10, 0.5 |
| `opacity` | 0.55 |
| `squircle_f` | 0.8 (superellipse exponent n = 5.2) |
| glow | off (weight 0, bias 0) |
| `glass_rim` / `rim_follow` | 1 / 1 |
| Goo morph | disabled |

The practical consequence: the requested blur is only **2.26 px** on the 4K
outputs (0.8 × √2 × scale 2) and **1.51 px** on DP-1. Before this pass the
capture and the 4-pass Kawase chain still ran at full framebuffer resolution,
and bokeh ran at half of full resolution.

## 1. Every instance of the material

| # | Site | Shader / path | When it runs | Area driver |
|---|---|---|---|---|
| 1 | Layer pills (bar, widgets, launcher, OSD, dock) | `glass.frag` (pill path) + capture blit + Kawase + bokeh | one pass element per matched layer surface; only frames whose damage intersects a pill | pill + 32 px bleed, or just the damage when the capture cache hits |
| 2 | Window panes (kitty, zen) | `glass.frag` (`LG_WINDOW`) + capture + chain + bokeh | `renderWindow` hook, main pass, only damaged frames | window + 32 px bleed; content-only frames reuse the cached capture |
| 3 | Window borders / Apple rim | `ring.frag` | `renderBorder` hooks; ring band ∩ damage | window + shadow halo at half res (capture), band only (shader) |
| 4 | Layer borders | `ring.frag` | same hook, only when `layer_borders=1` | same |
| 5 | Wallpaper wash | `wash.frag` | after each window/layer draw | damage ∩ draw box |
| 6 | Shared pre-window backdrop | full-monitor blit | `RENDER_PRE_WINDOWS`, ≥2 glass windows, damage outside panes | monitor at the effective capture divisor |
| 7 | Over-rim window edge | `glass.frag` + fixed r3 chain | only when `over_rim=1` (off) | edge band only |
| 8 | Rim-only widgets | `ring.frag` | master switch off, `glass_rim` on | edge band only |
| 9 | Goo workspace morph | `GooPass` | workspace transitions (disabled here) | — |
| 10 | Blend overlay | `blend.frag` | sentinel file present (disabled) | — |

There is still no readback, encode/decode, or CPU pixel path. All pixels stay
on the GPU.

## 2. Per-occurrence processing time (measured)

Method: offscreen EGL/GLES 3.2 on the same GTX 1080 Ti, the real shader
sources, live uniforms. Each sample is a batch of 10 sequential draws (one
`glFinish`), median of 15 batches; A/B variants run interleaved in the same
process. The GPU was shared with the live desktop (30-55 % SM), so absolute
values are inflated by up to ~2x versus the p10 numbers in the 2026-11-06
report; **relative ratios are stable** and are what the optimization decisions
use.

### 2.1 Raw shader fill rates

| Work | Size | Time | Rate |
|---|---:|---:|---:|
| Window pane, fast interior (live: fast path) | 1820x980 | 0.125 ms | 0.070 ns/px |
| Window pane, same shader, pill full-field | 427x640 | 0.046 ms | 0.162 ns/px |
| Bar pill | 348x53 | 0.026 ms | overhead-bound |
| Ring, 24 px band (4 scissored strips) | 1920x1080 | 0.020 ms | — |
| Ring, full quad (interior discarded) | 1920x1080 | 0.055 ms | 0.027 ns/px |
| Wash | 1920x1080 | 0.041 ms | 0.020 ns/px |
| Bokeh, 17 taps at half of L0 | 960x540 | 0.099 ms | 0.048 ns/px of L0 |
| Kawase, 4 passes at full L0 | 2560x1440 | 0.194 ms | 0.053 ns/px screen |

The pill path costs **2.3x** the window fast path per pixel because its lens
is full-field (`uLensBand=0`) and it evaluates the refraction/CA/rim work over
the whole shape. This pass adds an interior fast path for pills too: beyond
`max(edgePx, 0.35 rMax)` the lens is numerically identity, the rim/glow are
zero and the shadow is gated off, so the same early return the window path
uses applies. Measured against the previous shader: PSNR **71.5 dB, max 2/255**
on a 427x640 card (interior is ~12 % of that pill; larger cards gain more).

### 2.2 Whole capture pipeline (the part that dominated live cost)

The per-pill/per-window pipeline is: blit → Kawase → bokeh → glass. Measured
with the real sequence at the live blur (0.8, 2 iterations) and 4K:

| Stage | `capture_scale=1` (old) | auto divisor 2 (new) | Ratio |
|---|---:|---:|---:|
| capture blit (4K window) | 0.157 ms | 0.073 ms | 2.2x |
| Kawase 4 passes | 0.951 ms | 0.218 ms | 4.4x |
| bokeh 17 taps | 0.333 ms | 0.074 ms | 4.5x |
| glass shader | 0.672 ms | 0.622 ms | 1.08x |
| **total per full 4K window capture** | **2.10 ms** | **1.03 ms** | **2.05x** |

At 1820x980 the same pipeline is 0.57 → 0.36 ms (1.56x). At a 427x640 widget
(DP-1 scale 1.333) it is 0.199 → 0.108 ms (1.84x). At a 348x53 bar pill it is
0.168 → 0.063 ms (2.65x), because the four chain passes are fixed overhead on
a tiny buffer.

The auto divisor is derived from the blur the user asked for:

```
R      = blur_radius * sqrt(blur_iters) * monitor_scale   (screen-space blur, fb px)
div    = clamp(floor(2 R), 1, min(2, capture_scale))
```

A working texel may be at most ~2R wide before its bilinear footprint becomes
the dominant blur. The cap at 2 is deliberate: a 4:1 `glBlitFramebuffer` with
`GL_LINEAR` is not a proper box filter (it skips source texels) and aliases
high-frequency backdrops; 2:1 is an exact 2x2 box. The user's `capture_scale`
remains an upper bound (lower = sharper).

### 2.3 Content-only frames

Layer pills now cache the full-pill blurred capture. When the frame's damage
is confined to the pill and no large lower-window change is detected, the blit,
the four Kawase passes and the 17 bokeh taps are skipped; only the glass shader
runs, scissored to the damage rectangle.

For a 427x640 card, a content-only frame costs the glass shader on the damaged
area only:

| Damage | Pixels | Glass time | vs capture pipeline (0.108 ms) |
|---|---:|---:|---:|
| Rotating disc 50x50 | 2.5 k | 0.0004 ms | 270x less |
| Visualiser 200x100 | 20 k | 0.0032 ms | 34x less |
| Full pill repaint | 273 k | 0.046 ms | 2.3x less |

The cache is refreshed at least every 8 content-only frames when a window
overlaps the pill (bounds staleness from a small lower-window change to
~133 ms @60 Hz), and immediately on any large damage, move, resize, tune
change, transition, or overlap. `LIQUIDGLASS_NO_PILL_CACHE=1` disables it;
`LIQUIDGLASS_PILL_CACHE_ANY=1` ignores the window-overlap guard.

## 3. Frequency model

Let `F` be the presentation rate of the damaged monitor, `D` the fraction of
frames with damage intersecting the site, `c` the effective capture divisor,
`P` the Kawase pass count (0 or 4 here), `B` bokeh on, `H` the capture-cache
hit fraction.

```
pill   = Σ_pills [ H·glass(damage) + (1-H)·(blit(A/c²) + P·kawase(A/c²) + B·bokeh(A/4c²) + glass(A)) ]
window = Σ_windows [ cached ? glass(damage) : blit(A/c²) + P·kawase + B·bokeh + glass(A) ] + wash(damage)
ring   = Σ_borders [ blit(A/4) + ring(band) ]        # border_blur_scale=0: no chain
wash   = Σ_windows/layers wash(damage)               # ~0.020 ns/px
shared = blit(A_screen/c²)                           # once per monitor, only if not reusable
CPU    = per-layer geometry/JSON scan (8 ms shared cache, mtime-gated parse)
```

Important properties (all present in the code):

- **Damage-gated**: no damage intersecting a pill/window/band → no blit, blur,
  shader, or draw. A static desktop is exactly zero.
- **Content-only capture cache**: typing, progress bars, clocks, rotating
  album art and visualisers reuse the blurred backdrop; only the damaged
  pixels are re-shaded.
- **Automatic capture LOD**: the capture/Kawase/bokeh chain runs at the
  resolution the requested blur can actually resolve, not at L0 by default.
- **No self-damage loop**: the cursor-follow rim now damages only the edge
  band, and the filter snaps when its remaining error is sub-visible. This
  removes the previous ~2 s of full-surface repaints after every pointer move.
- **No readback**: pixels never leave the GPU.

### 3.1 Predicted rates with the live configuration

Per damaged frame, 4K window (3840x2160, c=2):

| Scenario | Capture pipeline | Glass/wash | Total/frame | At 60 Hz |
|---|---:|---:|---:|---:|
| Video / full repaint, capture cache hit | 0 | 0.62 + 0.16 wash | **0.78 ms** | **47 ms/s** |
| Drag / resize, cache miss | 0.37 | 0.62 + 0.16 | **1.15 ms** | **69 ms/s** |
| Typing (2x30 px caret) | 0 | ~0.001 | **~0.001 ms** | **~0.06 ms/s** |
| Cursor over a bar pill, cache hit | 0 | ~0.001 | **~0.001 ms** | **~0.17 ms/s @165 Hz** |

Layer pills on DP-1 (8 pills, 165 Hz), before vs after this pass:

| Work | Before (per frame) | After, cache hit (per frame) |
|---|---:|---:|
| 4 bar pills + 4 widget cards, capture+chain+bokeh | ~0.80 ms | 0 (amortised ~0.10 ms every 8 frames when over a window) |
| Glass over the actual damage (visualiser/disc/clock) | ~0.07 ms | ~0.02 ms |
| **Total** | **~0.87 ms/frame → 144 ms/s (14.4 %)** | **~0.03-0.13 ms/frame → 5-21 ms/s (0.5-2.1 %)** |

The live A/B measured **17 GPU-SM points** attributable to layer glass under a
continuously animating desktop (8 pills at 165 Hz), versus no measurable cost
for window glass or borders in that session. The table above is the
per-occurrence explanation of those 17 points: eight small capture pipelines
per frame at 165 Hz. The cache and the auto divisor target exactly that term.

Window glass is not the hot site on this desktop today, but the same pass
removes half of its per-capture cost (2.10 → 1.03 ms at 4K) and makes typing
effectively free.

### 3.2 Per-hour examples (one effect at a time)

| Activity | Draws/hour | GPU time/hour |
|---|---:|---:|
| Static desktop | 0 | 0 |
| Typing in one window, 10 keys/s | ~36 k tiny scissored draws | < 0.02 s |
| Video in one 4K glass window, 60 Hz, cache hit | 216 k glass + 216 k wash | ~168 s (4.7 %) |
| Dragging one 4K glass window for 60 s | 3.6 k full pipelines | ~4.1 s |
| One workspace slide (0.37 s, 5 tiled 4K windows) | ~22 full frames | ~100 ms |
| Widget card visualiser, 165 Hz, cache hit | 594 k small draws | ~2-7 s |
| Cursor parked / idle | 0 | 0 |

The expensive events are **full-window/full-screen motion and full-pane
content repaint**, not typing, cursor motion, or idle time. That ordering did
not change; this pass reduces both the per-occurrence cost (2x) and the
frequency of the expensive occurrence (capture cache, rim-band damage).

## 4. Changes in this pass

1. **Blur-derived capture divisor** (`lg::effectiveCapDiv`, Glass.hpp).
   `R = radius·√iters·scale`; `div = clamp(floor(2R), 1, min(2, capture_scale))`.
   Applied to layer pills, window panes, and the shared pre-window backdrop
   (so their UV contracts still match). Measured output at div 2 vs the old
   full-res chain: **PSNR 63.8-66.2 dB on smooth backdrops, max 1/255**; on a
   worst-case 8 px checkerboard **51.5 dB, mean 0.375/255** at 4 passes. The
   capture/chain/bokeh fill drops 4x (2.05x end-to-end at 4K because the glass
   shader is unchanged).
2. **Chain skip only for sub-quarter-texel taps** (`effR < 0.25`). A 1-texel
   tap is *not* dropped: at the live 0.8 radius the 2:1 capture blurs ~1 px,
   but the chain still supplies the rest of the requested radius
   (checkerboard A/B: 51 dB with 4 passes vs 25 dB without). This avoids the
   tempting but visibly softer "skip the chain" shortcut.
3. **Layer-pill capture cache** (`lg::SPillCapture`). Full-pill blurred
   capture, per pill slot, reused when damage is confined to the pill and the
   backdrop cannot have changed. Skips blit + 4 Kawase passes + bokeh on
   content-only frames. Conservative guards: geometry/tune/divisor/passes/
   bokeh key, union/mask opt-out, window-overlap check with a bounded 8-frame
   reuse run for small changes. `LIQUIDGLASS_NO_PILL_CACHE=1` escape hatch.
4. **Pill interior fast path** (`glass.frag`). Same proof as the window fast
   path: beyond `max(edgePx, 0.35 rMax)` the full-field lens is numerically
   identity, rim/glow are edge-masked, shadow is gated by `pillA`, and the
   bevel trio has saturated. Output A/B: **PSNR 71.5 dB, max 2/255**.
5. **Cursor-follow rim damages the band, not the surface.** Four strips of
   `max(bevW, 8·rimWidth)+2` px replace full-window/full-pill damage in layer
   glass, window glass, and border rings. For a 4K window that is 0.41 Mpx
   instead of 8.29 Mpx (**20x** less); for a 1.9 Mpx window, 0.19 Mpx instead
   of 1.9 Mpx (10x). This was a self-sustaining loop: every filter step
   damaged the whole surface, the next frame advanced the filter, repeat.
6. **Rim filter snap at 0.5°** (`RimFollow.cpp`). The exponential never reached
   its target, so the "angle changed" gate kept repainting for ~2.4 s after
   each pointer move. Snapping when the residual is sub-visible ends the chain
   after ~0.4 s at 165 Hz (0.5° changes the lit-edge dot product by <2e-3).
7. **`ring.frag` fPower fast path**: `pow(x, 0.5)` → `sqrt`, `pow(x, 1)` →
   identity (the live preset is 0.5); `pow(dot, 2)` → multiply; removed a
   redundant `normalize` on an already-normalized normal. Output A/B against
   the previous shader: PSNR **111-117 dB, max 1/255**.
8. **Version 0.8.36** built as `liquidglass-perf-20261113.so`; the config
   points at it. Never overwrite a mapped `.so`; the compositor keeps the
   previous build until the next restart.

   **Startup loading:** load at `hyprland.start` (first frame) and apply the
   preset in the same shell command, after `hyprctl plugin load` returns.
   `hyprctl` is synchronous, so the plugin's config keys exist before the
   evals run; there is no wall-clock delay in the config.

   **Startup crash root cause (2026-11-13):** the normal session was aborting
   in `CCompositor::initServer`, but the culprit was the freshly rebuilt
   `hypr-touch-gestures.so` (23:44), not liquid glass. With that plugin
   disabled, the same glass build and the full monitor/workspace config boot
   cleanly across repeated restarts. The 0.57 `end(CRenderContext&)` hook fix
   in this build is still required (the earlier the stale build called it with
   a missing argument). Touch gestures are disabled in `custom.lua` until that
   plugin is rebuilt for 0.57.

## 5. Validation

- `glass.frag` interior fast path vs previous shader, identical uniforms:
  427x640 pill **PSNR 71.5 dB, max 2/255**; 348x53 pill 116.8 dB, max 1/255.
- `ring.frag` micro-opts vs previous: **PSNR 111.4-116.8 dB, max 1/255** on
  window and pill scenes.
- Auto divisor (2) + full chain vs divisor 1 + full chain: smooth backdrop
  **63.8-66.2 dB, max 1/255**; checkerboard **51.5 dB, max 12/255** at 4K
  (structurally identical, only the capture grid differs). At DP-1
  (scale 1.333, 1.51 px requested blur): smooth **60.5 dB**, checkerboard
  **43.4 dB, mean 0.91/255** — the tighter grid is the worst case, and the
  output still differs by less than one code value on average.
- The 4-pass chain is retained at the live radius (checkerboard 51.5 dB vs
  25.2 dB without), so the requested blur is not silently reduced.
- Both shaders compile in the embedded build and in the offscreen GLES 3.2
  harness; the plugin links.
- Live loading was **not** performed: the running Hyprland has the previous
  `.so` mapped, and unloading it SEGVs (documented in the repo). Point the
  config at the new file and restart.

## 6. Remaining levers (not applied)

| Lever | Saving | Why not now |
|---|---|---|
| **Per-window shaded-result cache** | video/typing glass 0.62 → ~0.12 ms (blit) per 4K frame; ~30 ms/s on a full-screen video | needs a per-window full-res FBO + composite shader; must bypass during motion; not the hot site on this desktop |
| **Shared pre-layer backdrop** | one capture + one chain + one bokeh per monitor per frame instead of per pill; removes the self-damage loop entirely | needs per-layer-tier capture and z-order handling when pills overlap across tiers |
| **Ring band-only capture** | 4K border capture 1.9 Mpx → ~0.13 Mpx (15x) | needs a 4-strip atlas/UV contract; borders are not the hot site here |
| **Capture div 4 with a two-step 4x4 box downsample** | 4x more chain/bokeh headroom | only quality-safe when `2R ≥ 4`; the live 2.26 px blur wants div 2 |
| **Batch pill draws / UBO** | ~25 GL calls × 8 pills per frame (CPU) | small relative to GPU fill; needs a shader/ABI refactor |
| **Adaptive quality during motion** | skip bokeh / div 4 while dragging or sliding | changes the look only during motion; needs a user decision |
| **`window_borders=0`** | removes ring capture for non-glass windows | visual choice; measured no effect in the live session |
| **`bokeh=0`** | 0.07 ms per 4K capture frame | visual choice; bokeh is on by design |

## 7. Bottom line

- The material is **damage-gated**: idle is zero, typing is microseconds, and
  the only expensive frames are full-window/full-screen motion and full-pane
  content repaint.
- The live 17-point layer-glass cost is **eight small capture pipelines per
  frame at 165 Hz**, not the glass shader. This pass caches the full-pill
  blurred backdrop across content-only frames (the visualiser/disc/clock
  case) and runs the capture/chain/bokeh at the resolution the 0.8 px blur can
  actually resolve (4x less fill), which is the correct place to remove the
  work.
- The second frequency bug was the cursor-follow rim: every filter step
  damaged the entire surface for ~2.4 s after each pointer move. Band-only
  damage + a sub-visible snap threshold reduces that work by roughly 20-40x
  while keeping the visible light motion.
- The pixel cost of the glass itself is now close to the cost of compositing
  it: a window interior is 0.070 ns/px, a full-field pill 0.162 ns/px, and
  both have an exact fast path for the regions where the lens is identity.
- The next 2-4x on full-screen video is a shaded-result cache; the next 2-4x
  on many-pill desktops is a shared per-layer-tier backdrop. Both are
  architectural, not micro-optimizations, and are listed above with their
  correctness contracts.
