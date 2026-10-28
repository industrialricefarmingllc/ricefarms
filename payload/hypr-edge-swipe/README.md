# hypr-touch-gestures

Touch gestures for Hyprland — workspace edge swipes, live pinch resizing and
window dragging. Works even when the shell keeps fullscreen layer surfaces
on the top/overlay layers.

## Why not the built-in gestures?

The built-in touch swipe only begins when the touch lands on a surface at
or below the bottom layer (the `m_foundLSToFocus->m_layer <= 1` check in
Touch.cpp). A rice with permanent fullscreen top/overlay surfaces
(quickshell panels, decorative overlays) never satisfies that, so the
built-in gesture cannot trigger at all on such a setup. This plugin listens
to the `input.touch` event bus directly instead.

The built-in path is also *motion*-based: it targets `m-1` for a leftward
motion, even when that motion started at the right bezel, and it needs more
than half the screen to commit. This plugin is *edge*-based (right bezel ->
right workspace, left bezel -> left workspace) and follows the finger while
it moves. Keep `gestures:workspace_swipe_touch = false` so the two paths
never fight; `custom.lua` sets it.

## Gestures

### Workspace edge swipe

- Left edge inward -> workspace to the left
- Right edge inward -> workspace to the right
- Top edge inward -> workspace above
- Bottom edge inward -> workspace below
- Left edge outward -> workspace to the right
- Right edge outward -> workspace to the left
- Top edge outward -> workspace below
- Bottom edge outward -> workspace above

The outward listener is the same gesture in reverse: start a little inside
the edge band and move toward the bezel. Leave at least `min_distance_px`
between the start point and the screen edge so there is room to commit.

There is also a reverse swipe just outside the normal edge band: start within
`reverse_zone_px` (default 120 px) of the target edge, then move toward it.
The start point is the reference; once the finger has travelled
`reverse_min_px` (default 24 px) toward that edge, it navigates the opposite
way from the same-edge inward swipe and follows the finger normally. Starts
in the middle of the screen do not navigate, so ordinary app swipes are left
alone. Set `reverse_zone_px` to 0 only if you deliberately want no start
distance limit.

The workspace **follows the finger** while the swipe is in progress: the
outgoing workspace slides out and the incoming one slides in with the drag
distance. Release past the commit threshold to switch; release earlier and
it slides back. The threshold is `min_distance_px` (20 logical px by
default), so a short flick commits. Dragging further still follows the finger
before release. `dominance` still requires the travel along the chosen
direction to be clearly stronger than the perpendicular travel, so a
diagonal scroll does not switch workspaces. Inward activates at
`swipe_activation_px` (12 px by default, so bar taps are left to the shell);
outward never activates below 6 px, so a small backswing on an inward swipe
cannot lock the wrong direction.

Directions use the same 5x3 grid as `custom.lua`'s
`gridHorizontal`/`gridVertical`:

- solo eDP-1: rows `{10..14}`, `{20..24}`, `{30..34}`
- docked: each DP monitor owns three consecutive rows of the 45-cell grid
- horizontal wraps inside the current row; vertical wraps inside the current
  monitor's three-row block
- free anchors 10/20/30 fall back to numeric neighbours

The commit uses the same directional `slide` / `slidevert` style as the grid
keybinds, so wrapped jumps continue in the press direction instead of
reversing.

Taps and small scrolls in the edge band still work. Once travel in the
chosen direction reaches the activation threshold, the plugin cancels the
client's touch stream (`wl_touch.cancel`) and takes over, so the app does not
also scroll while a workspace is sliding.

### Corner launcher

Pibble is opened and closed from the corners:

- **Top-left, diagonal inward** (down-right) -> open.
- **Top-left, diagonal outward** (up-left, toward the corner) -> close.
- **Bottom-right, diagonal up-left** -> close.

The open gesture starts within `corner_px` of the corner. While Pibble is
open, the top-left close gets a wider start area, `corner_close_px` (120 px),
so it is easy to grab from farther in. Both horizontal and vertical
components must reach `corner_min_px` and be reasonably balanced.

During the top-left/bottom-right close drag, the launcher follows the finger
immediately (no need to lift); it closes when the drag is released. Reversing
back toward the start restores it instead. A straight horizontal or vertical
swipe in a corner still goes to the normal edge listener, so workspace
navigation keeps working there.

### Pinch on a window

Both fingers must land on the same window within `pinch_timeout_ms`.

- The window **resizes live** while the fingers move, giving feedback about
  whether the gesture will grow or shrink it. On pinch-out the preview only
  grows an axis that maximizing will actually grow; a dimension that will
  shrink at commit stays at its original size until release.
- Pinch **out** on a normal window: maximize it (the `SUPER+Z` / tmux `z`
  action, fullscreen mode 1). The window is floated for the preview and put
  back into the tiling tree before maximizing, so unmaximizing returns to a
  tile.
- Pinch **out** again while maximized: true fullscreen (the `SUPER+F` /
  tmux `f` action, fullscreen mode 0).
- Pinch **in** from fullscreen: back to maximized.
- Pinch **in** from maximized: back to normal tiling.
- Pinch **in** on a normal window: it stays floating at the smaller size the
  fingers pulled it down to.
- Releasing before the threshold restores the original geometry/tiling.

