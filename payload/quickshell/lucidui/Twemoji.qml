import QtQuick
import qs
import "twemoji.js" as Twemoji

// One emoji from the Twemoji set bundled under assets/twemoji.
//
// It is an image rather than a glyph because Noto Color Emoji carries a single
// 136px bitmap strike: at the launcher's small size that comes out soft, and
// the 1.35x face transform then stretches the low-res texture further. Twemoji
// ships vector SVGs, so the artwork resolves at any size, and it matches the
// flat Twitter look instead of the system emoji font.
//
// The asset is decoded at 4x so neither the reveal scale nor a HiDPI factor
// ever upsamples it. Strings the set is missing fall back to the emoji font.
Item {
    id: root

    property string emoji: ""
    property real size: 24
    property color fallbackColor: Theme.text
    readonly property string asset: Twemoji.assetName(root.emoji)

    implicitWidth: root.size
    implicitHeight: root.size

    Image {
        id: art

        anchors.fill: parent
        source: root.asset === "" ? "" : Qt.resolvedUrl("../assets/twemoji/" + root.asset + ".svg")
        sourceSize.width: Math.max(1, Math.ceil(root.size * 4))
        sourceSize.height: Math.max(1, Math.ceil(root.size * 4))
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        visible: status === Image.Ready
    }

    Text {
        anchors.centerIn: parent
        visible: !art.visible
        text: root.emoji
        color: root.fallbackColor
        font.family: "Noto Color Emoji"
        font.pixelSize: Math.round(root.size)
        renderType: Text.NativeRendering
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
