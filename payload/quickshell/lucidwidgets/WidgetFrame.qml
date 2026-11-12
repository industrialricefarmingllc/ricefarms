import QtQuick
import qs
import qs.lucidui
import "../squircle"

Item {
    id: frame

    required property string uid
    required property string wtype
    required property string wvariant
    required property real wx
    required property real wy
    required property real bw
    required property real bh
    required property bool pinned
    required property bool everywhere
    required property real zoom
    required property int zOrder
    required property string screenName
    required property string optsJson
    required property bool closing
    required property bool born

    property Item board: null

    readonly property var opts: {
        try {
            return JSON.parse(frame.optsJson);
        } catch (e) {
            return ({});
        }
    }
    readonly property bool locked: frame.pinned || Prefs.widgetLockAll
    readonly property bool onThisScreen: frame.board !== null && (frame.screenName === "" ? frame.board.isPrimary : frame.screenName === frame.board.screenName)
    // while the pointer holds this card every output has a copy of it. each copy
    // draws the part that falls on its own board, so the card crosses the seam
    // whole instead of stopping at the edge of the screen it started on
    readonly property var carry: Widgets.dragRects[frame.uid]
    readonly property bool carried: frame.carry !== undefined && frame.carry !== null
    // A carried copy exists on every output, but only the output whose part of
    // the seam it actually covers should draw it. Otherwise a drag wakes the
    // spatial foreground and glass publisher on every other monitor, which is
    // a full 3D mesh load per output at the exact moment the drag starts.
    readonly property bool onBoardNow: frame.board === null ? true
        : frame.x + frame.width > 0 && frame.x < frame.board.width
            && frame.y + frame.height > 0 && frame.y < frame.board.height
    readonly property var variantInfo: Widgets.variantAt(frame.wtype, frame.wvariant)
    // a variant that carries its own size: drag any edge instead of picking S/M/L/XL
    readonly property bool resizable: frame.variantInfo !== null && frame.variantInfo.resizable === true
    readonly property bool verticalOnly: frame.variantInfo !== null && frame.variantInfo.resizeAxis === "vertical"
    readonly property real safeZoom: frame.zoom > 0 ? frame.zoom : 1
    // a catalogue size is drawn at the interface size; a hand-sized card keeps its own
    readonly property real sizeScale: frame.resizable ? 1 : Theme.uiScale
    // while a grip is held the card runs off the live drag, not off the store
    readonly property real bodyW: frame.resizing ? frame.resW / frame.safeZoom : Math.round(frame.bw * frame.sizeScale)
    readonly property real bodyH: frame.resizing ? frame.resH / frame.safeZoom : Math.round(frame.bh * frame.sizeScale)
    readonly property real cardW: Math.round(frame.bodyW * frame.zoom)
    readonly property real cardH: Math.round(frame.bodyH * frame.zoom)
    // the same corner geometry the compositor gives a window, so cards and the
    // windows around them read as one surface language
    readonly property int radius: Math.round(Math.min(body.item !== null && body.item.pill === true ? frame.cardH : Theme.windowRadius, frame.cardH / 2, frame.cardW / 2))
    // the same corner expressed in the body's own unscaled coordinates
    readonly property real bodyRadius: frame.zoom > 0 ? frame.radius / frame.zoom : frame.radius
    readonly property bool active: frame.hovered || frame.dragging || frame.carried || frame.menuOpen
    // a card leans out under the pointer, as a hint that it is about to be
    // picked up; the drag itself takes it further
    readonly property bool lifting: frame.hovered && !frame.locked && !frame.dragging && !frame.resizing && !frame.closing
    // a variant can ask for no container at all and draw straight onto the wallpaper
    readonly property bool bare: body.item !== null && body.item.bare === true
    // Liquid glass (liquid-glass-hypr): the compositor draws the card's glass
    // behind it, so the QML container goes transparent. Bare variants have no
    // container either way.
    //
    // While a card is actually moving the glass is not published for it: the
    // per-frame blur/capture pass on a moving pill is the expensive part of a
    // drag. The card paints its normal opaque background instead. The hold
    // after the release keeps that background up until the pill has been
    // republished and read, so the hand-off cannot flash a transparent gap.
    readonly property bool moving: frame.dragging || frame.carried
    property bool glassHold: false
    readonly property bool glassSuspended: frame.moving || frame.glassHold
    readonly property bool externalGlass: Prefs.liquidGlassEnabled && !frame.bare && !frame.glassSuspended
    // ... or for nothing at all. never while you are working on the card, and the
    // fade to zero takes it out of the mask on its own, since visible follows opacity
    readonly property bool blanked: body.item !== null && body.item.hidden === true && !frame.dragging && !frame.carried && !frame.resizing && !frame.menuOpen && !frame.selected
    // the desktop's box is over this card right now; an unseen card never counts.
    // a locked card can still be caught by the box, it just cannot be dragged
    readonly property bool marked: {
        var m = Widgets.marquee;
        if (!m || frame.closing || !frame.visible || !frame.board || m.screen !== frame.board.screenName)
            return false;

        return m.x < frame.x + frame.width && m.x + m.w > frame.x && m.y < frame.y + frame.height && m.y + m.h > frame.y;
    }
    readonly property bool selected: Widgets.selection[frame.uid] === true
    // the widget panel is pointing at this card from its list
    readonly property bool spotted: Widgets.spotUid !== "" && Widgets.spotUid === frame.uid
    // dropped here from the panel: it settles where the ghost was rather than popping in
    readonly property bool landed: Widgets.landingUid !== "" && Widgets.landingUid === frame.uid
    readonly property bool editMode: frame.board !== null && frame.board.panelUp === true
    // held over the open widget panel, where letting go takes it off the desktop
    readonly property bool overBin: frame.dragging && frame.editMode && frame.board.binHit(frame.pointerX, frame.pointerY)

    property bool dragging: false
    property bool resizing: false
    property bool hovered: false
    property bool menuOpen: false
    // where the right-click landed, in the frame's own coordinates
    property real menuAtX: 0
    property real menuAtY: 0
    property real dragX: 0
    property real dragY: 0
    property real grabX: 0
    property real grabY: 0
    property real guideX: -1
    property real guideY: -1
    // the pointer during a drag, in board coordinates
    property real pointerX: -1
    property real pointerY: -1
    // the other selected cards riding along with this one's drag
    property var crew: []
    // where the card sat when the drag began
    property real homeX: 0
    property real homeY: 0
    // Snap targets are fixed for the duration of a drag: the cards around this
    // one do not move, and neither does its own size. Build the candidate
    // numbers once, then each pointer step only scans two flat arrays. The
    // previous per-move snapBox built ~30 temporary objects at pointer rate,
    // which showed up as GC work during long drags.
    property var snapXs: []
    property var snapYs: []
    property var snapResult: ({ "x": 0, "y": 0 })
    // -1 / 0 / 1 for the edge the held grip pulls on
    property int gripH: 0
    property int gripV: 0
    property real pressBX: 0
    property real pressBY: 0
    property real startX: 0
    property real startY: 0
    property real startW: 0
    property real startH: 0
    property real resX: 0
    property real resY: 0
    property real resW: 0
    property real resH: 0

    readonly property real gripSize: Theme.dp(12)
    // the eight handles, clockwise from the top left corner
    readonly property var gripSpecs: [{
        "h": -1,
        "v": -1
    }, {
        "h": 0,
        "v": -1
    }, {
        "h": 1,
        "v": -1
    }, {
        "h": 1,
        "v": 0
    }, {
        "h": 1,
        "v": 1
    }, {
        "h": 0,
        "v": 1
    }, {
        "h": -1,
        "v": 1
    }, {
        "h": -1,
        "v": 0
    }]

    function opt(key) {
        var v = frame.opts[key];
        return v !== undefined ? v : Widgets.defaultOptions(frame.wtype)[key];
    }

    function setOpt(key, value) {
        Widgets.setOption(frame.uid, key, value);
    }

    function setOpts(changes) {
        Widgets.setOptions(frame.uid, changes);
    }

    function clampX(v) {
        return frame.board ? Math.max(0, Math.min(frame.board.width - frame.cardW, v)) : v;
    }

    function clampY(v) {
        return frame.board ? Math.max(0, Math.min(frame.board.height - frame.cardH, v)) : v;
    }

    function siblings() {
        var out = [];
        if (!frame.board)
            return out;

        for (var i = 0; i < frame.board.frameCount; i++) {
            var f = frame.board.frameAt(i);
            // a card riding along in the same drag is no edge to snap to
            if (f && f !== frame && f.visible && !f.closing && !f.dragging)
                out.push(f);

        }
        return out;
    }

    // flat [value, guide, value, guide, ...] lists, built once per drag
    function rebuildSnap() {
        frame.snapXs = [];
        frame.snapYs = [];
        if (!Prefs.widgetSnap || !frame.board)
            return ;
        var W = frame.board.width;
        var H = frame.board.height;
        var w = frame.cardW;
        var h = frame.cardH;
        var pad = 20;
        var gap = 16;
        var xs = [pad, pad, W - pad - w, W - pad, (W - w) / 2, W / 2];
        var ys = [pad, pad, H - pad - h, H - pad, (H - h) / 2, H / 2];
        var others = frame.siblings();
        for (var i = 0; i < others.length; i++) {
            var f = others[i];
            xs.push(f.x, f.x, f.x + f.width - w, f.x + f.width,
                f.x + (f.width - w) / 2, f.x + f.width / 2,
                f.x + f.width + gap, -1, f.x - gap - w, -1);
            ys.push(f.y, f.y, f.y + f.height - h, f.y + f.height,
                f.y + (f.height - h) / 2, f.y + f.height / 2,
                f.y + f.height + gap, -1, f.y - gap - h, -1);
        }
        frame.snapXs = xs;
        frame.snapYs = ys;
    }

    function nearestSnapIndex(pos, list) {
        var best = -1;
        var bd = 9;
        for (var i = 0; i < list.length; i += 2) {
            var d = Math.abs(pos - list[i]);
            if (d < bd) {
                bd = d;
                best = i;
            }
        }
        return best;
    }

    function snapTo(nx, ny) {
        if (!Prefs.widgetSnap || !frame.board || frame.snapXs.length === 0) {
            frame.guideX = -1;
            frame.guideY = -1;
            frame.snapResult.x = nx;
            frame.snapResult.y = ny;
            return frame.snapResult;
        }
        var ix = frame.nearestSnapIndex(nx, frame.snapXs);
        var iy = frame.nearestSnapIndex(ny, frame.snapYs);
        frame.guideX = ix >= 0 ? frame.snapXs[ix + 1] : -1;
        frame.guideY = iy >= 0 ? frame.snapYs[iy + 1] : -1;
        frame.snapResult.x = ix >= 0 ? frame.snapXs[ix] : nx;
        frame.snapResult.y = iy >= 0 ? frame.snapYs[iy] : ny;
        return frame.snapResult;
    }

    // the card and its crew in the global layout, for the copies on the other
    // outputs to draw
    function publishCarry() {
        var bx = frame.board ? frame.board.screenX : 0;
        var by = frame.board ? frame.board.screenY : 0;
        var out = {};
        out[frame.uid] = {
            "x": bx + frame.dragX,
            "y": by + frame.dragY,
            "w": frame.width,
            "h": frame.height
        };
        for (var i = 0; i < frame.crew.length; i++) {
            var c = frame.crew[i];
            if (!c)
                continue;

            out[c.uid] = {
                "x": bx + c.dragX,
                "y": by + c.dragY,
                "w": c.width,
                "h": c.height
            };
        }
        Widgets.dragRects = out;
    }

    function beginDrag(mx, my) {
        // a card outside the selection moves on its own and lets the rest go
        if (!frame.selected)
            Widgets.clearSelection();

        if (frame.locked)
            return ;

        var crew = [];
        if (frame.selected) {
            for (var i = 0; frame.board && i < frame.board.frameCount; i++) {
                var f = frame.board.frameAt(i);
                if (f && f !== frame && f.selected && f.visible && !f.closing && !f.locked)
                    crew.push(f);

            }
            // lifted in their current stacking order, under the one in hand
            crew.sort((a, b) => {
                return a.zOrder - b.zOrder;
            });
        }
        for (var j = 0; j < crew.length; j++) {
            var c = crew[j];
            c.homeX = c.x;
            c.homeY = c.y;
            c.dragX = c.x;
            c.dragY = c.y;
            c.dragging = true;
            Widgets.raise(c.uid);
        }
        frame.crew = crew;
        frame.rebuildSnap();
        frame.grabX = mx;
        frame.grabY = my;
        frame.homeX = frame.x;
        frame.homeY = frame.y;
        frame.dragX = frame.x;
        frame.dragY = frame.y;
        frame.pointerX = -1;
        frame.pointerY = -1;
        frame.dragging = true;
        if (frame.board)
            frame.board.dragFrame = frame;

        publishCarry();
        Widgets.dragUid = frame.uid;
        Widgets.raise(frame.uid);
    }

    function moveDrag(mx, my) {
        if (!frame.dragging)
            return ;

        // the pointer may sit over another output now. snapping to the board it
        // started on would drag the card back to that screen's edges, so the
        // card only snaps while the pointer is still over its own board
        var crossing = false;
        if (frame.board) {
            var at = frame.mapToItem(frame.board, mx, my);
            frame.pointerX = at.x;
            frame.pointerY = at.y;
            var target = Widgets.screenAt(frame.board.screenX + at.x, frame.board.screenY + at.y);
            crossing = target !== null && target.name !== frame.board.screenName;
        }
        var rawX = frame.dragX + (mx - frame.grabX);
        var rawY = frame.dragY + (my - frame.grabY);
        var snapped;
        if (crossing) {
            frame.guideX = -1;
            frame.guideY = -1;
            snapped = {
                "x": rawX,
                "y": rawY
            };
        } else {
            snapped = frame.snapTo(rawX, rawY);
        }
        var dx = snapped.x - frame.homeX;
        var dy = snapped.y - frame.homeY;
        if (frame.board && !crossing) {
            // the group stops at an edge as one, so its shape never changes
            var l = frame.homeX;
            var t = frame.homeY;
            var r = frame.homeX + frame.cardW;
            var b = frame.homeY + frame.cardH;
            for (var i = 0; i < frame.crew.length; i++) {
                var c = frame.crew[i];
                if (!c)
                    continue;

                l = Math.min(l, c.homeX);
                t = Math.min(t, c.homeY);
                r = Math.max(r, c.homeX + c.width);
                b = Math.max(b, c.homeY + c.height);
            }
            dx = Math.max(-l, Math.min(frame.board.width - r, dx));
            dy = Math.max(-t, Math.min(frame.board.height - b, dy));
        }
        frame.dragX = frame.homeX + dx;
        frame.dragY = frame.homeY + dy;
        for (var j = 0; j < frame.crew.length; j++) {
            var m = frame.crew[j];
            if (!m)
                continue;

            m.dragX = m.homeX + dx;
            m.dragY = m.homeY + dy;
        }
        publishCarry();
        Widgets.setLive(frame.uid, frame.dragX, frame.dragY, frame.width, frame.height);
    }

    function endDrag(mx, my) {
        if (!frame.dragging)
            return ;

        var originX = frame.board ? frame.board.screenX : 0;
        var originY = frame.board ? frame.board.screenY : 0;
        // the release is the last move, so a quick let-go right at a seam still
        // lands on the output the pointer ended on
        if (mx !== undefined && my !== undefined && frame.board) {
            var at = frame.mapToItem(frame.board, mx, my);
            frame.pointerX = at.x;
            frame.pointerY = at.y;
        }
        var binned = frame.overBin;
        var crew = frame.crew;
        var carry = Widgets.dragRects;
        // the pointer decides the output; a drag released without a position
        // leaves it on the card's own centre
        var gx = frame.pointerX >= 0 ? originX + frame.pointerX : originX + frame.dragX + frame.width / 2;
        var gy = frame.pointerY >= 0 ? originY + frame.pointerY : originY + frame.dragY + frame.height / 2;
        var target = Widgets.screenAt(gx, gy);
        if (target === null && frame.board)
            target = Widgets.screenNamed(frame.board.screenName);

        frame.crew = [];
        frame.dragging = false;
        frame.guideX = -1;
        frame.guideY = -1;
        if (frame.board && frame.board.dragFrame === frame)
            frame.board.dragFrame = null;

        if (Widgets.dragUid === frame.uid)
            Widgets.dragUid = "";

        frame.pointerX = -1;
        frame.pointerY = -1;
        // dropped on the panel: the card and whatever rode along with it go
        if (binned) {
            Widgets.dragRects = ({});
            for (var b = 0; b < crew.length; b++) {
                if (crew[b]) {
                    crew[b].dragging = false;
                    Widgets.close(crew[b].uid);
                }
            }
            Widgets.clearSelection();
            Widgets.close(frame.uid);
            return ;
        }
        // the whole group lands on the output under the pointer, keeping the
        // shape it had while it was carried there
        if (frame.board && target !== null) {
            var mine = carry[frame.uid];
            if (!mine)
                mine = {
                "x": originX + frame.dragX,
                "y": originY + frame.dragY,
                "w": frame.width,
                "h": frame.height
            };

            Widgets.placeOn(frame.uid, target, mine.x, mine.y, mine.w || frame.width, mine.h || frame.height);
            for (var i = 0; i < crew.length; i++) {
                var c = crew[i];
                if (!c)
                    continue;

                var theirs = carry[c.uid];
                if (!theirs)
                    theirs = {
                    "x": originX + c.dragX,
                    "y": originY + c.dragY,
                    "w": c.width,
                    "h": c.height
                };

                Widgets.placeOn(c.uid, target, theirs.x, theirs.y, theirs.w || c.width, theirs.h || c.height);
                c.dragging = false;
            }
        } else {
            Widgets.setPos(frame.uid, frame.dragX, frame.dragY);
            for (var j = 0; j < crew.length; j++) {
                var m = crew[j];
                if (!m)
                    continue;

                Widgets.setPos(m.uid, m.dragX, m.dragY);
                m.dragging = false;
            }
        }
        Widgets.dragRects = ({});
        // a click that went nowhere lets the selection go
        if (frame.dragX === frame.homeX && frame.dragY === frame.homeY)
            Widgets.clearSelection();

        Widgets.liveUid = "";
    }

    function beginResize(hx, vy, px, py) {
        if (frame.locked || !frame.resizable)
            return ;

        frame.gripH = frame.verticalOnly ? 0 : hx;
        frame.gripV = vy;
        frame.pressBX = px;
        frame.pressBY = py;
        frame.startX = frame.x;
        frame.startY = frame.y;
        frame.startW = frame.width;
        frame.startH = frame.height;
        frame.resX = frame.x;
        frame.resY = frame.y;
        frame.resW = frame.width;
        frame.resH = frame.height;
        frame.resizing = true;
        Widgets.raise(frame.uid);
    }

    function moveResize(px, py) {
        if (!frame.resizing)
            return ;

        // the catalogue's limits are body pixels, the pointer moves in board ones
        var lim = Widgets.sizeLimits(frame.wtype, frame.wvariant);
        var z = frame.safeZoom;
        var boardW = frame.board ? frame.board.width : frame.startX + frame.startW;
        var boardH = frame.board ? frame.board.height : frame.startY + frame.startH;
        var dx = px - frame.pressBX;
        var dy = py - frame.pressBY;
        var nx = frame.startX;
        var ny = frame.startY;
        var nw = frame.startW;
        var nh = frame.startH;
        // Snap the face being dragged to half-steps of the catalogue's 1:1
        // reference. The grid is anchored on the catalogue size so a fresh
        // card already sits on it.
        var k = Prefs.interfaceScale;
        var step = Widgets.resizeStep(frame.wtype, frame.wvariant) * k * z;
        var variant = Widgets.variantAt(frame.wtype, frame.wvariant);
        var baseW = variant ? (Number(variant.w) || 0) * k * z : frame.startW;
        var baseH = variant ? (Number(variant.h) || 0) * k * z : frame.startH;
        if (!frame.verticalOnly && frame.gripH > 0) {
            nw = Math.min(lim.maxW * z, Math.min(boardW - nx, frame.startW + dx));
        } else if (!frame.verticalOnly && frame.gripH < 0) {
            var right = frame.startX + frame.startW;
            nw = Math.min(lim.maxW * z, Math.min(right, frame.startW - dx));
        }
        if (frame.gripV > 0) {
            nh = Math.min(lim.maxH * z, Math.min(boardH - ny, frame.startH + dy));
        } else if (frame.gripV < 0) {
            var bottom = frame.startY + frame.startH;
            nh = Math.min(lim.maxH * z, Math.min(bottom, frame.startH - dy));
        }
        if (step > 0) {
            if (!frame.verticalOnly && frame.gripH !== 0)
                nw = baseW + Math.round((nw - baseW) / step) * step;

            if (frame.gripV !== 0)
                nh = baseH + Math.round((nh - baseH) / step) * step;

        }
        if (frame.verticalOnly) {
            nw = frame.startW;
            nx = frame.startX;
        } else {
            nw = Math.max(lim.minW * z, Math.min(lim.maxW * z, nw));
            if (frame.gripH < 0)
                nx = frame.startX + frame.startW - nw;
        }
        nh = Math.max(lim.minH * z, Math.min(lim.maxH * z, nh));

        if (frame.gripV < 0)
            ny = frame.startY + frame.startH - nh;

        frame.resX = nx;
        frame.resY = ny;
        frame.resW = nw;
        frame.resH = nh;
        Widgets.setLive(frame.uid, nx, ny, nw, nh);
    }

    function endResize() {
        if (!frame.resizing)
            return ;

        var z = frame.safeZoom;
        Widgets.setSize(frame.uid, frame.resW / z, frame.resH / z);
        Widgets.setPos(frame.uid, frame.resX, frame.resY);
        frame.resizing = false;
        Widgets.liveUid = "";
    }

    // the menu's shortcut for the look the visualiser is really after
    function fillWidth() {
        if (!frame.board || !frame.resizable)
            return ;

        Widgets.setSize(frame.uid, frame.board.width / frame.safeZoom, frame.bh);
        Widgets.setPos(frame.uid, 0, frame.wy);
    }

    // Let a body opt into keyboard scrolling while the pointer is over it.
    function handleScrollKey(event) {
        if (body.item && typeof body.item.handleScrollKey === "function")
            return body.item.handleScrollKey(event) === true;

        return false;
    }

    function toggleMenu(px, py) {
        if (frame.menuOpen) {
            frame.menuOpen = false;
            if (Widgets.menuUid === frame.uid)
                Widgets.menuUid = "";

        } else {
            // claim the slot first: the connection below shuts every other menu,
            // and this frame's own guard would close us if we opened before it
            frame.menuAtX = px === undefined ? frame.width / 2 : px;
            frame.menuAtY = py === undefined ? frame.height / 2 : py;
            Widgets.menuUid = frame.uid;
            frame.menuOpen = true;
            Widgets.raise(frame.uid);
        }
    }

    // what WidgetRegion masks and blurs
    readonly property real surfaceX: 0
    readonly property real surfaceY: 0
    readonly property real surfaceWidth: frame.width
    readonly property real surfaceHeight: frame.height
    readonly property int surfaceRadius: frame.radius
    // the remove and pin badges overhang the corner, and the layer's input mask
    // only takes what these rects say, so each badge gets one of its own
    readonly property bool badgeShown: removeBadge.shown
    readonly property real badgeX: removeBadge.x
    readonly property real badgeY: removeBadge.y
    readonly property real badgeW: removeBadge.width
    readonly property real badgeH: removeBadge.height
    readonly property bool pinBadgeShown: pinBadge.shown
    readonly property real pinBadgeX: pinBadge.x
    readonly property real pinBadgeY: pinBadge.y
    readonly property real pinBadgeW: pinBadge.width
    readonly property real pinBadgeH: pinBadge.height

    visible: (frame.onThisScreen || frame.carried) && frame.onBoardNow && frame.opacity > 0.01
    width: frame.cardW
    height: frame.cardH
    z: frame.zOrder
    x: frame.resizing ? frame.resX : (frame.carried && frame.board ? frame.carry.x - frame.board.screenX : frame.clampX(frame.wx))
    y: frame.resizing ? frame.resY : (frame.carried && frame.board ? frame.carry.y - frame.board.screenY : frame.clampY(frame.wy))
    opacity: (frame.closing || frame.blanked) ? 0 : (frame.appeared ? (frame.overBin ? 0.4 : 1) : 0)
    scale: frame.closing ? 0.9 : (frame.appeared ? (frame.overBin ? 0.94 : (frame.carried ? 1.025 : (frame.lifting ? 1.0125 : 1))) : (frame.landed ? 1 : (frame.born ? 0.86 : 0.97)))

    property bool appeared: false

    Component.onCompleted: appearTimer.start()
    // Hand the glass back once the pill has been republished and read. 90 ms
    // is well past the 4 ms bridge write and the plugin's 8 ms scan, while
    // short enough not to be felt after the drop.
    onMovingChanged: {
        if (frame.moving) {
            glassHoldTimer.stop();
            frame.glassHold = false;
        } else if (Prefs.liquidGlassEnabled && !frame.bare) {
            frame.glassHold = true;
            glassHoldTimer.restart();
        }
    }

    Timer {
        id: glassHoldTimer

        interval: 90
        repeat: false
        onTriggered: frame.glassHold = false
    }

    // the box picks cards up and drops them live; letting it go keeps what it held
    onMarkedChanged: {
        if (Widgets.marquee !== null)
            Widgets.select(frame.uid, frame.marked);

    }
    onLockedChanged: {
        if (frame.locked)
            Widgets.select(frame.uid, false);

    }

    Connections {
        function onMenuUidChanged() {
            if (Widgets.menuUid !== frame.uid)
                frame.menuOpen = false;

        }

        target: Widgets
    }

    Timer {
        id: appearTimer

        interval: frame.born ? 20 : 1
        onTriggered: frame.appeared = true
    }

    Behavior on opacity {
        NumberAnimation {
            duration: Theme.durMedium
            easing.type: Theme.easeStandard
        }

    }

    Behavior on scale {
        NumberAnimation {
            duration: Theme.durMedium
            easing.type: Easing.OutBack
            easing.overshoot: 0.7
        }

    }

    Behavior on width {
        enabled: frame.appeared && !frame.resizing

        NumberAnimation {
            duration: Theme.durMedium
            easing.type: Theme.easeStandard
        }

    }

    Behavior on height {
        enabled: frame.appeared && !frame.resizing

        NumberAnimation {
            duration: Theme.durMedium
            easing.type: Theme.easeStandard
        }

    }

    Behavior on x {
        enabled: !frame.dragging && !frame.carried && !frame.resizing

        NumberAnimation {
            duration: Theme.durMedium
            easing.type: Theme.easeStandard
        }

    }

    Behavior on y {
        enabled: !frame.dragging && !frame.carried && !frame.resizing

        NumberAnimation {
            duration: Theme.durMedium
            easing.type: Theme.easeStandard
        }

    }

    HoverHandler {
        id: hoverHandler

        enabled: !frame.closing
        onHoveredChanged: frame.hovered = hoverHandler.hovered
        cursorShape: (frame.locked || frame.resizing) ? Qt.ArrowCursor : (frame.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
    }

    // sits under the body so buttons and fields inside the widget win the click -
    // except on a selected card, where it lifts over the body: a body that covers
    // its whole card (notes, palette) would otherwise eat the press and the
    // selection could never be dragged. the badge and the resize grips stay above
    MouseArea {
        id: dragArea

        anchors.fill: parent
        z: frame.selected ? 7 : 0
        acceptedButtons: Qt.LeftButton
        // a selected card is being moved as a whole: keep scroll views, lists
        // and other pointer handlers inside the body from stealing the drag
        // once it starts (the social feed's Flickable was catching it)
        preventStealing: frame.selected
        cursorShape: frame.selected ? (frame.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.ArrowCursor
        onPressed: (mouse) => {
            Widgets.raise(frame.uid);
            frame.beginDrag(mouse.x, mouse.y);
        }
        onPositionChanged: (mouse) => {
            return frame.moveDrag(mouse.x, mouse.y);
        }
        onReleased: (mouse) => frame.endDrag(mouse.x, mouse.y)
        onCanceled: frame.endDrag()
    }

    SquircleRect {
        id: card

        anchors.fill: parent
        radius: frame.radius
        fillColor: (frame.bare || frame.externalGlass) ? "transparent" : (body.item && body.item.fill !== undefined ? body.item.fill : Theme.bg)
        smoothing: Prefs.squircleF

        Behavior on fillColor {
            // instant while the glass is suspended (so the card is never see-
            // through for a frame); the release hold lets the fill fade back
            // to glass only after the pill is already published behind it
            enabled: !frame.glassSuspended

            ColorAnimation {
                duration: Theme.durSlowEffects
            }

        }

        // the card still clips its contents to the bounding rectangle (the
        // rounded edge itself is drawn by the squircle, as a Rectangle's
        // radius never cut children either)
        Item {
            anchors.fill: parent
            clip: true

            // the body lays out at its natural size and the whole thing is scaled, so a
            // variant never has to know what zoom it is being drawn at
            Item {
                width: frame.bodyW
                height: frame.bodyH
                scale: frame.zoom
                transformOrigin: Item.TopLeft

                // a preset can resize a card as it moves it, so the content follows the card
                Behavior on scale {
                    enabled: frame.appeared && !frame.resizing

                    NumberAnimation {
                        duration: Theme.durMedium
                        easing.type: Theme.easeStandard
                    }

                }

                Loader {
                    id: body

                    anchors.fill: parent
                    asynchronous: false
                    // a selected card drags as a whole: its own contents must not
                    // see the pointer, or a DragHandler inside them (the social
                    // feed's swipe-to-dismiss posts, a Flickable, a button) steals
                    // the drag once it passes its threshold
                    enabled: !frame.selected
                    // clock -> ClockWidget.qml, and so on for every category
                    source: frame.wtype === "" ? "" : frame.wtype.charAt(0).toUpperCase() + frame.wtype.slice(1) + "Widget.qml"

                }

            }

            Binding {
                target: body.item
                property: "host"
                value: frame
                when: body.status === Loader.Ready
            }

            SquircleRect {
                anchors.fill: parent
                radius: frame.radius
                fillColor: Theme.text
                smoothing: Prefs.squircleF
                // a pinned card cannot be moved or resized, so it gets no hover chrome
                // at all - on a bare full-width one this tint was a stray rectangle
                opacity: frame.locked ? 0 : (frame.carried ? 0.07 : (frame.active ? 0.035 : 0))

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.durShort
                    }

                }

            }

        }

    }

    // no hover chrome: right-press opens the options menu, and a right-drag moves
    // the widget, since bodies that cover their whole card (notes, palette) eat the
    // left press that dragArea below would have used
    MouseArea {
        id: menuArea

        property real pressX: 0
        property real pressY: 0
        property bool moved: false

        anchors.fill: parent
        z: 6
        // left presses fall straight through to the body and to dragArea
        acceptedButtons: Qt.RightButton
        onPressed: (mouse) => {
            menuArea.pressX = mouse.x;
            menuArea.pressY = mouse.y;
            menuArea.moved = false;
            Widgets.raise(frame.uid);
        }
        onPositionChanged: (mouse) => {
            if (!menuArea.moved) {
                // a pinned widget cannot move, so never swallow its menu click
                if (frame.locked)
                    return ;

                if (Math.abs(mouse.x - menuArea.pressX) < 4 && Math.abs(mouse.y - menuArea.pressY) < 4)
                    return ;

                menuArea.moved = true;
                frame.beginDrag(menuArea.pressX, menuArea.pressY);
            }
            frame.moveDrag(mouse.x, mouse.y);
        }
        onReleased: (mouse) => {
            if (menuArea.moved)
                frame.endDrag(mouse.x, mouse.y);
            else
                frame.toggleMenu(menuArea.pressX, menuArea.pressY);
            menuArea.moved = false;
        }
        onCanceled: {
            if (menuArea.moved)
                frame.endDrag();

            menuArea.moved = false;
        }
    }

    // what the desktop's box caught, shown live while the box is still out, and the
    // card the widget panel's list is pointing at
    SquircleRect {
        anchors.fill: parent
        z: 7
        radius: frame.radius
        fillColor: Theme.alpha(Theme.accent, 0.1)
        borderWidth: 2
        borderColor: Theme.accent
        smoothing: Prefs.squircleF
        opacity: (frame.selected || frame.spotted) ? 1 : 0
        visible: opacity > 0.01

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.durShort
            }

        }

    }

    // a resizable card has no other affordance, so outline it while it is under
    // the pointer - the bare variants have no container to hint at an edge
    Item {
        anchors.fill: parent
        z: 7
        visible: frame.resizable && !frame.locked && outline.opacity > 0.01

        SquircleRect {
            id: outline

            anchors.fill: parent
            radius: frame.radius
            fillColor: "transparent"
            borderWidth: 1
            borderColor: Theme.alpha(Theme.accent, 0.55)
            smoothing: Prefs.squircleF
            opacity: (frame.active || frame.resizing) ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.durShort
                }

            }

        }

    }

    // eight handles over everything else, left button only so a right press still
    // reaches the menu underneath
    Repeater {
        model: (frame.resizable && !frame.locked) ? (frame.verticalOnly ? [frame.gripSpecs[1], frame.gripSpecs[5]] : frame.gripSpecs) : []

        MouseArea {
            id: grip

            required property var modelData

            readonly property real t: frame.gripSize

            z: 8
            enabled: !frame.locked
            acceptedButtons: Qt.LeftButton
            hoverEnabled: true
            cursorShape: {
                if (grip.modelData.h === 0)
                    return Qt.SizeVerCursor;

                if (grip.modelData.v === 0)
                    return Qt.SizeHorCursor;

                return grip.modelData.h === grip.modelData.v ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor;
            }
            x: grip.modelData.h < 0 ? 0 : (grip.modelData.h > 0 ? frame.width - grip.t : grip.t)
            y: grip.modelData.v < 0 ? 0 : (grip.modelData.v > 0 ? frame.height - grip.t : grip.t)
            width: grip.modelData.h === 0 ? Math.max(0, frame.width - grip.t * 2) : grip.t
            height: grip.modelData.v === 0 ? Math.max(0, frame.height - grip.t * 2) : grip.t
            onPressed: (mouse) => {
                var p = grip.mapToItem(frame.board, mouse.x, mouse.y);
                frame.beginResize(grip.modelData.h, grip.modelData.v, p.x, p.y);
            }
            onPositionChanged: (mouse) => {
                var p = grip.mapToItem(frame.board, mouse.x, mouse.y);
                frame.moveResize(p.x, p.y);
            }
            onReleased: frame.endResize()
            onCanceled: frame.endResize()
        }

    }

    // while the widget panel is open, and on every card caught by the desktop's
    // box, a way off the desktop - pulled inside the screen when the card sits
    // right on its edge
    Item {
        id: removeBadge

        readonly property bool shown: (frame.editMode || frame.selected) && !frame.closing && !frame.dragging && !frame.carried && !frame.resizing

        z: 9
        width: Theme.dp(26)
        height: Theme.dp(26)
        x: Math.max(-Theme.dp(9), Theme.dp(4) - frame.x)
        y: Math.max(-Theme.dp(9), Theme.dp(4) - frame.y)
        opacity: removeBadge.shown ? 1 : 0
        scale: removeBadge.shown ? 1 : 0.5
        visible: opacity > 0.01

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: badgeArea.containsMouse ? Theme.error : Theme.surfaceHighest
            border.width: 1
            border.color: Theme.alpha(Theme.text, 0.12)

            Behavior on color {
                ColorAnimation {
                    duration: Theme.durFastEffects
                }

            }

        }

        Icon {
            anchors.centerIn: parent
            name: "remove"
            size: Theme.dp(18)
            color: badgeArea.containsMouse ? Theme.fgError : Theme.text
        }

        StateLayer {
            id: badgeArea

            radius: width / 2
            ripple: false
            tint: Theme.fgError
            onClicked: {
                Widgets.select(frame.uid, false);
                Widgets.close(frame.uid);
            }
        }

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.durFastEffects
            }

        }

        Behavior on scale {
            NumberAnimation {
                duration: Theme.durFastSpatial
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveFastSpatial
            }

        }

    }

    // keeps the card on every wallpaper. each wallpaper still holds its own copy,
    // so moving it here does not move it on the others
    Item {
        id: pinBadge

        readonly property bool shown: removeBadge.shown
        readonly property bool active: frame.everywhere

        z: 9
        width: Theme.dp(26)
        height: Theme.dp(26)
        x: removeBadge.x + removeBadge.width + Theme.dp(6)
        y: removeBadge.y
        opacity: pinBadge.shown ? 1 : 0
        scale: pinBadge.shown ? 1 : 0.5
        visible: opacity > 0.01

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: pinBadge.active ? (pinArea.containsMouse ? Theme.primary : Theme.primaryContainer) : Theme.surfaceHighest
            border.width: 1
            border.color: pinBadge.active ? Theme.primary : (pinArea.containsMouse ? Theme.accent : Theme.alpha(Theme.text, 0.12))

            Behavior on color {
                ColorAnimation {
                    duration: Theme.durFastEffects
                }

            }

            Behavior on border.color {
                ColorAnimation {
                    duration: Theme.durFastEffects
                }

            }

        }

        Icon {
            anchors.centerIn: parent
            name: "keep"
            size: Theme.dp(18)
            fill: pinBadge.active ? 1 : 0
            color: pinBadge.active ? (pinArea.containsMouse ? Theme.fgPrimary : Theme.fgPrimaryContainer) : Theme.text
        }

        StateLayer {
            id: pinArea

            radius: width / 2
            ripple: false
            tint: Theme.accent
            onClicked: Widgets.toggleEverywhere(frame.uid)
        }

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.durFastEffects
            }

        }

        Behavior on scale {
            NumberAnimation {
                duration: Theme.durFastSpatial
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveFastSpatial
            }

        }

    }

}
