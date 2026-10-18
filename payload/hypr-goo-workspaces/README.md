# hypr-goo-workspaces — MERGED into liquid-glass-hypr 0.5.0

> This standalone plugin is **retired**. There is exactly one `renderWindow`
> trampoline slot and liquid-glass-hypr owns it, so the morph now lives
> inside that plugin (same code: `src/Goo*.cpp`), warping windows from within
> its hook. See `~/src/liquid-glass-hypr` (README "Workspace morph" section).
> The sources here remain as history; the last standalone binary is archived
> as `gooworkspaces.so.retired-0.3.0-standalone` (do NOT load it alongside
> liquidglass — double hooks). Config keys (`plugin:gooworkspaces:*`) and the
> debug log (`~/.cache/hypr-goo-workspaces/debug.log`) are unchanged.

---

Gooey / liquid workspace-switch window animations for Hyprland — an overhaul
of the stock workspace slide, based on two CodePen references:

| Reference | What it does | How it's mapped here |
|---|---|---|
| [ainalem — Gooey radio buttons](https://codepen.io/ainalem/pen/EbdZrx) | An indicator ball stretches toward the newly selected option; an SVG goo filter (`feGaussianBlur` + `feColorMatrix` alpha threshold) fuses the shapes with liquid surface tension. | **Outgoing windows** collapse toward a point on the side the new workspace enters from (like the old selection shrinking into the new one) — scale down with the grow anchor pulled entry-side, a mid-transition liquid reach along the motion axis, droplet rounding, sliding out. A screen-space directional smear fuses outgoing and incoming mid-transition. |
| [konstantindenerz — Blob Switch](https://codepen.io/konstantindenerz/pen/GReBKQa) | A blob toggle wobbles through intermediate shapes, then settles with spring overshoot. | **Incoming windows** travel in from the entry side while growing from a condensed blob scale (`blob_scale`) with `easeOutBack` overshoot plus a damped-sine wobble (`wobble_amp` / `wobble_freq`), leading with the entry edge via cascade stagger. |

One honest deviation: the SVG goo filter thresholds *alpha*, which doesn't
exist on an opaque composite (wallpaper everywhere). Thresholding luminance
instead would posterize your wallpaper, so the screen-space pass does the
motion-liquid half (directional smear + wobble, envelope-gated to
mid-transition) while geometry (stretch/squash/blob/wobble/droplet) carries
the shape morph.

## How it works

1. `workspace.active` opens a per-monitor transition (`old → new`, entry
   side from id delta or forced). The outgoing workspace is pinned with
   `m_forceRendering` so its windows still reach the renderer. Tracking
   state is also seeded lazily from rendering (`activeWorkspaceID` +
   workspace objects harvested from live windows), so the first switch
   after (re)load animates fully.
2. The `renderWindow` hook classifies each window (`OUTGOING` / `INCOMING` /
   none), maps global progress through the cascade stagger (entry-edge
   windows lead), and temporarily warps `positionAnimation` / `sizeAnimation`
   around the original call (`setValueAndWarp`, restored immediately after —
   no fighting with layout animation goals).
3. A `CWindow::rounding()` hook adds droplet rounding peaking
   mid-transition (`droplet`, 0 = off).
4. At `RENDER_POST_WINDOWS` (exactly once per monitor render — after all
   workspace windows, before top/overlay layers and cursor) a custom
   `EK_CUSTOM` pass element blits the frame to scratch and rewrites it with
   the directional-smear shader. Shell stays crisp, cursor stays sharp
   (even software cursor — it draws later). The element reports an empty
   `opaqueRegion`, so it can never occlusion-cull anything after it.
5. A `tick` listener damages participating monitors every frame and releases
   the outgoing workspace at expiry — including one final full damage so the
   goo pass never leaves smeared residue. Mid-transition switches retarget
   cleanly; pinned / special-workspace / mirror / snapshot paths are skipped.

Window roles match by workspace-pointer identity first (exact, no ID
semantics), with workspace-ID comparison as fallback.

Debug log: `~/.cache/hypr-goo-workspaces/debug.log` records transition
begins, throttled per-window role/warp samples, and finishes (size-capped).
If a switch ever looks wrong, this file says exactly what the plugin saw.

## Install

```bash
cd ~/src/hypr-goo-workspaces
make                    # produces gooworkspaces.so
hyprctl plugin load $(pwd)/gooworkspaces.so
```

Persist across (re)loads with the guarded pattern (loading the same `.so`
twice aborts the compositor; never unload live):

```lua
hl.exec_cmd("hyprctl plugin list 2>/dev/null | grep -q hypr-goo-workspaces || hyprctl plugin load /home/nicerice/src/hypr-goo-workspaces/gooworkspaces.so")
```

Disable the built-in workspace slide so the two don't stack (lua is
authoritative if you use it):

```lua
hl.animation({ leaf = "workspaces", enabled = false })
```

```ini
animations {
    animation = workspaces, 0
}
```

Unload: don't, live (GL teardown off-context SEGVs — same as
liquid-glass-hypr). To update: rebuild, then reboot / exit-cycle.

