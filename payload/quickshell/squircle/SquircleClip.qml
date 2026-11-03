import QtQuick
import QtQuick.Effects

// Children cut to the shared squircle curve, with an optional fill behind
// them — the drop-in for ClippingRectangle wherever a widget's picture has
// to reach its own rounded edge.
//
//   SquircleClip {
//       anchors.fill: parent
//       radius: w.corner
//       smoothing: Prefs.squircleF
//       color: Theme.alpha(w.ink, 0.06)
//       Image { anchors.fill: parent; ... }
//   }
//
// Same curve as SquircleRect and SquircleMask. The mask is Shape geometry
// baked into an item layer (not a bare ShaderEffect) so it survives the
// size and reveal transitions a card goes through; the content rides the
// same layer with MultiEffect's mask, the pattern the dock's launcher uses.
Item {
    id: root

    property color color: "transparent"
    property real radius: 0
    // Per-corner overrides, Rectangle convention (-1 follows radius).
    property real topLeftRadius: -1
    property real topRightRadius: -1
    property real bottomLeftRadius: -1
    property real bottomRightRadius: -1
    // Shared corner smoothing, 0..1. 0.5 = classic squircle.
    property real smoothing: 0.5

    default property alias content: contentItem.data

    SquircleRect {
        anchors.fill: parent
        radius: root.radius
        topLeftRadius: root.topLeftRadius
        topRightRadius: root.topRightRadius
        bottomLeftRadius: root.bottomLeftRadius
        bottomRightRadius: root.bottomRightRadius
        fillColor: root.color
        smoothing: root.smoothing
    }

    Item {
        id: contentItem

        anchors.fill: parent
        layer.enabled: true
        // MultiEffect does not blend the mask's alpha through: it runs it
        // through smoothstep() first. With the defaults (threshold 0, spread
        // 0) any partial pixel becomes fully opaque, i.e. a 1-bit cut that
        // throws away the squircle's antialiased edge. 0.5/1 maps alpha 0..1
        // back to itself, so the mask's own ramp survives.
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: maskItem
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }

    }

    Item {
        id: maskItem

        anchors.fill: parent
        visible: false
        layer.enabled: true
        // Shape antialiasing is multisample-based, and a layer gets no
        // multisampling unless asked for; Quickshell never enables it on the
        // window. Smooth is the layer's filtering, and defaults to nearest.
        layer.samples: 4
        layer.smooth: true

        SquircleMask {
            anchors.fill: parent
            radius: root.radius
            topLeftRadius: root.topLeftRadius
            topRightRadius: root.topRightRadius
            bottomLeftRadius: root.bottomLeftRadius
            bottomRightRadius: root.bottomRightRadius
            smoothing: root.smoothing
        }

    }

}
