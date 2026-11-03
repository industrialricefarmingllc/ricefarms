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

    readonly property bool isMenu: reg.part === "menu"
    // a bare variant draws straight onto the wallpaper, so nothing frosts behind it
    readonly property bool bareCard: !reg.isMenu && reg.frame !== null && reg.frame.bare === true
    // the menu window is only up while the panel is, so its region tracks size,
    // not visibility: an empty region would have Hyprland blur the whole layer
    readonly property bool live: reg.isMenu ? (reg.panel !== null && reg.panel.width > 0.5 && reg.panel.height > 0.5) : (reg.frame !== null && !(reg.blur && reg.bareCard) && reg.frame.visible && reg.frame.width > 0.5)
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

    // the remove badge hangs off a selected card's corner. the mask cannot just
    // be widened around the card - that would also catch the strip below it - so
    // the badge gets a rect of its own
    readonly property bool badgeLive: !reg.blur && !reg.isMenu && reg.frame !== null && reg.frame.badgeShown === true
    readonly property real bdx: reg.badgeLive ? reg.frame.x + reg.frame.badgeX : 0
    readonly property real bdy: reg.badgeLive ? reg.frame.y + reg.frame.badgeY : 0
    readonly property real bdw: reg.badgeLive ? reg.frame.badgeW : 0
    readonly property real bdh: reg.badgeLive ? reg.frame.badgeH : 0
    // the pin badge sits beside the remove one and needs its own mask rect too
    readonly property bool pinBadgeLive: !reg.blur && !reg.isMenu && reg.frame !== null && reg.frame.pinBadgeShown === true
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
