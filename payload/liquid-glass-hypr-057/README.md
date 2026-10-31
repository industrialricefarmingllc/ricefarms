# liquid-glass-hypr

Real-time liquid glass for Hyprland layer surfaces **and windows**,
rendered **in the compositor render pass** — where the pixels already are.

## Why this exists

The previous architecture (lucid-capture) shuttled pixels compositor ->
`glReadPixels` -> PNG encode (~75ms) -> `/tmp` file -> file watcher ->
QML decode (~50ms) -> texture upload -> shader. Floor: **~150-250ms per
update, ~5fps ceiling**. No tuning crosses that; 60fps needs the pixels to
never leave the GPU.

This plugin, per frame per matched layer surface:

1. blits the behind-widget region into a scratch FBO (~0.2ms),
2. runs a half-res separable blur pyramid (~0.5ms),
3. draws the glass quad scissored to each pill (~0.5ms),

then the original `renderLayer` draws text/icons crisply on top.
Total ≈ **1ms/frame** at 1440p. Nothing is read back, encoded, or written
to disk. Ever.

## Layout

- `shaders/glass.frag` — the look. Ported 1:1 from the Quickshell
  `liquidglass_true.frag` (same SDF shape modes, same `f(x)` refraction
  curve, same glow/spec/noise), minus the brute-force blur, which is now a
  real dual-Kawase pyramid. `v_texcoord` spans the pill 0..1.
- `shaders/kawase_down.frag` / `kawase_up.frag` — dual-Kawase pair adapted
  from Hyprland's own blur (vibrancy/CM stages removed): down halves
  resolution per level over 3 scratch buffers, up accumulates back. Smooth
  at any radius by construction — the 9-tap gaussian this replaced
  fragmented into sharp-edged blocks once the radius outgrew its tap
  spread. Blur radius is resolution-proportional (x monitor scale), so a
  window reads the same on 1440p and 4K.
- `shaders/bokeh.frag` — optional bright-pass scatter (golden-angle disc
  taps) composited over the Kawase base. Off by default (`bokeh` 0).
- `src/main.cpp` — init/exit, `renderLayer` + `renderWindow` hooks,
  namespace/class filters.
- `src/Glass.*` — per-surface state: geometry cache, scratch FBOs,
  capture -> pyramid -> glass draws. No config parsing here beyond reads.
- `src/WindowGlass.*` — per-window state for the kitty takeover: same
  capture -> pyramid -> `glass.frag` draw, but the rect comes straight from
  the compositor (`CWindow::getWindowMainSurfaceBox`, zero IPC), radii come
  from the window's own `rounding()`, and the tint is the terminal's
  background color (`window_tint_file`), not the theme tint.
- `src/GlassPass.*` — single `IPassElement`. `needsLiveBlur()` forces a
  fresh backdrop every frame it draws: that flag is the 60fps guarantee.
- `src/Config.*` — flat `plugin:liquidglass:*` keys (below). Read fresh
  every draw: correct across `hyprctl reload`, ~ns cost.
- `embed.py` — bakes `shaders/*.frag` into `src/Shaders.hpp` (build
  output, not committed). Shaders stay editable with highlighting.
- `qml/GlassLayout.qml` — the Quickshell side: publishes pill rects.
  Symlinked into the quickshell tree (single source of truth).

## Geometry bridge (slow path / fast path split)

Pixels stay on GPU; only *geometry* crosses the process boundary. Each
publisher surface (dock, bar, ...) writes one file:

`~/.cache/liquid-glass-hypr/liquidglass-<name>-<MON>.json` (persistent
cache dir — never `/tmp`, which wipes on reboot)
```json
{"monitor": "DP-1", "ns": "quickshell", "surface": {"w": 2560, "h": 780},
 "pills": [{"x": 610, "y": 12, "w": 380, "h": 66, "r": [33, 33, 0, 0]}]}
```

