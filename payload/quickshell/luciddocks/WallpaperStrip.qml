import QtQuick
import qs
import qs.lucidui
import "../squircle"

// Wallpaper selector strip, in Pibble's carousel language: a fixed window of
// 1:2 cards laid out by their continuous rank, so a step slides the whole
// row instead of asking a ListView to relayout a row of changing widths.
Item {
    id: strip

    property var model: null
    property int heroW: Theme.dp(340)
    property int heroH: Theme.dp(211)
    property int midW: Theme.dp(238)
    property int midH: Theme.dp(148)
    property int smallW: Theme.dp(150)
    property int smallH: Theme.dp(93)
    property int tinyW: Theme.dp(100)
    property int tinyH: Theme.dp(62)
    property int itemGap: Theme.dp(10)
    property int hoveredIndex: -1
    property int currentIndex: 0
    // the wallpaper actually in use
    property string appliedPath: ""
    property string filterText: ""
    // the Live tab: the same picker over the videos
    property bool live: false
    property real stableHeight: height

    // where the card the user picked sits, as fractions of the window (-1 when
    // it is not known); the "from the chosen card" transition grows from there
    property real originX: -1
    property real originY: -1

    readonly property int count: strip.model ? strip.model.count : 0
    readonly property int sides: Prefs.wallpaperStripSides === 3 ? 3 : 2
    readonly property int halfVisible: strip.sides

    // 1:2 portrait previews, the same shape Pibble's carousel windows use.
    // The stage's available height sets the card height; its width is half of
    // it, and every rank scales from there so the aspect never changes.
    readonly property int cardH: {
        var hero = isFinite(strip.heroW) && strip.heroW > 0 ? strip.heroW : Theme.dp(280);
        var room = strip.stableHeight - Theme.dp(50);
        if (!isFinite(room) || room <= 0)
            return hero * 2; // before the launcher has handed down its height
        return Math.max(Theme.dp(160), Math.min(hero * 2, Math.round(room)));
    }
    readonly property int cardW: {
        var h = strip.cardH;
        return isFinite(h) && h > 0 ? Math.round(h / 2) : Theme.dp(140);
    }
    readonly property int cardCorner: Math.min(Theme.radiusSm, Math.max(Theme.shapeSm, Math.round(strip.cardW * 0.10)))
    readonly property real rowHeight: strip.cardH + Theme.dp(50)
    readonly property real stageTop: Math.max(0, (strip.stableHeight - strip.rowHeight) / 2)
    readonly property real stageH: strip.cardH + Theme.dp(12)

    // carousel metrics, straight from Pibble's carousel
    readonly property real slotSpacing: strip.cardW + strip.itemGap
    readonly property real parallaxFactor: 0.28
    readonly property real parallaxPx: strip.slotSpacing * strip.parallaxFactor
    readonly property real parallaxOverscan: (strip.halfVisible + 1) * strip.parallaxPx + Theme.dp(20)
    readonly property size decodeSize: Qt.size(Math.ceil((strip.cardW + strip.parallaxOverscan * 2) * Math.max(1, Screen.devicePixelRatio)), Math.ceil(strip.cardH * Math.max(1, Screen.devicePixelRatio)))
    readonly property real edgeFloor: 0.7
    readonly property real edgeRate: 0.12
    readonly property real edgeBreak: (1 - strip.edgeFloor) / strip.edgeRate
    readonly property real edgeClampedStep: strip.slotSpacing - strip.cardW * (1 - strip.edgeFloor)
    // exact visible extent of the outermost shown card: its centre offset plus
    // the half-width it is actually drawn at after the rank shrink. The
    // launcher sizes its face to this, so there is no empty side padding.
    readonly property int idealWidth: {
        var edge = strip.halfVisible;
        var edgeScale = Math.max(strip.edgeFloor, 1 - edge * strip.edgeRate);
        return Math.ceil(2 * strip.edgeOffset(edge) + strip.cardW * edgeScale);
    }

    // Magnitude of a card's x offset from the middle as a function of |rank|.
    // A plain rank * spacing opens visibly growing gaps once each card shrinks
    // around its own centre; this keeps the gap between neighbouring cards
    // constant, like Pibble's carousel.
    function edgeOffset(m) {
        if (m <= strip.edgeBreak)
            return strip.slotSpacing * m - (strip.cardW * strip.edgeRate / 2) * m * m;

        var atBreak = strip.slotSpacing * strip.edgeBreak - (strip.cardW * strip.edgeRate / 2) * strip.edgeBreak * strip.edgeBreak;
        return atBreak + strip.edgeClampedStep * (m - strip.edgeBreak);
    }

    // The unbounded animated rank. Arrow steps ease currentIndex into this;
    // a drag writes it directly so the strip follows the finger frame for
    // frame, then eases to whatever whole card the release commits to.
    property real animIndex: strip.currentIndex
    property bool dragging: false
    property bool jumping: false
    property real dragStartAnim: 0
    property real dragGrabX: 0

    Behavior on animIndex {
        enabled: !strip.dragging && !strip.jumping

        NumberAnimation {
            duration: 420
            easing.type: Easing.OutCubic
        }

    }

    onCurrentIndexChanged: {
        if (!strip.dragging)
            strip.animIndex = strip.currentIndex;

    }

    signal chosen(string path)
    signal wallpaperDeleteRequested(string path)

    function clampIndex(i) {
        if (strip.count <= 0)
            return 0;

        return Math.max(0, Math.min(strip.count - 1, i));
    }

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

    // arrow keys: one card along, and (for the styles laid out in rows) one row over
    function step(d) {
        if (strip.count <= 0)
            return;

        strip.currentIndex = strip.clampIndex(strip.currentIndex + d);
    }

    function stepVertical(d) {
    }

    function activateCurrent() {
        if (strip.count <= 0)
            return;

        var item = strip.model.get(strip.currentIndex);
        if (item) {
            var cell = cells.itemAt(strip.currentIndex);
            strip.noteOrigin(cell ? cell.cardItem : null);
            strip.chosen(item.path);
        }
    }

    // the card under the pointer if there is one, otherwise the selected card
    function deleteHighlighted() {
        if (strip.count <= 0)
            return false;

        var at = strip.hoveredIndex >= 0 && strip.hoveredIndex < strip.count ? strip.hoveredIndex : strip.currentIndex;
        if (at < 0 || at >= strip.count)
            return false;

        var item = strip.model.get(at);
        if (!item || item.path === "")
            return false;

        strip.hoveredIndex = -1;
        strip.wallpaperDeleteRequested(item.path);
        return true;
    }

    function setIndexImmediate(i) {
        if (strip.count <= 0)
            return;

        strip.jumping = true;
        strip.animIndex = strip.clampIndex(i);
        strip.currentIndex = strip.clampIndex(i);
        restoreAnim.restart();
    }

    onCountChanged: {
        if (strip.count <= 0)
            strip.currentIndex = 0;
        else if (strip.currentIndex >= strip.count)
            strip.currentIndex = strip.count - 1;
    }

    Timer {
        id: restoreAnim

        interval: 120
        onTriggered: strip.jumping = false
    }

    Item {
        id: stage

        y: strip.stageTop
        width: parent.width
        height: strip.stageH
        clip: true
        visible: strip.count > 0

        DragHandler {
            id: drag

            target: null
            xAxis.enabled: true
            yAxis.enabled: false
            enabled: strip.count > 1

            onActiveChanged: {
                if (active) {
                    strip.dragging = true;
                    strip.dragStartAnim = strip.animIndex;
                    strip.dragGrabX = centroid.position.x;
                } else {
                    var dx = centroid.position.x - strip.dragGrabX;
                    var carried = Math.abs(dx) + Math.abs(centroid.velocity.x) * 0.28;
                    var dir = dx < 0 ? 1 : -1;
                    var steps = carried >= 24 ? Math.max(1, Math.round(carried / strip.slotSpacing)) : 0;
                    strip.dragging = false;
                    strip.currentIndex = strip.clampIndex(strip.currentIndex + dir * steps);
                    strip.animIndex = strip.currentIndex;
                }
            }

            onCentroidChanged: {
                if (active) {
                    var dx = centroid.position.x - strip.dragGrabX;
                    strip.animIndex = Math.max(-0.25, Math.min(strip.count - 1 + 0.25, strip.dragStartAnim - dx / strip.slotSpacing));
                }
            }

        }

        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

            onWheel: (event) => {
                var d = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x;
                if (d !== 0)
                    strip.step(d < 0 ? 1 : -1);

            }
        }

        Repeater {
            id: cells
            model: strip.model

            delegate: Item {
                id: cell

                required property int index
                required property string path
                required property string name
                required property string thumb
                required property string preview
                required property string kind

                readonly property real rank: cell.index - strip.animIndex
                readonly property real absRank: Math.abs(cell.rank)
                readonly property bool near: cell.absRank <= strip.halfVisible + 1
                readonly property bool isCurrent: !strip.dragging && !strip.jumping && cell.index === strip.currentIndex
                readonly property real rankGrow: Math.max(strip.edgeFloor, 1 - cell.absRank * strip.edgeRate)
                readonly property real cellAlpha: cell.near ? Math.max(0, Math.min(1, strip.halfVisible + 1 - cell.absRank)) : 0
                readonly property real parallaxShift: Math.max(-strip.parallaxOverscan, Math.min(strip.parallaxOverscan, cell.rank * strip.parallaxPx))
                readonly property bool isApplied: strip.appliedPath !== "" && strip.appliedPath === cell.path
                readonly property bool hovered: hover.hovered
                readonly property bool pressed: tap.pressed && cell.hovered

                property real popScale: 1
                readonly property real growScale: cell.isCurrent ? cell.popScale : cell.rankGrow
                property Item cardItem: null

                onIsCurrentChanged: {
                    if (cell.isCurrent) {
                        cell.popScale = cell.rankGrow;
                        popIn.restart();
                    } else {
                        popIn.stop();
                        cell.popScale = 1;
                    }
                }

                NumberAnimation {
                    id: popIn
                    target: cell
                    property: "popScale"
                    to: 1
                    duration: Theme.durFastSpatial
                    easing.type: Easing.OutBack
                    easing.overshoot: 2.2
                }

                x: stage.width / 2 - width / 2 + Math.sign(cell.rank) * strip.edgeOffset(cell.absRank)
                y: (stage.height - height) / 2 + (cell.hovered ? -Theme.dp(4) : 0)
                width: strip.cardW
                height: strip.cardH
                z: -cell.absRank
                opacity: cell.cellAlpha
                visible: cell.cellAlpha > 0.01

                transform: Scale {
                    origin.x: cell.width / 2
                    origin.y: cell.height / 2
                    xScale: cell.growScale
                    yScale: cell.growScale
                }

                Behavior on y {
                    NumberAnimation {
                        duration: Theme.durShort
                        easing.type: Easing.OutCubic
                    }

                }

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.ms(180)
                    }

                }

                Loader {
                    id: cardLoader

                    anchors.fill: parent
                    active: cell.near
                    sourceComponent: cardComp
                }

                Component {
                    id: cardComp

                    SquircleClip {
                        id: card

                        anchors.fill: parent
                        radius: strip.cardCorner
                        smoothing: Prefs.squircleF
                        color: Theme.bgTile
                        opacity: (cell.isCurrent || cell.hovered || cell.absRank < 0.5) ? 1 : (cell.absRank <= 1 ? 0.78 : (cell.absRank <= 2 ? 0.5 : 0.36))
                        scale: cell.pressed ? 1 - 4 / card.width : (cell.hovered ? 1 + Theme.dp(6) / card.width : 1)

                        Component.onCompleted: cell.cardItem = card
                        Component.onDestruction: if (cell.cardItem === card) cell.cardItem = null

                        Behavior on scale {
                            NumberAnimation {
                                duration: Theme.durShort
                                easing.type: Easing.OutCubic
                            }

                        }

                        Behavior on opacity {
                            NumberAnimation {
                                duration: Theme.ms(180)
                            }

                        }

                        // wider than the card and panned opposite the strip, so
                        // the visible crop drifts slower than the frame. The
                        // still and the live preview share the box.
                        WallpaperCardMedia {
                            anchors.fill: parent
                            path: cell.path
                            thumb: cell.thumb
                            preview: cell.preview
                            kind: cell.kind
                            active: cell.isCurrent || cell.hovered
                            overscan: strip.parallaxOverscan
                            parallax: cell.parallaxShift
                            sourceSizeWidth: strip.decodeSize.width
                            sourceSizeHeight: strip.decodeSize.height
                        }

                        Rectangle {
                            anchors.fill: parent
                            color: Theme.text
                            opacity: cell.pressed ? Theme.statePressed : (cell.hovered ? Theme.stateHover : 0)

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: Theme.durShort
                                }

                            }

                        }

                        // the wallpaper actually on the desktop
                        Rectangle {
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.dp(10)
                            width: Theme.dp(26)
                            height: Theme.dp(26)
                            radius: width / 2
                            color: Theme.accent
                            scale: cell.isApplied ? 1 : 0.4
                            opacity: cell.isApplied ? 1 : 0
                            visible: opacity > 0.01

                            Behavior on scale {
                                NumberAnimation {
                                    duration: Theme.durFastSpatial
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: Theme.curveDefaultSpatial
                                }

                            }

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: Theme.durShort
                                }

                            }

                            DockGlyph {
                                anchors.centerIn: parent
                                width: Theme.dp(15)
                                height: Theme.dp(15)
                                pathData: DockIcons.check
                                glyphColor: Theme.fgAccent
                            }

                        }

                    }

                }

                HoverHandler {
                    id: hover

                    enabled: cell.near
                    cursorShape: Qt.PointingHandCursor
                }

                onHoveredChanged: {
                    if (cell.hovered)
                        strip.hoveredIndex = cell.index;
                    else if (strip.hoveredIndex === cell.index)
                        strip.hoveredIndex = -1;

                }

                TapHandler {
                    id: tap

                    enabled: cell.near

                    onTapped: {
                        if (cell.isCurrent) {
                            strip.noteOrigin(cell.cardItem);
                            strip.chosen(cell.path);
                        } else {
                            strip.currentIndex = cell.index;
                        }
                    }
                }

            }

        }

    }

    Item {
        id: caption

        anchors.top: stage.bottom
        anchors.topMargin: Theme.dp(8)
        anchors.left: parent.left
        anchors.right: parent.right
        height: Theme.dp(26)
        visible: stage.visible

        Row {
            id: capRow

            readonly property int at: strip.hoveredIndex >= 0 ? strip.hoveredIndex : strip.currentIndex
            readonly property var entry: strip.model && capRow.at >= 0 && capRow.at < strip.model.count ? strip.model.get(capRow.at) : null

            anchors.centerIn: parent
            spacing: Theme.dp(10)

            LText {
                id: capName

                anchors.verticalCenter: parent.verticalCenter
                role: "titleSmall"
                text: capRow.entry ? capRow.entry.name : ""
                color: Theme.text
                elide: Text.ElideRight
                width: Math.min(capMetrics.width + Theme.dp(2), Math.max(0, strip.width - Theme.dp(220)))

                TextMetrics {
                    id: capMetrics

                    font: capName.font
                    text: capName.text
                }

            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: appliedLabel.implicitWidth + Theme.dp(16)
                height: Theme.dp(22)
                radius: Theme.shapeFull
                color: Theme.accent
                visible: capRow.entry !== null && strip.appliedPath !== "" && strip.appliedPath === capRow.entry.path

                LText {
                    id: appliedLabel

                    anchors.centerIn: parent
                    role: "labelSmall"
                    text: "Active"
                    color: Theme.fgAccent
                }

            }

            LText {
                anchors.verticalCenter: parent.verticalCenter
                role: "labelMedium"
                tabular: true
                text: strip.count > 0 ? (capRow.at + 1) + " / " + strip.count : ""
                color: Theme.subtextDim
            }

        }

    }

    Column {
        id: emptyState

        anchors.top: parent.top
        anchors.topMargin: Math.max(0, (strip.stableHeight - emptyState.implicitHeight) / 2)
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Theme.dp(12)
        visible: strip.count === 0

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Theme.dp(58)
            height: Theme.dp(58)
            radius: Theme.shapeXl
            color: Theme.withBlur(Theme.surfaceHigh)

            Icon {
                anchors.centerIn: parent
                name: strip.live ? "movie" : "wallpaper"
                size: Theme.dp(28)
                color: Theme.primary
            }

        }

        LText {
            anchors.horizontalCenter: parent.horizontalCenter
            role: "titleMedium"
            text: strip.live ? "No videos in this folder" : "No wallpapers in this folder"
            color: Theme.text
        }

        LText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: strip.filterText !== "" ? "No wallpapers match \"" + strip.filterText + "\"" : (strip.live ? "Drop mp4, webm or mkv files into the theme's wallpaper folder and they show up here." : "Drop images into the theme's wallpaper folder and they show up here.")
            role: "bodyMedium"
            color: Theme.subtextDim
        }

    }

}
