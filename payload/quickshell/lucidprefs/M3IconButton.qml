import QtQuick
import qs
import qs.lucidui

// m3 expressive icon button: round at rest, morphs square-ish under press
Item {
    id: btn

    property string variant: "standard" // "standard" | "tonal" | "filled" | "outlined"
    property int size: Theme.dp(40)
    property int iconSize: Math.round(btn.size * 0.55)
    // a material symbol name
    property string iconPath: ""
    property bool enabled: true
    property bool destructive: false
    property string accessibleName: ""
    property string accessibleDescription: ""
    readonly property color baseColor: {
        if (btn.variant === "filled")
            return btn.destructive ? Theme.error : Theme.accent;

        if (btn.variant === "tonal")
            return btn.destructive ? Theme.errorContainer : Theme.secondaryContainer;

        return "transparent";
    }
    readonly property color fgColor: {
        if (btn.variant === "filled")
            return btn.destructive ? Theme.fgError : Theme.fgAccent;

        if (btn.variant === "tonal")
            return btn.destructive ? Theme.fgErrorContainer : Theme.fgSecondaryContainer;

        return btn.destructive ? Theme.error : (area.containsMouse ? Theme.text : Theme.subtext);
    }

    signal clicked()

    function activate() {
        if (btn.enabled)
            btn.clicked();
    }

    activeFocusOnTab: btn.enabled
    Accessible.role: Accessible.Button
    Accessible.name: btn.accessibleName !== "" ? btn.accessibleName : A11y.iconName(btn.iconPath, "")
    Accessible.description: btn.accessibleDescription
    Accessible.focusable: btn.enabled
    Accessible.focused: btn.activeFocus
    Accessible.pressed: area.pressed
    Accessible.onPressAction: btn.activate()
    Keys.onSpacePressed: btn.activate()
    Keys.onReturnPressed: btn.activate()
    Keys.onEnterPressed: btn.activate()

    implicitWidth: btn.size
    implicitHeight: btn.size
    opacity: btn.enabled ? 1 : 0.38
    readonly property bool jellyWobbling: squish.wobbling
    transform: Jelly {
        id: squish

        target: btn
        frequency: 6.5
    }

    Rectangle {
        id: container

        anchors.fill: parent
        // shape morph: full -> medium while held
        radius: area.pressed ? Theme.shapeMd : Theme.pill(btn.size)
        color: btn.baseColor
        border.width: btn.variant === "outlined" ? 1 : 0
        border.color: Theme.outlineStrong

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: btn.fgColor
            opacity: !btn.enabled ? 0 : (area.pressed ? Theme.statePressed : (area.containsMouse ? Theme.stateHover : 0))

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.durQuick
                }

            }

        }

        Behavior on radius {
            NumberAnimation {
                duration: Theme.durFastSpatial
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveDefaultSpatial
            }

        }

        Behavior on color {
            ColorAnimation {
                duration: Theme.durShort
            }

        }

    }

    Icon {
        anchors.centerIn: parent
        name: btn.iconPath
        size: Math.round(btn.iconSize * 1.08)
        color: btn.fgColor
    }

    MouseArea {
        id: area

        anchors.fill: parent
        hoverEnabled: true
        enabled: btn.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            btn.forceActiveFocus();
            btn.activate();
        }
        onPressedChanged: squish.kick(area.pressed ? -0.12 : 0.09)
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -Theme.dp(3)
        radius: Theme.pill(height + Theme.dp(6))
        color: "transparent"
        border.width: btn.activeFocus && btn.enabled ? Theme.dp(2) : 0
        border.color: Theme.accent
        visible: border.width > 0 && Prefs.a11yFocusRing
        z: 10
    }

    Behavior on opacity {
        NumberAnimation {
            duration: Theme.durShort
        }

    }

}
