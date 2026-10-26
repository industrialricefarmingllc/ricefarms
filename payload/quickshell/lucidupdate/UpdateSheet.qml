import QtQuick
import Quickshell
import Quickshell.Wayland
import qs

// the update pop-up, over everything on the shell's display. it holds the
// keyboard only while something has to be typed
PanelWindow {
    id: sheet

    readonly property bool open: Updates.sheetOpen && Updates.flow !== "" && !Lockscreen.locked

    screen: Monitors.mainScreen
    color: "transparent"
    visible: (sheet.open || card.opacity > 0.01) && Monitors.surfacesUp
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: !sheet.open ? WlrKeyboardFocus.None : (card.wantsKeys ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand)
    WlrLayershell.namespace: "lucidupdate"
    onOpenChanged: {
        if (sheet.open)
            Qt.callLater(card.focusInput);

    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.alpha(Theme.cShadow, 0.55)
        opacity: sheet.open ? 1 : 0

        // the install carries on behind a click away; nothing else is dismissed by one
        MouseArea {
            anchors.fill: parent
            onClicked: Updates.hide()
        }

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.durShort
            }

        }

    }

    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: card.dismiss()

        UpdateCard {
            id: card

            anchors.centerIn: parent
            shown: sheet.open

            // clicks on the card must not reach the dimmer
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                z: -1
            }

        }

    }

    BackgroundEffect.blurRegion: (Theme.blurAmount > 0 && sheet.open) ? cardBlurRegion : null

    Region {
        id: cardBlurRegion

        x: Math.ceil(card.x - 0.002)
        y: Math.ceil(card.y - 0.002)
        width: Math.max(0, Math.floor(card.x + card.width + 0.002) - Math.ceil(card.x - 0.002))
        height: Math.max(0, Math.floor(card.y + card.height + 0.002) - Math.ceil(card.y - 0.002))
        radius: Theme.shapeXl
    }

}
