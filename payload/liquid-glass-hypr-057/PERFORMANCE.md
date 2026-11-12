# Liquid glass — performance model and 2026-11-04 optimization pass

> **2026-11-06:** see `PERFORMANCE-20261106.md` for the current measured
> numbers and the fast-path/bokeh/overlap-cache fixes. Some statements below
> (notably the window fast-path condition and bokeh state) no longer match
> the code or the live preset.

This document is the measured + theoretical cost model for the
`liquid-glass-hypr` shader stack on this machine (GTX 1080 Ti, Hyprland
0.57, 2560x1440@165 + 2x3840x2160@60). It covers every place the material
is evaluated, predicts how often that happens, and records the optimizations
applied in this pass.

## 1. Where the material is evaluated

| Site | Shader / path | When it runs | Current config |
|---|---|---|---|
| Layer pills (bar, dock, OSD, launcher, widget cards) | `glass.frag` + optional `kawase_*` + optional `bokeh.frag` | One pass element per matched layer surface, only on frames whose damage intersects a pill | `namespaces=quickshell,lucid-launcher,lucid-widgets`; 3 bar pills + 5 widget cards on DP-1 |
| Window panes (kitty, zen) | `glass.frag` with `LG_WINDOW` + optional `kawase_*` + optional `bokeh.frag` | `renderWindow` hook, main pass only, one pane per matched window, only on damaged frames | `windows=kitty,zen`; 5 kitty windows in the measured session |
| Window borders / rim light | `ring.frag` | `renderBorder` hooks, scissored to the ring band + shadow halo; only on border damage | `window_borders=1`, `rim_light=1`, `frame_enable=0`, `border_blur_scale=0` |
| Layer borders | `ring.frag` | Same ring, only when `layer_borders=1` | off by default |
| Wallpaper wash (windows + layer pills) | `wash.frag` | After each window/layer draw, scissored to damage | active (wash PNG exists); 5% screen / 10% multiply |
| Blend overlay | `blend.frag` | Replaces a full-screen layer draw with a soft-light composite | disabled by `~/.config/liquid-glass-hypr/blend-overlay.disabled` |
| Bokeh | `bokeh.frag` | After the Kawase chain, only when `bokeh > 0.01` | `liquidGlassBokeh=0.9` (on) |
| Kawase blur | `kawase_down.frag`, `kawase_up.frag` | Capture pyramid; skipped when the effective radius is sub-visible | `blur_iters=1`, `blur_radius=4.3`, `capture_scale=1` |
| Shared pre-window backdrop | blit only | Once per monitor per frame when >=2 glass windows and damage intersects one | full-monitor capture |
| Goo workspace morph | `GooPass` etc. | Only during workspace transitions | separate feature, not the glass material |

## 2. Per-occurrence cost (measured)

Measured offscreen with EGL/GLES 3.2 on the same GPU, using the real shader
sources and representative uniforms. Times are per draw, batch-timed with
`glFinish`; the machine was also running a CUDA workload, so treat these as
ranges. `ns/px` is useful for scaling to other areas.

| Work | Size | Before | After this pass |
|---|---:|---:|---:|
| Window pane, slow path (glow forces full slow path) | 1920x1080 | 0.34–0.42 ms | — |
| Window pane, interior fast path | 1920x1080 | — | 0.22–0.30 ms |
| Pill glass | 320x480 | ~0.02–0.05 ms | unchanged |
| Pill glass | 200x40 | ~0.001–0.009 ms | unchanged |
| Bokeh, 17 taps | 1024x1024 | ~0.06–0.15 ms | unchanged (trig precompute measured no gain) |
| Wash | 1920x1080 | ~0.16 ms | ~0.11 ms |
| Wash | 320x480 | ~0.005–0.014 ms | ~0.003–0.01 ms |
| Ring, actual 63px frame around 1868x1025 | ~0.36 Mpx | ~0.11 ms | ~0.10 ms (exp/log + early-out) |
| Ring, full quad worst case | 1920x1080 | ~0.15–0.18 ms | — |
| Kawase down 1920→960 | 960x540 | ~0.05–0.07 ms | unchanged |
| Kawase up 960→1920 | 1920x1080 | ~0.13–0.15 ms | unchanged |

