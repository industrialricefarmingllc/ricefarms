import QtQuick
import Quickshell
import Quickshell.Widgets
import qs
import qs.lucidui

// one wallpaper in Settings -> Theme: a picture, or a video's first frame
Rectangle {
    id: tile

    required property string path
    required property string name
    // the small copy wallpaper-thumbs.sh cut, "" until it exists
    required property string thumb
    // skwd's animated WebP for a video or Wallpaper Engine scene
    property string preview: ""
    property string kind: ""
    property bool live: false
    property bool selected: false

    readonly property bool liveItem: tile.live || tile.kind === "video" || tile.kind === "we"

    signal picked()

    width: Theme.dp(150)
    height: Theme.dp(88)
    radius: Theme.radiusSm
    color: Theme.bgSunken

    ClippingRectangle {
        anchors.fill: parent
        radius: tile.radius
        color: "transparent"

        // a picture falls back to its original; a video has nothing to show until its frame is cut
        Image {
            id: image

            anchors.fill: parent
            source: tile.thumb !== "" ? "file://" + tile.thumb : (tile.liveItem ? "" : "file://" + tile.path)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            sourceSize.width: Theme.dp(300)
            sourceSize.height: Theme.dp(176)
            visible: image.status === Image.Ready
        }

        // the same short preview the picker plays, while the pointer rests here
        AnimatedImage {
            anchors.fill: parent
            source: tile.preview !== "" ? "file://" + tile.preview : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            playing: visible
            visible: tile.preview !== "" && tileArea.containsMouse
            sourceSize.width: Theme.dp(300)
            sourceSize.height: Theme.dp(176)
        }

    }

    Rectangle {
        width: Theme.dp(24)
        height: Theme.dp(24)
        radius: Theme.dp(12)
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Theme.dp(6)
        color: Theme.alpha(Theme.cShadow, 0.65)
        visible: tile.liveItem

        Icon {
            anchors.centerIn: parent
            name: "movie"
            size: Theme.dp(14)
            color: "white"
        }

    }

    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.width: tile.selected ? 3 : (tileArea.containsMouse ? 2 : 0)
        border.color: tile.selected ? Theme.accent : Theme.alpha(Theme.text, 0.5)

        Behavior on border.width {
            NumberAnimation {
                duration: Theme.durQuick
            }

        }

    }

    MouseArea {
        id: tileArea

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: tile.picked()
    }

    Rectangle {
        id: delBtn

        readonly property bool active: tileArea.containsMouse || delArea.containsMouse

        width: Theme.dp(28)
        height: Theme.dp(28)
        radius: Theme.dp(14)
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.dp(6)
        color: delArea.containsMouse ? Theme.error : Theme.alpha(Theme.cShadow, 0.65)
        opacity: delBtn.active && !SkwdWall.isVirtual(tile.path) ? 1 : 0
        visible: opacity > 0.01
        scale: delBtn.active ? 1 : 0.7

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.durQuick
            }

        }

        Behavior on scale {
            NumberAnimation {
                duration: Theme.durShort
                easing.type: Theme.easeEmphasized
                easing.overshoot: Theme.emphasizedOvershoot
            }

        }

        Behavior on color {
            ColorAnimation {
                duration: Theme.durQuick
            }

        }

        Icon {
            anchors.centerIn: parent
            name: "delete"
            size: Theme.dp(18)
            fill: delArea.containsMouse ? 1 : 0
            color: delArea.containsMouse ? Theme.fgError : "white"
        }

        MouseArea {
            id: delArea

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (SkwdWall.isVirtual(tile.path))
                    return ;

                Prefs.askConfirm(tile.live ? "Delete this live wallpaper?" : "Delete this wallpaper?", "\"" + tile.name + "\" is moved to the trash, so it can be restored from there if you change your mind.", "Delete", "wallpaper:" + tile.path);
            }
        }

    }

}
