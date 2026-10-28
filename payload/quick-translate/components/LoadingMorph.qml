import QtQuick
import QtQuick.Shapes
import "Shapes.js" as Shapes

// The Material 3 Expressive loading indicator: one shape dissolving into the
// next while it turns. Small enough for a chat bubble, expressive enough that
// waiting still looks like the rest of the shell.
Item {
    id: root

    property bool running: true
    property color color: Theme.accent
    property real size: Theme.dp(30)
    readonly property var sequence: ["softBurst", "cookie9", "pentagon", "pill", "sunny", "cookie4", "oval"]
    readonly property real fit: 1 / Math.max.apply(null, root.sequence.map((n) => Math.max.apply(null, Shapes.radii(n))))
    property real t: 0

    implicitWidth: root.size
    implicitHeight: root.size
    width: root.size
    height: root.size

    NumberAnimation on t {
        running: root.running && root.visible
        from: 0
        to: root.sequence.length
        duration: root.sequence.length * Theme.ms(650)
        loops: Animation.Infinite
    }

    Shape {
        id: shape

        readonly property int step: Math.floor(root.t) % root.sequence.length
        readonly property real f: root.t - Math.floor(root.t)
        // a small spring into every shape, so the morphs read as one gesture
        readonly property real e: 1 - Math.pow(1 - Math.min(1, shape.f * 1.6), 3)
        readonly property real side: root.width * 0.82 * root.fit

        width: shape.side
        height: shape.side
        anchors.centerIn: parent
        rotation: root.t * 140 + shape.e * 50
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: root.color
            strokeColor: "transparent"
            strokeWidth: 0

            PathSvg {
                path: Shapes.svg(Shapes.mix(Shapes.radii(root.sequence[shape.step]), Shapes.radii(root.sequence[(shape.step + 1) % root.sequence.length]), shape.e), shape.side, 0)
            }

        }

    }

}