Logical px, surface-relative; radii are `[tl, tr, br, bl]`. The plugin
routes files to surfaces by measuring the conversion ratio live
(`surfaceBox / declaredSize`) and converts rects with it — self
calibrating, so monitor scale, Qt DPR and nesting quirks (all observed
to disagree) never enter the picture. A file applies when the ratio is
uniform across axes and sane (0.5–4) **and**, when the file declares an
`ns`, that namespace equals the layer surface's namespace. Size alone is
not always unique: the island bar (1368x896) and an always-mapped
launcher (1368x900) are 0.4% apart, inside the ratio tolerance, and the
bar's pills then drew on the launcher at *its* origin — the screen edge
instead of the bar's top margin. Files without `ns` keep the legacy
size-only routing. Written on every
layout change (bindings re-evaluate per morph frame — exact tracking, no
debounce by design). Absent/unparseable/non-matching file: that surface
is skipped silently. mtimes are stat'ed per frame, parsed only on change.

## Config

All `plugin:liquidglass:*`, all live (`hyprctl keyword ...`):

| key | default | QML Prefs twin |
|---|---|---|
| `enabled` | 1 | — (master switch) |
| `namespaces` | `quickshell` | — (substring match on layer namespace) |
| `power` | 3.0 | `liquidGlassPower` |
| `shape_width` / `shape_height` | 3.5 | `liquidGlassWidth/Height` |
| `a,b,c,d` | 0.7/2.3/5.2/6.9 | `liquidGlassA…D` |
| `fpower` | 1.0 | `liquidGlassFPower` |
| `noise` | 0.06 | `liquidGlassNoise` |
| `blur_radius` / `blur_iters` | 2.0 / 1 | `liquidGlassBlurRadius/Iters` |
| `capture_scale` | 4.0 | — (working-res divisor for capture + Kawase chain: 4 = quarter-res, ~4x less scratch and ~3-4x less chain traffic for a near-identical blurred backdrop; blur strength auto-corrected so the look matches; 2 = old half-res) |
| `glow_weight,bias,edge0,edge1` | 0.25/0/0.5/-0.5 | `liquidGlassGlow*` |
| `opacity` | 0.82 | `liquidGlassOpacity` |
| `tint` | `0x191113ff` | `Theme.bgOpaque` (tuner pushes live later) |
| `use_pill` | 1 | pill vs superellipse shape mode |
| `shadow_color` | `0x1a1a1a66` | `Theme.hyprShadow` (rgb + alpha) |
| `shadow_offset_x/y` | 0 / 10 | `hyprShadowOffsetX/Y` |
| `shadow_blur` | 12 | softness, fb px |
| `windows` | `kitty,zen` | — (under-glass only, comma-separated substring match on `CWindow::m_class`; non-matching (opaque) windows submit nothing; empty disables) |
| `window_over_rim` | 0 | — REMOVED, no-op (was rim-only overdraw on top of windows; deleted, nothing draws over window edges anymore) |
| `window_over_rim_exclude` | `kitty,zen` | — unused since the removal (kept registered) |
| `window_tint_file` | `~/.config/kitty/matugen-colors.conf` | — (last `background #rrggbb` wins; falls back to `tint`) |
| `window_opacity` | `-1` (= `opacity`) | — (window-only glass strength; raise toward 1 for dark terminals on bright wallpapers) |
| `bokeh` | `0` | — (0..1 highlight-disc scatter over the blur; disc size follows blur radius) |
| `frame_enable` | `1` | — (neoclassical relief on window borders; auto-off on thin bands) |
| `frame_scale` | `1.0` | — (motif period scale) |
| `frame_seed_mode` | `1` | — (1 = per-window design from geometry hash, 0 = one frame everywhere) |
| `frame_frieze` | `-1` | — (-1 = per-window pick, 0 = egg-and-dart, 1 = greek key, 2 = guilloche, 3 = fluting) |
| `frame_gilt` | `1.0` | — (0 = carved stone, 1 = full gilt crests; inactive windows go stone) |
| `frame_relief` | `1.0` | — (emboss strength: refraction steer + bevel modulation) |

Corner radii are per-pill from geometry (no global needed). `box/corner`
derivations (`menuWidth`, notch square corners) live in QML, as before.
Window radii come from the window's own rounding (windowrule + decoration).

