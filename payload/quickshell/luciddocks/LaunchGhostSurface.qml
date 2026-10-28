import QtQuick
import qs
import qs.lucidui
import "../squircle"

// The settled half of a launch: the tile the app is about to fill, on the m3
// surface ladder, carrying the app's icon and the expressive loading indicator.
// The overlay's landed state is laid out from the same functions, so the
// crossfade between the growing shape and this window is invisible.
Item {
    id: root

    property string iconSource: ""
    property string appName: ""
    // logical px, matching decoration:rounding unless the ghost says otherwise
    property real radius: 8
    property bool indicator: false

    // one icon size for both this surface and the overlay, so they land on the
    // same pixel whatever the tile's shape
    function edgeFor(w, h) {
        return Math.max(Theme.dp(32), Math.min(Theme.dp(88), Math.round(Math.min(w, h) * 0.28)));
    }
    function centerYFor(h) {
        return Math.round(h * 0.43);
    }
    readonly property real iconEdge: root.edgeFor(root.width, root.height)
    readonly property real iconCenterY: root.centerYFor(root.height)
    readonly property color fill: Theme.bgTile
    readonly property color line: Theme.alpha(Theme.text, 0.07)

    SquircleRect {
        anchors.fill: parent
        radius: root.radius
        fillColor: root.fill
        borderColor: root.line
        borderWidth: 1
        smoothing: Prefs.squircleF
    }

    Image {
        id: icon

        x: Math.round((root.width - root.iconEdge) / 2)
        y: Math.round(root.iconCenterY - root.iconEdge / 2)
        width: root.iconEdge
        height: root.iconEdge
        source: root.iconSource
        fillMode: Image.PreserveAspectFit
        asynchronous: false
        cache: true
        smooth: true
        mipmap: true
        visible: root.iconSource !== "" && status === Image.Ready
    }

    // an app with no resolvable icon still gets a mark: its initial, in the
    // same place the icon would sit
    Text {
        x: icon.x
        y: icon.y
        width: icon.width
        height: icon.height
        visible: root.iconSource === "" || icon.status === Image.Error
        text: root.appName !== "" ? String(root.appName).charAt(0).toUpperCase() : "?"
        color: Theme.accent
        font.family: Theme.fontFamily
        font.pixelSize: Math.max(12, Math.round(root.iconEdge * 0.5))
        font.weight: Font.DemiBold
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    LoadingIndicator {
        id: loader

        width: Math.max(Theme.dp(24), Math.min(Theme.dp(44), Math.round(Math.min(root.width, root.height) * 0.12)))
        height: width
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(root.iconCenterY + root.iconEdge / 2 + Theme.dp(16))
        running: root.indicator
        contained: false
        color: Theme.accent
        visible: root.indicator
    }
}
