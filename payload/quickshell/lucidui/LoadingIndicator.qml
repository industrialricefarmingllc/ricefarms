import QtQuick
import QtQuick.Shapes
import qs
import "Shapes.js" as Shapes

// m3 expressive loading indicator: one shape morphing through the sequence
// while it turns. `contained` sets it on a primary-container disc
Item {
    id: li

    property bool running: visible
    property bool contained: false
    // 0 keeps the expressive sequence; 1 is a plain circle. Use it to hand the
    // shape over to a geometric iris without changing shape families abruptly.
    property real circleMorph: 0
    property color color: li.contained ? Theme.fgPrimaryContainer : Theme.primary
    readonly property var sequence: ["softBurst", "cookie9", "pentagon", "pill", "sunny", "cookie4", "oval"]
    // fraction of each shape's radial deviation from a circle that is kept.
    // 0.34 = 66% less amplitude than the authored shapes.
    property real amplitude: 0.34
    // one scale for every shape, so none leaves the box while it turns
    readonly property real fit: {
        var max = 0;
        for (var i = 0; i < li.sequence.length; i++) {
            var r = Shapes.radii(li.sequence[i]);
            var top = 0;
            for (var j = 0; j < r.length; j++) top = Math.max(top, r[j]);
            max = Math.max(max, 1 + (top - 1) * li.amplitude);
        }
        return 1 / Math.max(0.0001, max);
    }
    property real t: 0

    implicitWidth: Theme.dp(44)
    implicitHeight: Theme.dp(44)

    NumberAnimation on t {
        running: li.running && li.visible
        from: 0
        to: li.sequence.length
        duration: li.sequence.length * 650
        loops: Animation.Infinite
    }

    Rectangle {
        visible: li.contained
        anchors.fill: parent
        radius: width / 2
        color: Theme.primaryContainer
    }

    Shape {
        id: s

        readonly property int step: Math.floor(li.t) % li.sequence.length
        readonly property real f: li.t - Math.floor(li.t)
        // a spring-ish settle into each shape
        readonly property real e: 1 - Math.pow(1 - Math.min(1, s.f * 1.6), 3)
        readonly property real sz: li.width * (li.contained ? 0.62 : 0.84) * li.fit
        readonly property var radii: {
            var base = Shapes.mix(Shapes.radii(li.sequence[s.step]), Shapes.radii(li.sequence[(s.step + 1) % li.sequence.length]), s.e);
            var m = Math.max(0, Math.min(1, li.circleMorph));
            // damp toward a circle, then finish the journey to a plain circle
            // when the iris asks for one (circleMorph)
            var a = li.amplitude * (1 - m);
            var out = [];
            for (var i = 0; i < base.length; i++) out.push(1 + (base[i] - 1) * a);
            return out;
        }

        width: s.sz
        height: s.sz
        anchors.centerIn: parent
        rotation: li.t * 140 + s.e * 50
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: li.color
            strokeColor: "transparent"
            strokeWidth: 0

            PathSvg {
                path: Shapes.svg(s.radii, s.sz, 0)
            }

        }

    }

}
