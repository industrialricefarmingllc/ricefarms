import QtQuick
import QtQuick.Effects
import qs
import "../squircle"

// One continuous background for a notch-mode side group.
//
// With liquid glass on, the compositor plugin draws the left/right groups as a
// single shape (see shell.qml's glassGroupFor). With it off the members used to
// paint a notch each, so the same silhouette is drawn here and the members'
// own bodies step aside (BarPill.groupBackground).
Item {
    id: root

    // {x, w, h, r, first, last} from shell.qml's notchGroupBounds, or null
    property var bounds: null
    property bool shown: true
    property real hiddenOffset: 0
    // "left" rounds the group's inner-bottom corner on the right, "right" on
    // the left; the outer corner sits on the screen edge.
    property string side: "left"
    // px of side border to drop at the top, where the group's shoulder flare
    // takes the outline over (see shell.qml's notch flare repeater)
    property real borderLeftGap: 0
    property real borderRightGap: 0
    // external liquid glass: the compositor draws the body inside this exact
    // shape, so this item becomes a transparent fill carrying only the window
    // hairline (and no QML shadow)
    property bool borderOnly: false

    readonly property real cornerRadius: root.bounds ? root.bounds.r : 0

    // The shadow needs a MultiEffect layer, and a layered item at a fractional
    // output scale (1.333 on DP-1 here) samples its source through the
    // transparent padding around it: the body's outermost row came out ~30%
    // transparent. On a notch that row is the one against the screen edge, so
    // a hairline of wallpaper showed above the tab — and because the shoulder
    // flares are drawn outside the layer, the see-through row stopped where it
    // met them, reading as a break between the inverted corner and the tab.
    //
    // Carry the same body two pixels past the top edge (the shape is square
    // there: only its bottom-inner corner is rounded) so the blended row falls
    // off-screen. The silhouette on screen is unchanged; the fill now reaches
    // y=0 fully opaque.
    readonly property real edgeOverhang: 2

    visible: root.shown && root.bounds !== null
    x: root.bounds ? root.bounds.x : 0
    y: root.hiddenOffset - root.edgeOverhang
    width: root.bounds ? Math.max(1, root.bounds.w) : 0
    height: root.bounds ? root.bounds.h + root.edgeOverhang : 0
    z: -2

    layer.enabled: root.visible && !root.borderOnly
    layer.samples: 4
    layer.effect: MultiEffect {
        shadowEnabled: true
        shadowBlur: Theme.hyprShadowBlur
        blurMax: Theme.hyprShadowBlurMax
        shadowColor: Theme.hyprShadow
        shadowHorizontalOffset: Theme.hyprShadowOffsetX
        shadowVerticalOffset: Theme.hyprShadowOffsetY
        shadowScale: Theme.hyprShadowScale
        autoPaddingEnabled: true
    }

    SquircleRect {
        anchors.fill: parent
        fillColor: root.borderOnly ? "transparent" : Theme.bg
        smoothing: Prefs.squircleF
        // the hairline a window that is not focused wears, so the group reads
        // as the same kind of surface as an app window at rest
        borderColor: WindowBorder.colour
        borderWidth: WindowBorder.size
        // the tab grows out of the screen edge: no top edge to outline
        borderTop: 0
        // the overhang above the screen adds to the shoulder's drop, so the
        // side hairline still resumes where the flare's arc ends
        borderGap: Qt.vector2d(root.borderLeftGap + root.edgeOverhang, root.borderRightGap + root.edgeOverhang)
        // SquircleRect maps its bottom pair across (its _br reads
        // bottomLeftRadius), so set the inward corner through the opposite
        // property to land it on the right side.
        bottomLeftRadius: root.side === "left" ? root.cornerRadius : -1
        bottomRightRadius: root.side === "left" ? -1 : root.cornerRadius
    }

}