Scaling rules:

- Glass and wash are fill-rate bound: `t ≈ area × ns_per_px`. Use
  ~0.10–0.20 ns/px for the window fast path, ~0.2–0.4 ns/px for the slow
  edge path, ~0.05–0.14 ns/px for wash, ~0.1 ns/px for bokeh.
- Kawase is bandwidth bound: `t ≈ pixels × taps × 4 B`. At capture divisor
  `c`, the chain works on `A/c²`, so going from `capture_scale=1` to `2`
  cuts chain fill by ~4x and capture blit by ~4x; `4` cuts it by ~16x.
- Blit estimate: 1920x1080 RGBA ≈ 8.3 MB read + 8.3 MB write ≈ 0.05 ms at
  ~300 GB/s effective; 3840x2160 ≈ 0.11 ms. The shared backdrop is the
  largest single blit in the stack.

## 3. Frequency model

Let `F` be the presentation rate of a damaged monitor, `D` the damage area,
`N_p` pills, `N_w` glass windows, `N_b` borders, `N_l` mapped layers,
`A` the surface area, `c` the capture divisor, `P` the Kawase pass count,
`B` bokeh on/off.

Per damaged frame:

```
layer glass   = Σ_pills [ blit(A_p/c²) + P·kawase(A_p/c²) + B·bokeh(A_p/c²) + glass(A_p) ]
window glass  = Σ_windows [ cached ? glass(D_w) : blit(A_w/c²) + P·kawase + B·bokeh + glass(A_w) ]
shared backdrop = blit(A_screen/c²)            (once per monitor, only if not reusable)
borders       = Σ_borders [ blit(A_band/2²) + ring(A_band) ]
wash          = Σ_windows/layers wash(D)
CPU geometry  = N_l × shared 8ms scan/parse (was N_l × N_files every frame)
CPU wash      = N_l × shared 8ms scan + mtime-gated JSON (was N_l × N_files parse every frame)
```

Important properties already in the code:

- **Damage-gated.** No damage intersecting a pill/window/border → no blit,
  no blur, no shader, no draw. A static desktop costs zero glass GPU time.
- **Content-only cache.** Typing/video damage inside a window reuses the
  cached blurred backdrop; only the damaged pixels are re-shaded.
- **Small pills skip the chain.** When the effective blur radius is below
  the visible threshold, `passes=0` and only the downsample blit + glass
  shader run.
- **No readback.** Pixels never leave the GPU; no PNG/encode/decode path.

Representative frequencies:

| Scenario | Work per second (one 1920x1080 pane) |
|---|---|
| Static desktop | 0 glass draws |
| Typing (20x30 logical caret damage, 60 Hz) | ~0.002 ms/frame × 60 ≈ 0.1 ms/s |
| Video / full-window repaint at 60 Hz, `capture_scale=1`, bokeh on | ~0.6 ms/frame × 60 ≈ 36 ms/s |
| Window drag/resize at 165 Hz | ~0.6 ms/frame × 165 ≈ 100 ms/s |
| Border focus change | ~0.1 ms once |
| Bar/widget morph at 60 Hz (8 pills) | ~0.1–0.3 ms/frame × 60 ≈ 6–18 ms/s |

The measured live session (before the safe-mode restart) showed Hyprland at
~39.5% GPU SM and ~75% CPU with the plugin, versus ~22.9% SM after disabling
layer glass and ~36.3% SM after disabling window glass. Disabling layer
glass alone removed ~13.4% SM; window glass ~3% SM. These are not a clean
baseline because the shell was continuously damaging (widgets/cursor/clock)
and a CUDA job shared the GPU, but they identify layer glass as the largest
single consumer on this desktop. The historical `CULPRITS.md` (2026-10-13)
measured window glass at 21.1% SM, over-rim at 9.6%, shadows at 4.2%, and
layer glass near 0% on the older code; the current code has since added
damage gating, the content cache, and the fast paths, so that ranking no
longer applies unchanged.

## 4. Changes applied in this pass

