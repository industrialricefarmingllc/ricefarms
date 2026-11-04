import QtQuick
import qs
import qs.lucidui

// A like is a small, physical thing: the heart fills and gives a single
// overshoot, then settles.  The count is part of the same tap target.
Item {
    id: like

    property bool liked: false
    property int count: -1
    property bool enabled: true
    property color ink: Theme.subtext

    signal clicked()

    implicitHeight: Theme.dp(30)
    implicitWidth: row.implicitWidth + Theme.dp(12)
    opacity: like.enabled ? 1 : 0.45

    function pop() {
        popAnim.restart();
    }

    Row {
        id: row

        anchors.centerIn: parent
        spacing: Theme.dp(5)

        Icon {
            id: heart

            anchors.verticalCenter: parent.verticalCenter
            name: "favorite"
            size: Theme.dp(18)
            fill: like.liked ? 1 : 0
            color: like.liked ? Theme.primary : like.ink
            scale: 1

            Behavior on color {
                ColorAnimation {
                    duration: Theme.durDefaultEffects
                }

            }

        }

        LText {
            anchors.verticalCenter: parent.verticalCenter
            visible: like.count >= 0
            role: "labelMedium"
            text: like.count >= 0 ? like.count : ""
            color: like.liked ? Theme.primary : like.ink
        }

    }

    SequentialAnimation {
        id: popAnim

        NumberAnimation {
            target: heart
            property: "scale"
            to: 1.32
            duration: Theme.durFastSpatial
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveFastSpatial
        }

        NumberAnimation {
            target: heart
            property: "scale"
            to: 1
            duration: Theme.durDefaultSpatial
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveDefaultSpatial
        }

    }

    StateLayer {
        radius: Theme.pill(height)
        tint: like.liked ? Theme.primary : like.ink
        disabled: !like.enabled
        onClicked: like.clicked()
    }

    onLikedChanged: {
        if (like.liked)
            like.pop();

    }

}