## Config — `plugin:gooworkspaces:*` (all live via `hyprctl keyword`)

| key | default | notes |
|---|---|---|
| `enabled` | 1 | master switch |
| `duration_ms` | 550 | 450–650 reads "liquid"; lower reads "snappy" |
| `slide_ratio` | 0.35 | travel distance as fraction of monitor width/height |
| `stretch` | 0.28 | peak outgoing elongation along motion (+28% mid-transition) |
| `squash` | 0.18 | peak outgoing compression across motion |
| `blob_scale` | 0.42 | incoming windows start at 42% and grow to full |
| `wobble_amp` | 0.06 | damped-sine wobble on the incoming grow (0 = off) |
| `wobble_freq` | 1.5 | wobble oscillations per transition |
| `collapse` | 0.32 | outgoing windows shrink to this fraction toward the entry side |
| `stagger` | 0.25 | cascade reserve: fraction of duration the far edge lags (0 = off) |
| `droplet` | 28.0 | peak extra corner rounding in px mid-transition (0 = off) |
| `goo_strength` | 0.4 | screen-space smear peak mix 0..1 (0 = pass off, zero cost) |
| `goo_smear` | 20.0 | max smear spread along motion, logical px |
| `goo_wobble` | 6.0 | perpendicular UV wobble amplitude, logical px (0 = off) |
| `direction` | `auto` | `auto` (higher id ⇒ enters from right) \| `forward` \| `backward` |
| `vertical` | 0 | 1 = vertical slide (forward enters from bottom) |
| `out_curve` | `expo` | outgoing easing: `expo` \| `back` \| `linear` |
| `in_curve` | `back` | incoming easing: `expo` \| `back` \| `linear` |

Quick taste tests:

```bash
hyprctl keyword plugin:gooworkspaces:duration_ms 700
hyprctl keyword plugin:gooworkspaces:wobble_amp 0.10
hyprctl keyword plugin:gooworkspaces:goo_strength 0.7
hyprctl keyword plugin:gooworkspaces:stagger 0
```

## Layout

- `src/main.cpp` — hooks (`renderWindow`, `rounding`) + event wiring
  (`workspace.active`, `tick`, `render.stage`), per-monitor bookkeeping.
- `src/GooTransition.*` — transition state machine, easings, morph math,
  cascade stagger.
- `src/GooPass.*` — screen-space goo pass element + embedded GLSL
  (fullscreen smear shader, compiled at first use; failure notifies once
  and permanently disables the pass).
- `src/Config.*` — config registration + live reads.

GL objects (scratch FB, shader, VAO) are intentionally leaked on unload —
freeing them off-context SEGVs (same trade as liquid-glass-hypr); the OS
reclaims everything at process exit.