1. **Window interior fast path survives the active-glow boost.**
   `glass.frag` used to require `uGlowW < 0.001` for the fast path. The
   focused window carries `window_active_glow=0.2`, so the whole pane paid
   for the slow path even though the glow is edge-masked and exactly zero
   in the fast-path region. The condition is now
   `(uCA < 0.001 || uDetail < 0.001)`, which is also correct when CA is off
   (the detail term is derived from CA taps and is identically zero).
   Measured: 0.34–0.42 → 0.22–0.30 ms per full 1920x1080 pane (~35% less).
2. **Wash interior early-out.** A pixel more than one corner radius inside
   the pill's straight-sided box is inside the shape with `mask=1`; the
   superellipse `pow()` chain is skipped there. Measured: ~0.16 → ~0.11 ms
   per full 1920x1080 window (~34% less).
3. **Ring lens curve uses exp/log.** `ring.frag` now takes a precomputed
   `uLogCME` and evaluates `exp((-D·dist-A)·log(C·e))` instead of
   `pow(C·e, ...)`, with the old path as fallback. Interior-margin pixels
   also discard before the fade-axis and shadow SDF/exp work.
4. **Shared geometry scan cache.** `CGlassLayer::loadGeometry` used to
   `opendir()` + `stat()` every publisher file for every layer every frame.
   A shared per-monitor 8 ms cache now performs one scan per monitor per
   8 ms; per-file parsing is still mtime-gated. The bridge coalesces writes
   at 16 ms, so 8 ms is below the producer's own update granularity.
5. **Wash JSON cache.** `layerWashSnapshots` used to open and parse every
   publisher JSON for every mapped layer every frame. It now uses the same
   shared 8 ms scan and keeps parsed JSON until the file's mtime changes.
6. **Shared pre-window backdrop persistence.** The full-monitor backdrop
   used to be invalidated at `RENDER_POST` and recaptured whenever damage
   intersected a glass window — including typing/video damage that cannot
   change the wallpaper/bottom layers. It now persists across frames and is
   recaptured only when damage leaves a glass pane, a workspace/goo
   transition is active, the plugin is disabled, fewer than two glass
   windows are present, or the capture divisor changes.
7. **Layer border config reads only when layer borders are on.** The
   inactive-border gradient and seven border tunables are no longer read
   on every layer frame when the feature is off.
8. **Shadow SDF/exp skipped where it cannot contribute.** `glass.frag`
   skips the shadow SDF + exp when `pillA >= 0.999` (the final mix weights
   the shadow by `1 - pillA`, exactly zero there); `ring.frag` skips it when
   `sd <= push - aa` (the shadow is masked to zero inside the outer
   silhouette). Pills are mostly interior, so this removes the shadow work
   from most of their fragments.
9. **One SDF per slow fragment when shape is the default 3.5.** The
   refraction depth used a second `sdPillBox4` at `pillPx * 3.5 / uShape`;
   at the default `shape_width = shape_height = 3.5` that is exactly
   `pillPx`, so the already-computed silhouette SDF is reused.
10. **16 ms scalar config cache with tune-generation invalidation.**
    `getFloat`/`getInt` are called ~30 times per glass draw. The cache is
    cleared immediately when `tuneGeneration()` bumps (prefs/matugen/theme),
    so the damage that accompanies a change paints with the new values;
    `hyprctl eval` edits land within 16 ms.
11. **Safe versioned deployment.** The build is installed as
    `liquidglass-perf-20261104-1736.so` (earlier `...-1726.so`/`...-1733.so`);
    point `hyprland.lua` at the version you want and restart. Never `cp` over
    a `.so` a running Hyprland may have mapped; build to a new filename,
    point the config at it, and restart.
12. **`fPower=0.5` sqrt fast path.** The current Lucid preset uses
    `fpower=0.5`; `pow(x, 0.5)` is now `sqrt(x)`, alongside the existing
    `fPower=1` identity path. Saves a transcendental per slow fragment.
13. **Normal SDF taps skipped when nothing consumes them.** The four extra
    SDF evaluations that feed the Apple rim / legacy glow are skipped when
    `rim_light=0` and both glow weight and bias are zero. No change when
    either effect is on (the current config).
