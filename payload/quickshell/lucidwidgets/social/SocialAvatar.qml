import QtQuick
import qs
import qs.lucidui
import "../../squircle"

// A round author picture with a tonal initial underneath.  Avatars may crop
// (they are decoration); post media never does.
Item {
    id: avatar

    required property var author
    property real size: Theme.dp(36)
    property string source: ""

    readonly property string name: String((avatar.author || {}).display_name || (avatar.author || {}).handle || "?").trim()
    readonly property string pictureSource: String((avatar.author || {}).avatar_url || "")
    readonly property bool hackernews: avatar.source === "hackernews" && pictureSource === ""

    implicitWidth: avatar.size
    implicitHeight: avatar.size

    SquircleClip {
        anchors.fill: parent
        radius: avatar.size / 2
        smoothing: 0.5
        color: avatar.hackernews ? Theme.primary : Theme.surfaceHighest

        LText {
            anchors.centerIn: parent
            visible: avatar.hackernews || picture.status !== Image.Ready
            role: "titleSmall"
            text: avatar.name.slice(0, 1).toUpperCase() || "?"
            color: avatar.hackernews ? Theme.fgPrimary : Theme.subtext
        }

        Image {
            id: picture

            anchors.fill: parent
            source: avatar.hackernews ? "" : avatar.pictureSource
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: Math.max(1, Math.round(avatar.size * 3))
            sourceSize.height: Math.max(1, Math.round(avatar.size * 3))
            smooth: true
            visible: !avatar.hackernews && status === Image.Ready
        }

    }

}
