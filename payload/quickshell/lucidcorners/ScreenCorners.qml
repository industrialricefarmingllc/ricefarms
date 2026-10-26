import QtQuick
import Quickshell
import Quickshell.Wayland
import qs
import "../squircle"

// Fake rounded screen corners: one fullscreen click-through overlay per
// monitor, drawing a black inverted squircle in each screen corner.
// The overlay sits on the Overlay layer so it masks windows (even
// fullscreen) exactly like a physical rounded bezel would.
Scope {
    id: root

    // Logical px — uniform real-world size on every monitor, because the
    // Hyprland scales (1.6 center vs 2.4 sides) are proportional to panel
    // DPI. Fixed *physical* px would look smaller on the denser sides.
    // Radius == size, so the arc runs edge to edge.
    // Tweak here if you want subtler/chunkier rounding.
    // NOTE: shaders/reading_mode.glsl exempts these corners from the e-ink
    // pass via CORNER_FRAC = cornerSize / 1600 (all monitors are 1600
    // logical px wide) — keep the two in sync.
    // Logical px — identical radius to Hyprland windows (Theme.windowRadius,
    // currently 16) on the shared squircle exponent (Prefs.squircleF ->
    // n = 2 + 4f). Keep in sync with shaders/reading_mode.glsl CORNER_FRAC,
    // which is cornerSize / 1600.
    property int cornerSize: Theme.windowRadius
    property color cornerColor: "black"

    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            required property var modelData
            screen: modelData
            objectName: "screenCorners"

            color: "transparent"
            // -1: reserve nothing AND ignore other layers' reservations
            // (e.g. the bar's), so the overlay truly spans the full output.
            exclusiveZone: -1
            // NOT "quickshell": this surface is always mapped, fullscreen
            // and transparent, and the liquid-glass-hypr plugin gates on a
            // namespace substring then routes geometry by surface SIZE -
            // any 1600x900 glass file (e.g. the launcher's reveal circle)
            // would also draw here, one level above its owner, as a ghost
            // cover over the launcher text. Outside the pattern the plugin
            // (and the quickshell xray layerrule) skip it entirely, which
            // costs nothing: four black corner shapes need neither.
            WlrLayershell.namespace: "lucid-corners"
            mask: Region {
            }
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            // One SDF draw for all four corners (inverted squircles, i.e.
            // the box OUTSIDE the arc). At squircleF 0 the edge is exactly
            // the old circular arc of radius cornerSize.
            SquircleCorners {
                anchors.fill: parent
                cornerSize: root.cornerSize
                color: root.cornerColor
                smoothing: Prefs.squircleF
            }
        }
    }
}