14. **`uTexel` uniform instead of per-fragment `textureSize`.** Dither and
    CA texel steps now use `1 / uBlurSize`, set once per draw, instead of a
    `textureSize()` query in the fragment shader.
15. **Geometry generation gate for layer glass.** The shared scan now
    carries a generation that bumps when a publisher file is added, removed
    or rewritten. `CGlassLayer::render` can return before `loadGeometry()`
    when the generation, surface box and tune generation are unchanged and
    the frame damage misses the last glass union.
16. **Allocation-free hot-path lookups.** `geoDir()` is computed once;
    scan caches are nested maps (no `dir + "|" + mon` key allocation);
    `getFloat`/`getInt`/`getString` use transparent `std::map` lookups with
    `std::string_view`; comma-separated namespace/window patterns are parsed
    once per distinct pattern instead of once per call.
17. **Wash gating.** Layer wash snapshots return immediately for
    non-glass namespaces (wallpaper/spatial/desktop/corners), and
    `windowWashDraw` skips the uniform setup and draw call when the draw box
    does not intersect the frame damage at all.

Not applied (measured or judged not worth the risk):

- Replacing the sin-based dither hash with `hash12`: measured ~30% *slower*
  on this GPU (0.22 → 0.31 ms for the window fast path). The SFU sin is
  cheaper than the extra ALU here.
- Precomputing bokeh golden-angle directions: measured within noise
  (~0.14 vs ~0.15 ms); the 17 texture taps dominate, not the trig.
- Shrinking the per-window capture to the damage rect: the current
  `damageCovers()` contract deliberately requires the whole capture region
  (pill/window + 32 px bleed) to be freshly repainted, otherwise the blur
  samples stale pixels and ghosts. The content-only cache already removes
  the frequent typing/video recapture.

## 5. Remaining levers (quality/performance trade-offs)

These are configuration choices, not code changes, because they alter the
look:

| Lever | Effect | Trade-off |
|---|---|---|
| `capture_scale=2` (from 1) | ~4x less capture/Kawase/bokeh fill and ~4x less scratch VRAM | Blurred backdrop is quarter-res instead of half-res; README calls 4 "near-identical" |
| `capture_scale=4` | ~16x less chain fill | Softer backdrop; recommended on iGPU/VRAM-constrained systems |
| `bokeh=0` | Removes the 17-tap pass (~0.12 ms per full 1080p pane) | Loses the highlight-disc scatter |
| `windows=""` or restrict to the active class | Removes per-window pane cost for background terminals | Background terminals lose glass |
| `blur_iters=1` (already) | Avoids the depth-2 cycle | Slightly less smooth large-radius blur |
| `ca=0` (optional) | Keeps the fast path active and removes 24 CA taps | No chromatic fringing |
| `detail_preserve=0` (already) | Flat tint mix instead of the contrast-gated one | Detail-preserving tint off |
| `noise=0` (already) | Skips three sin taps | No film grain |
| `layer_borders=0` (already) | No ring pass for pills | No hairline border on pills |
| `frame_enable=0` (already) | No picture-frame relief | No ornate frame |

The single biggest remaining GPU cost is full-window damage at
`capture_scale=1` with bokeh on. For a machine that values responsiveness
over the last bit of backdrop sharpness, `capture_scale=2` is the highest
leverage change. For a machine that wants the current look, the code-side
wins above are the safe floor.

## 6. Measurement method and caveats

- Offscreen EGL/GLES 3.2, real shader sources, representative uniforms,
  `glFinish`-batched draws. The CUDA workload (ComfyUI) shared the GPU, so
  absolute times vary by roughly ±30%; relative A/B comparisons were run in
  the same process.
- Live numbers came from `nvidia-smi pmon` (per-process SM%) and
  `/proc/<pid>/stat` over 6 s windows. The session restarted into Hyprland
  safe mode during the measurement run (no plugins loaded); the new build
  was compiled and installed but not loaded live.
- The plugin's own damage gating means "per frame" in this document means
  "per damaged frame that intersects the relevant bounds", not monitor Hz.
