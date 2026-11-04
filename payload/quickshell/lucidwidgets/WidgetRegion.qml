import Quickshell
import qs

Region {
    id: reg

    property var frame: null
    property var panel: null
    property bool blur: false
    // "card" is the widget itself, "menu" the options panel, which lives in a
    // window of its own and so reports its own geometry
    property string part: "card"
    // While the desktop's selection box is out, the cards must not take the
    // pointer: the box is dragged on the icon board underneath, and a card it
    // crosses would otherwise become the pointer target and cancel the drag.
    // Blur regions only shape the compositor's frost, so they stay untouched.
    readonly property bool marqueePassthrough: !reg.blur && Widgets.marquee !== null

    // While the widget layer's mask is already the whole screen (a card is in
    // hand, the panel is open) or a desktop box owns the pointer, these
    // per-card regions cannot change the result. Same for the card blur
    // regions when the compositor draws the glass instead. Freezing them stops
    // ~40 Region trees (and their x/y/radius bindings) from re-evaluating on
    // every frame of a drag — the mask and blur result stay identical.
    readonly property bool frozen: !reg.isMenu && ((reg.blur && Prefs.liquidGlassEnabled)
        || (!reg.blur && reg.frame !== null && reg.frame.board !== null
            && (reg.frame.board.grabbing || reg.frame.board.panelUp || Widgets.marquee !== null)))

    readonly property bool isMenu: reg.part === "menu"
    // a bare variant draws straight onto the wallpaper, so nothing frosts behind it
    readonly property bool bareCard: !reg.isMenu && reg.frame !== null && reg.frame.bare === true
    // the menu window is only up while the panel is, so its region tracks size,
    // not visibility: an empty region would have Hyprland blur the whole layer
    readonly property bool live: !reg.frozen && !reg.marqueePassthrough && (reg.isMenu ? (reg.panel !== null && reg.panel.width > 0.5 && reg.panel.height > 0.5) : (reg.frame !== null && !(reg.blur && reg.bareCard) && reg.frame.visible && reg.frame.width > 0.5))
    // the compositor's blur mask needs a horizontal hair of inset or the edge crawls
    readonly property real inset: reg.blur ? 1 : 0
    readonly property real bx: !reg.live ? 0 : (reg.isMenu ? reg.panel.x : reg.frame.x + reg.frame.surfaceX)
    readonly property real by: !reg.live ? 0 : (reg.isMenu ? reg.panel.y : reg.frame.y + reg.frame.surfaceY)
    readonly property real bw: !reg.live ? 0 : (reg.isMenu ? reg.panel.width : reg.frame.surfaceWidth)
    readonly property real bh: !reg.live ? 0 : (reg.isMenu ? reg.panel.height : reg.frame.surfaceHeight)
    readonly property int rad: !reg.live ? 0 : (reg.isMenu ? (reg.panel.cornerRadius !== undefined ? reg.panel.cornerRadius : Theme.radiusLg) : reg.frame.surfaceRadius)

    function lo(v) {
        return Math.ceil(v - 0.002);
    }

    function hi(v) {
        return Math.floor(v + 0.002);
    }

    Region {
        x: reg.lo(reg.bx + reg.inset)
        y: reg.lo(reg.by + reg.inset)
        width: Math.max(0, reg.hi(reg.bx + reg.bw - reg.inset) - reg.lo(reg.bx + reg.inset))
        height: Math.max(0, reg.hi(reg.by + reg.bh - reg.inset) - reg.lo(reg.by + reg.inset))
        radius: Math.max(0, reg.rad - reg.inset)
    }

    // The resize grips sit on the visible rounded edge. At the corners half of
    // the grab square falls outside the rounded input region above, so clicks
    // aimed at the grip dot landed on the desktop instead — the resize only
    // started when the pointer happened to land on the inner half. Resizable
    // cards get the full bounding rect as an extra input region; it only
    // widens the clickable area into the transparent corner notches and never
    // changes what is drawn.
    readonly property bool gripInput: !reg.blur && !reg.isMenu && reg.live && reg.frame !== null
        && reg.frame.resizable === true && reg.frame.locked !== true

    Region {
        x: reg.lo(reg.bx)
        y: reg.lo(reg.by)
        width: reg.gripInput ? Math.max(0, reg.hi(reg.bx + reg.bw) - reg.lo(reg.bx)) : 0
        height: reg.gripInput ? Math.max(0, reg.hi(reg.by + reg.bh) - reg.lo(reg.by)) : 0
    }

    // the remove badge hangs off a selected card's corner. the mask cannot just
    // be widened around the card - that would also catch the strip below it - so
    // the badge gets a rect of its own
    readonly property bool badgeLive: !reg.blur && !reg.isMenu && !reg.frozen && reg.frame !== null && reg.frame.badgeShown === true && !reg.marqueePassthrough
    readonly property real bdx: reg.badgeLive ? reg.frame.x + reg.frame.badgeX : 0
    readonly property real bdy: reg.badgeLive ? reg.frame.y + reg.frame.badgeY : 0
    readonly property real bdw: reg.badgeLive ? reg.frame.badgeW : 0
    readonly property real bdh: reg.badgeLive ? reg.frame.badgeH : 0
    // the pin badge sits beside the remove one and needs its own mask rect too
    readonly property bool pinBadgeLive: !reg.blur && !reg.isMenu && !reg.frozen && reg.frame !== null && reg.frame.pinBadgeShown === true && !reg.marqueePassthrough
    readonly property real pdx: reg.pinBadgeLive ? reg.frame.x + reg.frame.pinBadgeX : 0
    readonly property real pdy: reg.pinBadgeLive ? reg.frame.y + reg.frame.pinBadgeY : 0
    readonly property real pdw: reg.pinBadgeLive ? reg.frame.pinBadgeW : 0
    readonly property real pdh: reg.pinBadgeLive ? reg.frame.pinBadgeH : 0

    Region {
        x: reg.lo(reg.bdx)
        y: reg.lo(reg.bdy)
        width: reg.badgeLive ? Math.max(0, reg.hi(reg.bdx + reg.bdw) - reg.lo(reg.bdx)) : 0
        height: reg.badgeLive ? Math.max(0, reg.hi(reg.bdy + reg.bdh) - reg.lo(reg.bdy)) : 0
        radius: reg.badgeLive ? Math.round(reg.bdw / 2) : 0
    }

    Region {
        x: reg.lo(reg.pdx)
        y: reg.lo(reg.pdy)
        width: reg.pinBadgeLive ? Math.max(0, reg.hi(reg.pdx + reg.pdw) - reg.lo(reg.pdx)) : 0
        height: reg.pinBadgeLive ? Math.max(0, reg.hi(reg.pdy + reg.pdh) - reg.lo(reg.pdy)) : 0
        radius: reg.pinBadgeLive ? Math.round(reg.pdw / 2) : 0
    }

    // the blur mask is hard edged, so the rounded rect above leaves notches at the corners
    Region {
        x: reg.lo(reg.bx + reg.rad)
        y: reg.lo(reg.by)
        width: reg.blur ? Math.max(0, reg.hi(reg.bx + reg.bw - reg.rad) - reg.lo(reg.bx + reg.rad)) : 0
        height: Math.max(0, reg.hi(reg.by + reg.bh) - reg.lo(reg.by))
    }

    Region {
        x: reg.lo(reg.bx)
        y: reg.lo(reg.by + reg.rad)
        width: reg.blur ? Math.max(0, reg.hi(reg.bx + reg.bw) - reg.lo(reg.bx)) : 0
        height: Math.max(0, reg.hi(reg.by + reg.bh - reg.rad) - reg.lo(reg.by + reg.rad))
    }

}
