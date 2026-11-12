import QtQuick
import qs

// The picker styles built from slots: every wallpaper is one shape that glides
// between places as the selection moves, changing width, height and corner
// radius on the way. A style only says where the wallpaper `offset` places from
// the selected one goes (slotRect); this does the rest, and has the same
// interface as WallpaperStrip so the launcher can load any of them.
Item {
    id: strip

    property var model: null
    property int heroW: 340
    property int heroH: 211
    // the tiers of the strip style; slot styles lay themselves out, but the launcher sets them
    property int midW: 238
    property int midH: 148
    property int smallW: 150
    property int smallH: 93
    property int tinyW: 100
    property int tinyH: 62
    property int itemGap: Theme.dp(10)
    property int hoveredIndex: -1
    property int currentIndex: -1
    property bool userMoved: false
    property string appliedPath: ""
    // the picker's query, for the explicit "nothing matched" state
    property string filterText: ""
    // the Live tab: the same picker over the videos
    property bool live: false
    // a style with real corners opts into the shell's squircle curve; the
    // pill style leaves smoothing at 0, where the same mask is an exact
    // capsule and keeps its Theme.pill ends
    property bool squircle: false
    property real stableHeight: height
    property bool syncing: false
    // True while the picker is being laid out (the launcher opening, or the
    // panel widening for this tab): the slots ease from their old size to the
    // new one. The picture must not ride that ease, or the wallpaper scales
    // with the growing card. See the card's WallpaperCardMedia below.
    property bool layoutResizing: false
    // How many slots either side of the selected one a style can put on screen.
    // A card's picture is only built within this reach (see the delegate's
    // `near`), so a library of a hundred wallpapers does not decode a hundred
    // pictures at once - and does not decode them again on every model rebuild.
    // Styles that show more (the pills) raise it.
    property int visibleReach: 6
    // where the pointer has carried the slots while a drag is in progress
    property bool dragging: false
    property real dragOffset: 0
    property real originX: -1
    property real originY: -1
    readonly property int count: strip.model ? strip.model.count : 0
    // the wallpapers own the whole picker body: no caption strip below them
    readonly property real stageTop: 0
    readonly property real stageH: Math.max(0, strip.stableHeight)
    // slotRect(offset) -> { x, y, w, h, r, o }: where the wallpaper that many places
    // from the selected one sits in the stage, its corner radius and opacity (0 hides it)
    property var slotRect: function (offset) {
        return {
            "x": 0,
            "y": 0,
            "w": 0,
            "h": 0,
            "r": 0,
            "o": 0
        };
    }

    // Far slots are invisible. Share one parked rect per side instead of
    // building a fresh object for every item on each stage resize/selection.
    // The style's own out-of-range result is kept, so the entrance geometry is
    // exactly what it was; only the per-delegate allocation is gone.
    readonly property var parkedRightRect: {
        strip.width;
        strip.height;
        return strip.slotRect(1000000);
    }

    readonly property var parkedLeftRect: {
        strip.width;
        strip.height;
        return strip.slotRect(-1000000);
    }

    signal chosen(string path)
    signal wallpaperDeleteRequested(string path)

    function noteOrigin(card) {
        if (!card || strip.Window.width <= 0 || strip.Window.height <= 0) {
            strip.originX = -1;
            strip.originY = -1;
            return;
        }
        var p = card.mapToItem(null, card.width / 2, card.height / 2);
        strip.originX = p.x / strip.Window.width;
        strip.originY = p.y / strip.Window.height;
    }

    function step(d) {
        if (strip.count > 0) {
            strip.userMoved = true;
            strip.currentIndex = Math.max(0, Math.min(strip.count - 1, strip.currentIndex + d));
        }
    }

    function stepVertical(d) {
    }

    function pathAt(i) {
        var item = (strip.model && i >= 0 && i < strip.count) ? strip.model.get(i) : null;
        return item ? item.path : "";
    }

    function activateCurrent() {
        var path = strip.pathAt(strip.currentIndex);
        if (path === "")
            return;

        strip.noteOrigin(slots.itemAt(strip.currentIndex));
        strip.chosen(path);
    }

    // Delete: the card under the pointer if there is one, otherwise the
    // selected card - the same interface as WallpaperStrip's, so the launcher's
    // Delete key works in the slot styles too.
    function deleteHighlighted() {
        if (strip.count <= 0)
            return false;

        const at = strip.hoveredIndex >= 0 && strip.hoveredIndex < strip.count ? strip.hoveredIndex : strip.currentIndex;
        if (at < 0 || at >= strip.count)
            return false;

        const item = strip.model ? strip.model.get(at) : null;
        if (!item || item.path === "")
            return false;

        strip.hoveredIndex = -1;
        strip.wallpaperDeleteRequested(item.path);
        return true;
    }

    function setIndexImmediate(i) {
        strip.syncing = true;
        strip.currentIndex = i;
        restoreAnim.restart();
    }

    // the model arrives after the picker does
    onCurrentIndexChanged: strip.hoveredIndex = -1
    onCountChanged: {
        if (strip.count > 0 && strip.currentIndex < 0)
            strip.currentIndex = 0;

    }

    Timer {
        id: restoreAnim

        interval: 120
        onTriggered: strip.syncing = false
    }

    // The slot width/height Behaviors run for 300 ms. Keep the picture pinned
    // to the final slot for a beat after the last layout change, then let it
    // follow normally again once the card has settled.
    Timer {
        id: layoutSettle

        interval: Theme.ms(340)
        onTriggered: strip.layoutResizing = false
    }

    onWidthChanged: {
        if (strip.width > 1) {
            strip.layoutResizing = true;
            layoutSettle.restart();
        }
    }
    onStableHeightChanged: {
        if (strip.stableHeight > 1) {
            strip.layoutResizing = true;
            layoutSettle.restart();
        }
    }

    Item {
        id: stage

        y: strip.stageTop
        width: parent.width
        height: strip.stageH
        visible: strip.count > 0

        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: (event) => {
                strip.step(event.angleDelta.y < 0 || event.angleDelta.x < 0 ? 1 : -1);
            }
        }

        // Touch and mouse swipes walk the slots: the row follows the pointer
        // while the button is down, then settles on the shapes it was carried
        // past. The slots are a Repeater positioned by currentIndex, so the
        // drag offset is applied to every shape instead of scrolling a view.
        DragHandler {
            id: swipe

            target: null
            enabled: strip.count > 1
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad | PointerDevice.TouchScreen
            xAxis.enabled: true
            yAxis.enabled: false

            property real grabX: 0
            // last motion point; on release centroid.position can already be
            // back at the press position
            property real lastX: 0

            onCentroidChanged: {
                if (!swipe.active)
                    return ;

                swipe.lastX = centroid.position.x;
                strip.dragOffset = swipe.lastX - swipe.grabX;
            }

            onActiveChanged: {
                if (swipe.active) {
                    swipe.grabX = swipe.lastX = centroid.position.x;
                    strip.dragOffset = 0;
                    strip.dragging = true;
                    return ;
                }

                var dx = swipe.lastX - swipe.grabX + centroid.velocity.x * 0.12;
                strip.dragging = false;
                strip.dragOffset = 0;
                if (Math.abs(dx) < Theme.dp(24))
                    return ;

                var steps = Math.max(1, Math.round(Math.abs(dx) / Math.max(Theme.dp(52), strip.heroW * 0.45)));
                for (var i = 0; i < steps; i++)
                    strip.step(dx < 0 ? 1 : -1);
            }
        }

        Repeater {
            id: slots

            // the model itself, not its count: an int model makes the Repeater
            // rebuild every delegate whenever a row is appended, which is what
            // turned each filter keystroke into a hundred card rebuilds. Bound
            // to the model, inserts and moves only touch the delegates they are
            // about, the same way the strip's Repeater behaves.
            model: strip.model

            delegate: Item {
                id: slot

                required property int index
                required property string path
                required property string name
                required property string thumb
                required property string preview
                required property string kind
                // optional: local rows and older filtered copies do not carry
                // source dimensions, and a required property made every
                // delegate fail to create (the picker rendered an empty stage)
                property int srcWidth: 0
                property int srcHeight: 0

                readonly property int offset: slot.index - strip.currentIndex
                readonly property var rect: slot.near ? strip.slotRect(slot.offset) : (slot.offset > 0 ? strip.parkedRightRect : strip.parkedLeftRect)
                readonly property bool isCurrent: slot.offset === 0
                readonly property bool isApplied: strip.appliedPath !== "" && strip.appliedPath === slot.path
                readonly property bool hovered: slotHover.hovered
                readonly property bool pressed: slotTap.pressed && slot.hovered
                readonly property bool wide: slot.width >= Theme.dp(70)
                // one beyond the reach, so the card entering from the edge
                // already exists and slides in instead of popping
                readonly property bool near: Math.abs(slot.offset) <= strip.visibleReach + 1

                // The slot's own geometry snaps to the target. Only a cheap
                // affine transform moves it from where it was: animating
                // width/height recreated the squircle layer's FBO (and with it
                // the picture's texture) on every frame, which is what made a
                // step cost 30-60 ms. The invariant here is that width/height
                // change once per step, while x/y/scale change per frame.
                property var animFrom: null
                property var animTo: null
                property real animP: 1
                function mixRect(a, b, t) {
                    return {
                        "x": a.x + (b.x - a.x) * t,
                        "y": a.y + (b.y - a.y) * t,
                        "w": a.w + (b.w - a.w) * t,
                        "h": a.h + (b.h - a.h) * t,
                        "r": a.r + (b.r - a.r) * t,
                        "o": a.o + (b.o - a.o) * t
                    };
                }
                onRectChanged: {
                    if (slot.animFrom === null || slot.animTo === null) {
                        slot.animFrom = slot.rect;
                        slot.animTo = slot.rect;
                        slot.animP = 1;
                        return ;
                    }
                    if (!slot.near || (slot.animFrom.o <= 0.01 && slot.rect.o <= 0.01)) {
                        slot.animFrom = slot.rect;
                        slot.animTo = slot.rect;
                        slot.animP = 1;
                        return ;
                    }
                    slot.animFrom = slot.mixRect(slot.animFrom, slot.animTo, slot.animP);
                    slot.animTo = slot.rect;
                    slot.animP = 0;
                    slideAnim.restart();
                }
                Component.onCompleted: {
                    slot.animFrom = slot.rect;
                    slot.animTo = slot.rect;
                }

                NumberAnimation {
                    id: slideAnim

                    target: slot
                    property: "animP"
                    from: 0
                    to: 1
                    duration: Theme.ms(300)
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.easeEmphasizedDecel
                }

                x: (slot.animFrom ? slot.animFrom.x + (slot.rect.x - slot.animFrom.x) * slot.animP : slot.rect.x) + (strip.dragging ? strip.dragOffset : 0)
                y: slot.animFrom ? slot.animFrom.y + (slot.rect.y - slot.animFrom.y) * slot.animP : slot.rect.y
                // target size; the transform paints it at the interpolated size
                width: slot.rect.w
                height: slot.rect.h
                opacity: (slot.hovered && slot.rect.o > 0) ? 1 : slot.rect.o
                visible: slot.opacity > 0.01 && slot.width > 1
                scale: slot.pressed ? 0.97 : 1
                transform: Scale {
                    origin.x: 0
                    origin.y: 0
                    xScale: slot.animFrom ? (slot.animFrom.w + (slot.rect.w - slot.animFrom.w) * slot.animP) / Math.max(1, slot.width) : 1
                    yScale: slot.animFrom ? (slot.animFrom.h + (slot.rect.h - slot.animFrom.h) * slot.animP) / Math.max(1, slot.height) : 1
                }

                onHoveredChanged: {
                    if (slot.hovered)
                        strip.hoveredIndex = slot.index;
                    else if (strip.hoveredIndex === slot.index)
                        strip.hoveredIndex = -1;

                }

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.ms(300)
                    }

                }

                Behavior on scale {
                    NumberAnimation {
                        duration: Theme.durShort
                        easing.type: Easing.OutCubic
                    }

                }

                // Only the slots a style can actually show build a card: the
                // rest stay bare delegates with no picture, no mask layer and
                // no decode. This is the strip's `near` gate, for the slot
                // styles (bento, pills) that used to build every wallpaper.
                Loader {
                    anchors.fill: parent
                    active: slot.near
                    sourceComponent: cardComp
                }

                Component {
                    id: cardComp

                    Rectangle {
                        id: card

                        anchors.fill: parent
                        radius: 5
                        color: Theme.bgTile
                        clip: true

                        // a narrow shape shows the middle of the picture, a wide one all of it.
                        // While the slot is easing to a new size, use that final slot, not the
                        // current half-grown card: the container animates around a steady picture,
                        // instead of the picture stretching to fill each frame.
                        WallpaperCardMedia {
                            anchors.centerIn: parent
                            width: Math.max(strip.layoutResizing ? slot.rect.w : parent.width,
                                            (strip.layoutResizing ? slot.rect.h : parent.height) * 1.6)
                            height: strip.layoutResizing ? slot.rect.h : parent.height
                            path: slot.path
                            thumb: slot.thumb
                            preview: slot.preview
                            kind: slot.kind
                            sourceWidth: slot.srcWidth
                            sourceHeight: slot.srcHeight
                            active: slot.isCurrent || slot.hovered
                            current: slot.isCurrent
                            preferThumb: true
                            sourceSizeWidth: Theme.dp(640)
                            sourceSizeHeight: Theme.dp(400)
                        }

                        Rectangle {
                            anchors.fill: parent
                            color: Theme.text
                            opacity: slot.pressed ? Theme.statePressed : (slot.hovered ? Theme.stateHover : 0)

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: Theme.durShort
                                }

                            }

                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: card.radius
                            color: "transparent"
                            border.color: Theme.accent
                            border.width: slot.isCurrent ? 3 : 0
                            visible: slot.isCurrent
                        }

                    }

                }

                // applied: a check on a wide shape, a dot at the foot of a slim one
                Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.dp(10)
                    width: Theme.dp(24)
                    height: Theme.dp(24)
                    radius: Theme.pill(24)
                    color: Theme.accent
                    visible: slot.isApplied && slot.wide

                    DockGlyph {
                        anchors.centerIn: parent
                        width: Theme.dp(15)
                        height: Theme.dp(15)
                        pathData: DockIcons.check
                        glyphColor: Theme.fgAccent
                    }

                }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Theme.dp(8)
                    width: Theme.dp(8)
                    height: Theme.dp(8)
                    radius: Theme.pill(8)
                    color: Theme.accent
                    visible: slot.isApplied && !slot.wide
                }

                HoverHandler {
                    id: slotHover

                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    id: slotTap

                    onTapped: {
                        if (slot.isCurrent) {
                            strip.noteOrigin(slot);
                            strip.chosen(slot.path);
                        } else {
                            strip.userMoved = true;
                            strip.currentIndex = slot.index;
                        }
                    }
                }

            }

        }

    }

    Column {
        id: emptyState

        anchors.top: parent.top
        anchors.topMargin: Math.max(0, (strip.stableHeight - emptyState.implicitHeight) / 2)
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Theme.dp(10)
        visible: strip.count === 0

        DockGlyph {
            width: Theme.dp(32)
            height: Theme.dp(32)
            anchors.horizontalCenter: parent.horizontalCenter
            opacity: 0.5
            pathData: DockIcons.brokenImage
            glyphColor: Theme.subtext
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: strip.filterText !== "" ? (strip.live ? Tr.t("No live wallpapers found") : Tr.t("No wallpapers found")) : (strip.live ? Tr.t("No videos in this folder") : Tr.t("No wallpapers in this folder"))
            color: Theme.subtext
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontBody
            font.weight: Font.Medium
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(Theme.dp(340), Math.max(Theme.dp(140), strip.width - Theme.dp(32)))
            visible: strip.filterText !== ""
            text: (RemoteWall.enabled && RemoteWall.query !== "" && RemoteWall.query === strip.filterText.toLowerCase())
                ? "Nothing in your library, Wallhaven, or the Workshop matches \"" + strip.filterText + "\"."
                : "No local wallpaper matches \"" + strip.filterText + "\"."
            color: Theme.subtextDim
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontLabel
        }

    }

}