## Windows — kitty takeover

`renderWindow` (main passes ALL/MAIN, never POPUP or snapshots) draws one
glass quad over the whole window rect inline in the hook — the same
`glass.frag` the pills use (refraction curve, glow, noise, CA, drop shadow)
— and then the original `renderWindow` draws the terminal on top. Inline on
purpose (not a pass element): the element executed detached from the
window's own draw and sampled `renderModif` stale, freezing the glass while
the window slid out on switches. Requirements and behavior:

- The terminal must be translucent (`background_opacity < 1` in kitty.conf)
  or its opaque background covers the glass. Text stays fully opaque: only
  the background lets light through.
- Tint is the terminal's color: `window_tint_file` is parsed for the last
  `background` line (kitty is last-wins, so a pinned override after the
  matugen include is honored in both dark and light modes). kitty.conf edits
  repaint via damage-on-change, same as the prefs/matugen tune generation.
  Unreadable file → falls back to the theme `tint`.
- Fullscreen-coverage windows are skipped (nothing alive behind them).
- No on-top/rim pass: glass draws only UNDER matched (translucent) windows.
  Nothing is ever drawn over regular window edges or contents.
- Glass tracks moves/resizes exactly: geometry is read live from the
  compositor, no bridge files, no polling.

## Quickshell wiring

1. Symlink `qml/GlassLayout.qml` into a quickshell module dir.
2. `LiquidGlassBg`: `externalGlass: true` hides both QML bg layers so the
   compositor glass shows through; content tiles are untouched, so
   translucency parity holds by construction. `BarPill`/`Workspaces` expose
   the same flag, which also disables their QML drop shadows (the plugin
   draws the shadow; a shadow of the transparent bg would blob around
   glyphs instead of pills).
3. One `GlassLayout` per glassed surface (`name: "dock"`, `"bar"`, ...),
   `pills` bound to the live rects. Bar pills reuse each module's own
   `surfaceX/surfaceY/surfaceWidth/surfaceHeight` + `cornerRadius` /
   `topRadius` (including the popupMode second pill); see
   `bar.glassPills` in shell.qml.

## Build / run

```sh
make            # -> liquidglass.so
hyprctl plugin unload /path/to/lucid-capture.so   # if migrating
hyprctl plugin load $PWD/liquidglass.so
```

> Hard rule learned 2026-09-04: NEVER `plugin unload` liquidglass live —
> unloading the old build SEGV'd the compositor (watchdog safe-mode
> restart, all clients lost). Fresh loads are safe; to update the .so,
> restart the Hyprland session instead of unload+load.