Fullscreen and maximized windows keep their discrete step only; they are not
floated for a preview, so pinching near a fullscreen game cannot yank it out
of fullscreen until the gesture actually commits.

The gesture commits on release once the finger distance has grown by
`pinch_ratio` (+25% by default) or shrunk by its inverse (-20%). For
floating/maximized/fullscreen windows the client's touch stream is cancelled
when the step commits; for the live preview it is cancelled as soon as the
preview starts.

### Drag a window

A single-finger drag is left entirely to the app, so text selection,
scrolling, sliders and other touch interactions keep working. To move a
window, **double-tap it** and keep the second touch down. Once that second
touch travels `drag_threshold_px`, the window follows the finger. A
double-tap that does not move is still a normal double-click. The two taps
must land on the same window within `drag_double_tap_ms` (measured from the
first tap-down) and `drag_double_tap_px`; each tap itself must be under
300 ms.

A vertical or mostly-vertical one-finger swipe (scrolling a page) also
pauses drag arming for `drag_cooldown_ms` (300 ms). A quick tap followed by
another swipe therefore keeps scrolling instead of turning into a window
drag. Diagonal swipes count as scrolls when their vertical component is at
least half their horizontal component.

A tiled window is floated at its exact on-screen position and size before
the drag starts, so the gesture does not make it jump or grow. A maximized
window is returned to its tile first.

On release the window is **put back into the tiling tree at the drop point**
(the other windows reflow). This also applies to a window that was already
floating before the drag. Fullscreen windows are deliberately *not*
draggable, so a stray drag cannot pull a game out of fullscreen.

The first `drag_threshold_px` of the second touch still goes to the app;
after that the client touch is cancelled and the window follows the finger.
Touches that start on a shell bar, dock or other input-accepting layer
surface are left alone.

## Config

Plugin keys:

```
plugin:touch:enabled               = 1      # master switch
plugin:touch:zone_px               = 56     # edge band width (all four edges, logical px)
plugin:touch:zone_top_px           = 0      # don't start edge swipes within N px of the top
plugin:touch:swipe_activation_px   = 12     # travel before the workspace follows
plugin:touch:swipe_distance_px     = 900    # finger travel for a full screen of workspace
plugin:touch:min_distance_px       = 20     # inward travel needed to commit
plugin:touch:dominance             = 1.2    # required inward / perpendicular travel ratio
plugin:touch:invert                = 0      # swap sides (left -> next, right -> previous)
plugin:touch:vertical_edges        = 1      # enable top/bottom edge swipes
plugin:touch:reverse_enabled       = 1      # swipe from the interior toward an edge
plugin:touch:reverse_zone_px       = 120    # max start distance from that edge (0 = any)
plugin:touch:reverse_min_px        = 24     # movement toward the edge before it takes over
plugin:touch:corner_enabled        = 1      # corner swipe opens/closes Pibble
plugin:touch:corner_px             = 48     # open-gesture corner square (logical px)
plugin:touch:corner_close_px       = 120    # wider top-left start area while Pibble is open
plugin:touch:corner_min_px         = 24     # min dx and dy before it fires

plugin:touch:pinch_enabled         = 1
plugin:touch:pinch_live            = 1      # resize live (0 = discrete steps only)
plugin:touch:pinch_ratio           = 1.25   # +25% to expand, -20% to contract
plugin:touch:pinch_min_distance_px = 40     # minimum finger separation
plugin:touch:pinch_timeout_ms      = 400    # max delay between the two fingers

plugin:touch:drag_enabled          = 1
plugin:touch:drag_threshold_px     = 24     # travel before the drag takes over
plugin:touch:drag_double_tap_ms    = 150    # first tap-down to second tap-down
plugin:touch:drag_double_tap_px    = 40     # max distance between the two taps
plugin:touch:drag_cooldown_ms      = 300    # pause drag arming after a vertical scroll
```

From the Lua config:

```lua
hl.config({ plugin = { touch = { zone_px = 70, min_distance_px = 30 } } })
```

Note: on Hyprland 0.56.2's Lua config path, runtime `hl.config()` overrides
for plugin namespaces are not reliably seen by the plugin's value bindings
(`hyprctl getoption` shows the new value, but the plugin keeps reading the
registered default). The compiled defaults are what is used in practice; to
change them permanently, edit `src/Config.cpp` and rebuild. This applies to
the swipe distance/commit distance too; the native `gestures:workspace_swipe_*`
settings are not used by this plugin (the native touch gesture is disabled).

## Build & load

```sh
make
hyprctl plugin load "$PWD/hypr-touch-gestures.so"
```

`custom.lua` loads it on `hyprland.start` with a `hyprctl plugin list` guard
(so a reload does not load it twice). This plugin has no GL state, so unlike
the rice's render plugins it is safe to unload/reload while iterating:

```sh
hyprctl plugin unload "$PWD/hypr-touch-gestures.so"
hyprctl plugin load "$PWD/hypr-touch-gestures.so"
```

`PLUGIN_EXIT` cancels an in-flight swipe/preview and ends an active drag
before the code is unloaded, so reloading during a gesture does not leave a
workspace offset or a half-floated window behind.

## Debugging

`~/.cache/hypr-edge-swipe/debug.log` records edge candidates, previews,
commits/cancels (workspace, direction, travel), pinch candidates/previews
and the chosen action, and drag begin/end. Size-capped.
