import QtQuick
import "squircle.js" as Sq

// Filled squircle rect with border — drop-in replacement for Rectangle
// wherever a visible corner should follow the shared smoothing factor.
//
//   SquircleRect {
//       anchors.fill: parent
//       radius: 18                      // uniform corner radius, px
//       topLeftRadius: 0                // per-corner override (-1 = radius)
//       fillColor: Theme.bg
//       borderWidth: 1
//       borderColor: Theme.accent
//       smoothing: Prefs.squircleF      // 0..1, default 0.5
//   }
//
// At smoothing 0 the SDF is exactly circular, i.e. visually identical to
// Rectangle. Children are NOT clipped (same as Rectangle with clip:false);
// pair with SquircleMask via OpacityMask/MultiEffect where content must be
// cut to the curve (wallpaper thumbs, app icons, panel content).
ShaderEffect {
    id: root

    property color fillColor: "white"
    property color borderColor: "transparent"
    property real borderWidth: 0
    // Which edges the border covers. A notch tab hangs off the screen edge, so
    // its top edge has no outline (0); otherwise 1.
    property real borderTop: 1
    // Px of left/right border to drop from the top, where a concave shoulder
    // flare takes the outline over. Qt.vector2d(left, right).
    property vector2d borderGap: Qt.vector2d(0, 0)
    property real radius: 0
    // Per-corner overrides, Rectangle convention (-1 follows radius).
    property real topLeftRadius: -1
    property real topRightRadius: -1
    property real bottomLeftRadius: -1
    property real bottomRightRadius: -1
    // Shared corner smoothing, 0..1. 0.5 = classic squircle.
    property real smoothing: 0.5

    readonly property real _tl: root.topLeftRadius >= 0 ? root.topLeftRadius : root.radius
    readonly property real _tr: root.topRightRadius >= 0 ? root.topRightRadius : root.radius
    readonly property real _br: root.bottomLeftRadius >= 0 ? root.bottomLeftRadius : root.radius
    readonly property real _bl: root.bottomRightRadius >= 0 ? root.bottomRightRadius : root.radius
    readonly property real exponent: Sq.exponent(root.smoothing)

    // ShaderEffect uniforms (vec4/vec2 map from these properties).
    property vector4d radii: Qt.vector4d(root._tl, root._tr, root._br, root._bl)
    property vector2d itemSize: Qt.vector2d(width, height)

    // A zero-size item draws nothing (avoids div-by-zero in the SDF).
    visible: width > 0.5 && height > 0.5

    // .qsb is build output from the .frag beside it (`qsb --qt6
    // squircle_rect.frag -o squircle_rect.frag.qsb`); Qt 6 ShaderEffect
    // only accepts .qsb URLs. resolvedUrl pins the lookup to this file's
    // directory — a bare relative URL would resolve against whichever
    // file instantiates this component.
    fragmentShader: Qt.resolvedUrl("squircle_rect.frag.qsb")
}
