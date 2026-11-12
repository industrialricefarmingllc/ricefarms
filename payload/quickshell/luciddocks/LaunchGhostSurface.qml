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
    // 0 at the behind-icon size, 1 when the halo should cover the whole tile
    property real revealProgress: 0

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

        z: 1
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
        layer.enabled: visible
        // Mask in a supersampled layer, otherwise the mask is baked at 1x and
        // the tile's scale blurs the icon back down again.
        layer.textureSize: Qt.size(Math.ceil(width * 4), Math.ceil(height * 4))
        layer.smooth: true
        layer.mipmap: true
        layer.effect: ShaderEffect {
            property vector2d center: Qt.vector2d(0.5, 0.5)
            property real radius: 0.5
            property real aspect: 1
            fragmentShader: "LauncherMask.qsb"
        }
    }

    // an app with no resolvable icon still gets a mark: its initial, in the
    // same place the icon would sit
    Text {
        z: 1
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

    // The loading shape is a filled halo behind the icon. On the iris it grows
    // past the tile's diagonal so the circle also covers the corners, not just
    // the inscribed square.
    LoadingIndicator {
        id: halo

        readonly property real base: root.iconEdge * 1.8
        readonly property real full: Math.hypot(root.width, root.height) / (0.84 * halo.fit) * 1.02
        readonly property real p: Math.max(0, Math.min(1, root.revealProgress))

        width: base + (full - base) * halo.p
        height: width
        x: Math.round((root.width - width) / 2)
        y: Math.round(root.iconCenterY + (root.height / 2 - root.iconCenterY) * halo.p - height / 2)
        z: 0.5
        // freeze the expressive sequence while the iris turns it into a circle
        running: root.indicator && halo.p <= 0.001
        circleMorph: halo.p
        contained: false
        color: Theme.accent
        visible: root.indicator
    }
}
