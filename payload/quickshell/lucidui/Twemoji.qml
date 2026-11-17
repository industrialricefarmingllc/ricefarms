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
    // A server emoji's own PNG/GIF. This Qt build has no WebP plugin, so the
    // CDN link is asked for PNG (or GIF when animated) rather than letting the
    // source be a Twemoji SVG.
    property string imageSource: ""
    // Animated server emoji use AnimatedImage; static PNGs stay on Image.
    property bool animated: false
    // lets a closed/hidden picker stop decoding frames
    property bool playing: true
    property real size: 24
    property color fallbackColor: Theme.text
    readonly property string asset: Twemoji.assetName(root.emoji)
    readonly property bool remote: root.imageSource !== ""

    implicitWidth: root.size
    implicitHeight: root.size

    Image {
        id: art

        anchors.fill: parent
        source: root.remote && root.animated ? "" : (root.remote ? root.imageSource : (root.asset === "" ? "" : Qt.resolvedUrl("../assets/twemoji/" + root.asset + ".svg")))
        sourceSize.width: Math.max(1, Math.ceil(root.size * 4))
        sourceSize.height: Math.max(1, Math.ceil(root.size * 4))
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        // Server emoji are CDN URLs. Decoding one on the GUI thread blocks the
        // whole shell until the network answers (or gives up), which is what
        // made reopening the emoji tab after copying one hang for seconds.
        asynchronous: true
        cache: true
        visible: !(root.remote && root.animated) && status === Image.Ready
    }

    AnimatedImage {
        id: animatedArt

        anchors.fill: parent
        source: root.remote && root.animated ? root.imageSource : ""
        sourceSize.width: Math.max(32, Math.ceil(root.size * 2))
        sourceSize.height: Math.max(32, Math.ceil(root.size * 2))
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: true
        cache: true
        playing: root.playing
        visible: root.remote && root.animated && status === AnimatedImage.Ready
    }

    Text {
        anchors.centerIn: parent
        visible: !root.remote && !art.visible
        text: root.emoji
        color: root.fallbackColor
        font.family: "Noto Color Emoji"
        font.pixelSize: Math.round(root.size)
        renderType: Text.NativeRendering
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
