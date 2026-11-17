import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs
import qs.lucidui
import qs.luciddocks
import qs.squircle

// The app-launch morph, reused for the Duolingo lesson.
//
// This is the same sequence as luciddocks/LaunchGhost.qml: the icon swells
// from the widget rect into the held tile, the m3 halo sits behind it, and
// when the page is ready an iris opens from the tile's centre. The tile is
// held from the first frame, so the page is never visible until the iris —
// exactly the placeholder-window behaviour of a normal launch.
Item {
    id: launch

    property rect fromRect: Qt.rect(0, 0, 1, 1)
    property rect toRect: Qt.rect(0, 0, 1, 1)
    property bool active: false
    property bool pageReady: false

    signal finished()

    readonly property int irisMs: Math.round(Theme.durFastSpatial * 4 / 3) + 100
    readonly property var irisCurve: [0.05, 0.7, 0.1, 1, 1, 1]
    readonly property real windowRadius: Math.max(0, HyprConfig.num("decoration.rounding", 8)
        * HyprConfig.num("decoration.rounding_power", 2) / 2)
    readonly property real windowSmoothing: Prefs.squircleF

    property real morphT: 0
    property real effectsT: 0
    property real revealRadius: 0
    property real contentOpacity: 0
    property bool revealing: false
    property bool landed: false

    readonly property real shapeX: fromRect.x + (toRect.x - fromRect.x) * morphT
    readonly property real shapeY: fromRect.y + (toRect.y - fromRect.y) * morphT
    readonly property real shapeW: Math.max(0, fromRect.width + (toRect.width - fromRect.width) * morphT)
    readonly property real shapeH: Math.max(0, fromRect.height + (toRect.height - fromRect.height) * morphT)
    readonly property real shapeRadius: Math.max(0, Math.min(shapeW, shapeH) / 2 * (1 - effectsT) + windowRadius * effectsT)
    readonly property real iconFromSize: Math.min(fromRect.width, fromRect.height) * 0.82
    readonly property real iconToSize: Math.max(Theme.dp(32), Math.min(Theme.dp(88), Math.round(Math.min(toRect.width, toRect.height) * 0.28)))
    readonly property real iconSize: iconFromSize + (iconToSize - iconFromSize) * effectsT
    readonly property real iconX: fromRect.x + fromRect.width / 2 + (toRect.x + toRect.width / 2 - (fromRect.x + fromRect.width / 2)) * morphT - iconSize / 2
    readonly property real iconY: fromRect.y + fromRect.height / 2 + (toRect.y + Math.round(toRect.height * 0.43) - (fromRect.y + fromRect.height / 2)) * morphT - iconSize / 2
    readonly property color fill: launch.mix(Theme.accentContainer, Theme.bgTile, effectsT)
    readonly property color edge: Theme.alpha(Theme.text, 0.07 * effectsT)

    readonly property real revealCx: toRect.x + toRect.width / 2
    readonly property real revealCy: toRect.y + toRect.height / 2
    readonly property real revealMax: Math.hypot(toRect.width / 2, toRect.height / 2) + 2
    readonly property real revealSoftStop: revealRadius > 1 ? (revealRadius - 1) / revealRadius : 0

    function mix(a, b, t) {
        t = Math.max(0, Math.min(1, t));
        return Qt.rgba(a.r * (1 - t) + b.r * t, a.g * (1 - t) + b.g * t, a.b * (1 - t) + b.b * t, a.a * (1 - t) + b.a * t);
    }

    function start() {
        seedFade.stop();
        morphAnim.stop();
        effectsAnim.stop();
        revealAnim.stop();
        active = true;
        GateCore.lessonRevealed = false;
        landed = false;
        revealing = false;
        revealRadius = 0;
        morphT = 0;
        effectsT = 0;
        contentOpacity = 0;
        seedFade.start();
        morphAnim.start();
        effectsAnim.start();
    }

    function reset() {
        seedFade.stop();
        morphAnim.stop();
        effectsAnim.stop();
        revealAnim.stop();
        active = false;
        landed = false;
        revealing = false;
        revealRadius = 0;
        morphT = 0;
        effectsT = 0;
        contentOpacity = 0;
    }

    function maybeReveal() {
        if (!active || !pageReady || revealing)
            return ;
        if (effectsT < 0.999)
            return ;

        GateCore.lessonRevealed = true;
        revealing = true;
        revealRadius = 0;
        revealAnim.restart();
    }

    onPageReadyChanged: maybeReveal()
    onEffectsTChanged: maybeReveal()

    visible: active

    // Swallow clicks while the tile covers the page. The window controls are
    // siblings above this item, so they stay usable.
    MouseArea {
        anchors.fill: parent
        enabled: launch.active
    }

    Item {
        id: content

        anchors.fill: parent
        // the remaining tile fades as the iris grows, so the handover is a
        // dissolve as well as a cut
        opacity: launch.contentOpacity * (launch.revealing ? Math.max(0, 1 - launch.revealRadius / Math.max(1, launch.revealMax)) : 1)
        layer.enabled: launch.revealing
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: revealMask
        }

        // the held tile: exactly the surface a normal launch leaves behind
        LaunchGhostSurface {
            x: launch.toRect.x
            y: launch.toRect.y
            width: launch.toRect.width
            height: launch.toRect.height
            iconSource: GateCore.assetsPath + "/duolingo-owl.png"
            appName: "Duolingo"
            radius: launch.windowRadius
            opacity: launch.landed ? 1 : 0
            indicator: launch.landed
            revealProgress: launch.revealing
                ? Math.min(1, (launch.revealRadius / Math.max(1, launch.revealMax)) / 0.6)
                : 0
        }

        // the overlay half: the widget icon growing into the tile
        SquircleRect {
            z: 1
            x: launch.shapeX
            y: launch.shapeY
            width: launch.shapeW
            height: launch.shapeH
            radius: launch.shapeRadius
            smoothing: launch.windowSmoothing * launch.effectsT
            fillColor: launch.fill
            borderColor: launch.edge
            borderWidth: 1
            opacity: launch.landed ? 0 : 1
        }

        Image {
            z: 2
            x: launch.iconX
            y: launch.iconY
            width: Math.max(1, launch.iconSize)
            height: width
            source: GateCore.assetsPath + "/duolingo-owl.png"
            fillMode: Image.PreserveAspectFit
            asynchronous: false
            cache: true
            smooth: true
            mipmap: true
            opacity: launch.landed ? 0 : 1
        }

    }

    // White outside the iris, transparent inside. MultiEffect reads the alpha,
    // so the tile survives everywhere except the opening circle.
    Item {
        id: revealMask

        anchors.fill: parent
        visible: false
        layer.enabled: launch.active

        Shape {
            anchors.fill: parent

            ShapePath {
                fillGradient: RadialGradient {
                    centerX: launch.revealCx
                    centerY: launch.revealCy
                    centerRadius: Math.max(1, launch.revealRadius)
                    focalX: launch.revealCx
                    focalY: launch.revealCy
                    spread: ShapeGradient.PadSpread

                    GradientStop {
                        position: 0
                        color: "transparent"
                    }

                    GradientStop {
                        position: launch.revealSoftStop
                        color: "transparent"
                    }

                    GradientStop {
                        position: 1
                        color: "white"
                    }
                }

                startX: 0
                startY: 0

                PathLine { x: launch.width; y: 0 }
                PathLine { x: launch.width; y: launch.height }
                PathLine { x: 0; y: launch.height }
                PathLine { x: 0; y: 0 }
            }

        }

    }

    NumberAnimation {
        id: seedFade

        target: launch
        property: "contentOpacity"
        from: 0
        to: 1
        duration: Theme.ms(90)
        easing.type: Easing.Bezier
        easing.bezierCurve: Theme.curveEffects
    }

    NumberAnimation {
        id: morphAnim

        target: launch
        property: "morphT"
        from: 0
        to: 1
        duration: Theme.durDefaultSpatial
        easing.type: Easing.Bezier
        easing.bezierCurve: Theme.curveDefaultSpatial

        onFinished: {
            launch.morphT = 1;
            launch.effectsT = 1;
            launch.landed = true;
        }
    }

    NumberAnimation {
        id: effectsAnim

        target: launch
        property: "effectsT"
        from: 0
        to: 1
        duration: Theme.durDefaultSpatial
        easing.type: Easing.Bezier
        easing.bezierCurve: Theme.curveEffects
    }

    NumberAnimation {
        id: revealAnim

        target: launch
        property: "revealRadius"
        from: 0
        to: launch.revealMax
        duration: launch.irisMs
        easing.type: Easing.Bezier
        easing.bezierCurve: launch.irisCurve

        onFinished: {
            launch.active = false;
            launch.revealing = false;
            launch.revealRadius = 0;
            launch.contentOpacity = 0;
            launch.finished();
        }
    }

}