Lucid-capture can stay loaded during migration (it only samples now that
its visuals are elsewhere); unload it once every surface is wired and
delete the PNG machinery (`FileView` watchers, stamped URLs, usage.json
side of things stays — that's app stats, unrelated).

## Deliberate non-goals (v1)

- Chromatic aberration: 2 extra taps, unlocked after the look matches.
- Tint tracking matugen automatically: the tuner (Prefs -> keyword)
  does this next; default is a static dark neutral.
- ~~Windows: layers only. Window glass is upstream hyprglass territory.~~
  Done in v0.2.0 (kitty takeover): full-window glass via `renderWindow`.

## Workspace morph (goo, merged from hypr-goo-workspaces 0.5.0)

Gooey workspace-switch window animations, based on
[ainalem's gooey radio buttons](https://codepen.io/ainalem/pen/EbdZrx)
(outgoing windows collapse toward a point on the side the new workspace
enters from) and
[konstantindenerz's blob switch](https://codepen.io/konstantindenerz/pen/GReBKQa)
(incoming windows grow from a condensed blob with overshoot + wobble).

Why it lives here: there is exactly ONE `renderWindow` trampoline slot.
A standalone morph plugin can never own it while this plugin is loaded
(verified by disassembly: second hook is refused, warps silently never run,
force-render flags leak = permanent ghosts). The morph warps windows from
inside this plugin's hook — glass snapshots see warped geometry, so glass
follows the morph — plus a scale-anchor suck toward the edge-center point
(genie-style, no extra pixels drawn) and two retired screen-space passes
(funnel tip + fullscreen smear, both default off: extra pixels read as
ghosts).

Mechanism notes:
- `workspace.active` opens a per-monitor transition; the outgoing workspace
  is pinned with `m_forceRendering`. Progress/finish are driven from every
  path that observes a live transition (hook, rounding, goo pass) — never
  from `tick`, which only fires while native animations run. `finish()`
  always ends with a full-monitor damage so the smear pass leaves no residue.
- Roles match by workspace-pointer identity first, workspace ID second.
- Disable the stock slide so the two don't stack:
  `hl.animation({ leaf = "workspaces", enabled = false })`.
- Config: `plugin:gooworkspaces:*` (`enabled` 0 — ships off; enable live via
  `hyprctl eval "hl.config({plugin={gooworkspaces={enabled=1}}})"`,
  `duration_ms` 600, `slide_ratio` 0.18, `stretch` 0.10, `squash` 0.06, `blob_scale` 0.60,
  `collapse` 0.40, `fade_out_min` 0.33 (outgoing windows dim 1.0 -> this on the
  upstream move-from-workspace alpha channel, eased OUT so the dim reads from
  the first frames — ease-in would sit at ~1.0 for 75% of the flight; 1.0
  disables; NEVER 0.0 — Hyprland culls effectiveAlpha==0 windows from
  rendering and culled windows run no hooks, so no restore can ever reach
  them: permanently invisible. Floor is 0.02), `wobble_amp` 0.02, `wobble_freq` 1.5 (uniform breathing, same sign
  both axes — overall scale only, never width-vs-height shear),
  `stagger` 0.10 (fraction of `duration_ms` spread as per-window delays,
  e.g. 0.10 * 500ms = 50ms — RANKED even across address-sorted participants
  so any window count splits the full spread, plus a small deterministic
  hash wobble for organic feel), `spring_stiffness` 110.0 /
  `spring_damping` 13.0 / `spring_velocity` 4.0
  (mass = 1; tossed underdamped spring for `in_curve` spring — fast
  Material-style lead, ~9% overshoot, settled inside the transition;
  tracks `back` closely by design),
  `droplet` 0.0 (off), `tip_enable` 0 (off — funnel pixels read as ghosts;
  code kept for later), `tip_curve` 1.5, `tip_max` 4000.0, `genie_pull` 1.0,
  `goo_strength` 0.0 (off — the smear pass left trails),
  `goo_smear` 20.0, `goo_wobble` 6.0,
  `direction` auto (left | right | up | down | forward | backward),
  `vertical` 0 (legacy auto-mode override),
  `out_curve` expo, `in_curve` spring (true spring | back | expo | linear).
- Companion mode (recommended): stock `workspaces` owns MOTION (`slide`,
  steered per jump), the morph adds ONLY per-window alpha + scale — zero its
  motion (`slide_ratio` 0, `stretch`/`squash` 0, `collapse` 1.0, `genie_pull`
  0) or the two slides stack into chaos. Keep the stock style at `slide`
  (alpha pinned at 1, no native fade) so the `fade_out_min` dim applies
  exactly once. Full-morph mode (plugin owns motion too) is possible but
  needs stock `workspaces` DISABLED entirely.
  Live-settable via `hyprctl eval "hl.config({plugin={gooworkspaces={...}}})"`
  (`hyprctl keyword` is dead under the lua parser).
- Direction in auto mode: cross-monitor jumps aim along the physical monitor
  offset (the real edge between screens); same-monitor jumps treat workspace
  rows of 10 (1-9, 11-19, …) as vertical moves and in-row jumps as
  horizontal; everything else falls back to ID order.
- Genie suck: the scale anchor migrates toward the edge-center point, so the
  window quad itself flows into it (outgoing, leading edge first) and emerges
  out of it (incoming). No extra pixels are drawn — only the window's own
  position/scale animvars move — so this path cannot ghost by construction.
- Debug log: `~/.cache/hypr-goo-workspaces/debug.log` (begins, throttled
  role/warp samples, finishes).
