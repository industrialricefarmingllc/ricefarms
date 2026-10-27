import QtQuick
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Widgets
import qs
import qs.lucidui
import "../squircle"

// Pibble's apps page, wearing the launcher's own metrics: a paged 4x3 wall of
// app tiles that springs in as a staggered cascade and marks the keyboard
// selection with the accent-container tint. Paging and the arrow walk are
// pibble's too (see LauncherState.vMove / pageJump there), so the grid moves
// the way the grid it came from does.
Item {
    id: root

    property var model: null
    // emoji rows use the same wall and paging, with a glyph instead of an icon
    property bool emojiMode: false
    property int currentIndex: 0
    // true only while the wall is actually on screen (the panel body is open
    // and the Apps view is showing). Cells fill silently while it is false, so
    // the one visible cascade is the entrance below rather than a wave that
    // already played behind a closed panel.
    property bool active: false
    // bumped by the face whenever the dock rewrites its rows. These cells are
    // not a view's delegates, so model.get() needs a dependency to re-evaluate
    // when rows are replaced in place (same key, new title/icon).
    property int revision: 0
    // bumped to replay the entrance wave: the launcher opening, or the grid
    // coming back when the query is cleared
    property int entrance: 0

    // pibble's grid, with four rows so the wall fills the launcher body
    readonly property int cols: 4
    readonly property int rows: 4
    readonly property int pageSize: cols * rows
    readonly property int count: model ? model.count : 0
    readonly property int pageCount: pageSize > 0 ? Math.ceil(count / pageSize) : 0
    readonly property int page: pageSize > 0 ? Math.floor(Math.max(0, currentIndex) / pageSize) : 0
    readonly property int pageStart: page * pageSize

    // pibble's drawer geometry, narrowed to the launcher's content width. The
    // 174px tile is 21% of its 820px launcher; four tiles across a 336px face
    // land on the same proportion, and everything inside scales with the tile.
    readonly property real cs: Prefs.launcherScale
    // item contents are sized against the four-column tile by this factor;
    // the caption keeps its own (unscaled) size
    readonly property real itemScale: 1.0
    readonly property real padX: Theme.dp(8)
    readonly property real gap: Theme.dp(18)
    // the fourth row gets the vertical room; gaps stay generous rather than
    // stretching the tiles to fill every pixel
    readonly property real padY: Theme.dp(8)
    readonly property real rowGap: Theme.dp(12)
    readonly property real tileW: {
        // rows stay fixed; on a short panel shrink the tiles rather than
        // clipping the last row (a large scale or the external launcher's
        // golden-ratio top margin can both leave less height than the grid's
        // natural one)
        var byWidth = Math.max(1, (root.width - 2 * root.padX - (root.cols - 1) * root.gap) / root.cols);
        var avail = root.height - 2 * root.padY - (root.rows - 1) * root.rowGap;
        if (avail <= 0)
            return byWidth;

        var byHeight = (avail / root.rows - root.fixedH) / (0.44 * root.itemScale);
        return Math.max(1, Math.min(byWidth, byHeight));
    }
    readonly property real iconBox: Math.round(tileW * 0.44 * itemScale)
    readonly property real iconSize: Math.round(iconBox * 0.58)
    readonly property int captionSize: Math.max(9, Math.round(Theme.typeSize("bodyMedium") * cs))
    readonly property real captionH: Math.max(Math.round(13 * cs * itemScale), Math.round(captionSize * 1.25))
    readonly property real fixedH: Math.round(8 * cs * itemScale) + captionH
    readonly property real tileH: iconBox + fixedH
    readonly property real gridH: rows * tileH + (rows - 1) * rowGap
    // what the dock sizes the panel to while this is the whole content, from
    // the width alone so it can't feed back into the height it is measuring
    readonly property real naturalHeight: rows * (Math.round(Math.max(1, (width - 2 * padX - (cols - 1) * gap) / cols) * 0.44 * itemScale) + fixedH) + (rows - 1) * rowGap + 2 * padY
    // the height the drawer actually takes once the panel has had its say
    readonly property real laidOutHeight: gridH + 2 * padY

    signal activated(int index)

    implicitHeight: naturalHeight

    // pibble walks the grid with the wheel, one row at a time (see its
    // backdrop wheel handler), so pages come round at the same point the
    // keyboard's Down does.
    WheelHandler {
        property real acc: 0

        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: (event) => {
            event.accepted = true;
            acc += event.angleDelta.y;
            while (acc >= 120) {
                root.stepVertical(-1);
                acc -= 120;
            }
            while (acc <= -120) {
                root.stepVertical(1);
                acc += 120;
            }
        }
    }

    onCountChanged: {
        if (currentIndex >= count)
            currentIndex = Math.max(0, count - 1);
    }
    onActiveChanged: {
        if (active)
            playEntrance();
    }
    Component.onCompleted: {
        if (active)
            playEntrance();
    }

    function playEntrance() {
        if (!root.active || entranceGuard.running)
            return ;

        // one entrance per time the wall becomes the visible content; the
        // guard folds together the active/head-only notifications that arrive
        // in the same frame
        entranceGuard.restart();
        drawerEnter.restart();
        entrance++;
    }

    Timer {
        id: entranceGuard

        interval: 80
    }

    function resetSelection() {
        currentIndex = 0;
    }

    function stepHorizontal(dir) {
        if (count === 0)
            return ;
        currentIndex = ((currentIndex + dir) % count + count) % count;
    }

    function stepVertical(dir) {
        if (count === 0)
            return ;
        currentIndex = root.vMove(currentIndex, count, cols, rows, dir);
    }

    // pibble's walk: down a column through every page, then to the top of the
    // next column; up mirrors it.
    function vMove(sel, total, cols, rows, dir) {
        if (!total)
            return 0;

        const page = cols * rows;
        const p = Math.floor(sel / page);
        const w = sel % page;
        const r = Math.floor(w / cols);
        const c = w % cols;
        const pages = Math.ceil(total / page);
        if (dir > 0) {
            const idx = r < rows - 1 ? sel + cols : (p + 1) * page + c;
            if (idx < total)
                return idx;

            const nc = c + 1;
            return (nc < cols && nc < total) ? nc : 0;
        } else {
            if (r > 0)
                return sel - cols;

            if (p > 0)
                return (p - 1) * page + (rows - 1) * cols + c;

            const nc = c > 0 ? c - 1 : cols - 1;
            for (let pp = pages - 1; pp >= 0; pp--) {
                for (let rr = rows - 1; rr >= 0; rr--) {
                    const idx = pp * page + rr * cols + nc;
                    if (idx < total)
                        return idx;
                }
            }
            return total - 1;
        }
    }

    function pageMove(dir) {
        if (!count || pageSize <= 0)
            return ;

        const pages = Math.ceil(count / pageSize);
        if (pages <= 1)
            return ;

        const w = currentIndex % pageSize;
        const cur = Math.floor(currentIndex / pageSize);
        const next = ((cur + dir) % pages + pages) % pages;
        currentIndex = Math.min(count - 1, next * pageSize + w);
    }

    function activateCurrent() {
        if (currentIndex >= 0 && currentIndex < count)
            activated(currentIndex);

    }

    Item {
        id: drawer

        anchors.centerIn: parent
        width: root.width
        height: root.laidOutHeight
        transformOrigin: Item.Center

        // pibble's pane entrance: the drawer settles up into place from just
        // below, springing over its final few pixels
        ParallelAnimation {
            id: drawerEnter

            NumberAnimation {
                target: drawer
                property: "opacity"
                from: 0
                to: 1
                duration: Theme.ms(200)
                easing.type: Easing.OutCubic
            }

            NumberAnimation {
                target: drawer
                property: "scale"
                from: 0.9
                to: 1
                duration: Theme.ms(500)
                easing.type: Easing.OutBack
                easing.overshoot: 1.8
            }

            NumberAnimation {
                target: drawer
                property: "anchors.verticalCenterOffset"
                from: 40
                to: 0
                duration: Theme.ms(500)
                easing.type: Easing.OutBack
                easing.overshoot: 1.8
            }

        }

        Grid {
            id: tileGrid

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            columns: root.cols
            columnSpacing: root.gap
            rowSpacing: root.rowGap

            Repeater {
                id: gridRepeater

                model: root.pageSize

                Item {
                    id: cell

                    required property int index
                    readonly property int appIndex: root.pageStart + cell.index
                    property var entry: {
                        root.revision;
                        root.page;
                        if (!root.model || cell.appIndex >= root.model.count)
                            return null;

                        return root.model.get(cell.appIndex);
                    }
                    property var shownEntry: null
                    property bool filled: false
                    readonly property bool isSelected: cell.filled && root.currentIndex === cell.appIndex

                    width: root.tileW
                    height: root.tileH

                    // pibble's slot rebinding: a page turn hands a filled slot a
                    // different app and the tile stays put. A slot that fills
                    // while the wall is on screen springs in; one that fills
                    // while it is closed waits for the entrance wave instead.
                    onEntryChanged: {
                        if (entry) {
                            const wasFilled = filled;
                            const isNew = !wasFilled || !shownEntry || shownEntry.key !== entry.key;
                            shownEntry = entry;
                            filled = true;
                            if (isNew) {
                                springIn.stop();
                                springOut.stop();
                                if (wasFilled || !root.active) {
                                    wrap.opacity = 1;
                                    wrap.scale = 1;
                                    wrap.anchors.verticalCenterOffset = 0;
                                } else {
                                    springIn.restart();
                                }
                            }
                        } else if (filled) {
                            filled = false;
                            springIn.stop();
                            springOut.stop();
                            if (root.active)
                                springOut.restart();
                            else
                                wrap.opacity = 0;
                        }
                    }
                    Connections {
                        target: root

                        function onEntranceChanged() {
                            if (cell.filled)
                                springIn.restart();

                        }
                    }

                    Column {
                        id: wrap

                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.tileW
                        spacing: Math.round(8 * root.cs * root.itemScale)
                        opacity: 0

                        Item {
                            id: iconBox

                            anchors.horizontalCenter: parent.horizontalCenter
                            width: root.iconBox
                            height: root.iconBox

                            // The plate is full-size; the icon is drawn at
                            // 100% and cropped to that circle.
                            SquircleRect {
                                anchors.fill: parent
                                anchors.margins: -Theme.dp(3)
                                fillColor: "transparent"
                                borderColor: Theme.accent
                                borderWidth: cell.isSelected ? Theme.dp(2) : 0
                                radius: width / 2
                                smoothing: Prefs.squircleF
                                visible: cell.isSelected
                            }

                            SquircleRect {
                                id: iconPlate

                                anchors.fill: parent
                                radius: width / 2
                                fillColor: Theme.isLightMode ? "#ffffff" : "#000000"
                                borderColor: Theme.isLightMode ? "#ffffff" : "#000000"
                                borderWidth: Theme.dp(2)
                                smoothing: Prefs.squircleF
                            }

                            Image {
                                id: appIcon

                                anchors.fill: parent
                                asynchronous: true
                                cache: true
                                // Decode above the drawn size so the surface's
                                // 1.35x reveal scale (and any HiDPI factor)
                                // never upsamples a tiny pixmap.
                                sourceSize.width: Math.max(64, Math.ceil(width * 4))
                                sourceSize.height: Math.max(64, Math.ceil(height * 4))
                                // Smooth/downsample rather than nearest-neighbour.
                                smooth: true
                                mipmap: true
                                fillMode: Image.PreserveAspectCrop
                                source: {
                                    IconTheme.generation;
                                    if (root.emojiMode || !cell.shownEntry || cell.shownEntry.iconName === "")
                                        return "";

                                    const hit = IconTheme.pathFor(cell.shownEntry.iconName);
                                    return hit !== "" ? hit : Quickshell.iconPath(cell.shownEntry.iconName, true);
                                }
                                visible: status === Image.Ready
                                layer.enabled: visible
                                // Mask in a supersampled layer, otherwise the
                                // mask is baked at 1x and the face scale blurs
                                // the icon back down again.
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

                            Text {
                                anchors.centerIn: parent
                                visible: root.emojiMode
                                text: cell.shownEntry ? cell.shownEntry.emoji : ""
                                color: Theme.text
                                font.family: "Noto Color Emoji"
                                font.pixelSize: Math.round(root.iconBox * 0.58)
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }

                            LText {
                                anchors.centerIn: parent
                                visible: !root.emojiMode && appIcon.status !== Image.Ready
                                text: cell.shownEntry ? cell.shownEntry.title.slice(0, 2).toUpperCase() : ""
                                color: Theme.isLightMode ? "#000000" : "#ffffff"
                                role: "labelLarge"
                                size: Math.round(root.iconSize * 0.52)
                                horizontalAlignment: Text.AlignHCenter
                            }

                            TapHandler {
                                enabled: cell.filled
                                onTapped: {
                                    root.currentIndex = cell.appIndex;
                                    root.activated(cell.appIndex);
                                }
                            }

                        }

                        LText {
                            width: parent.width
                            text: cell.shownEntry ? cell.shownEntry.title : ""
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                            color: Theme.text
                            role: "bodyMedium"
                            size: root.captionSize
                        }

                    }

                    // bloom: stagger the cascade, spring each tile out of a
                    // smaller, lower state, and let the overshoot carry it
                    SequentialAnimation {
                        id: springIn

                        PropertyAction {
                            target: wrap
                            property: "opacity"
                            value: 0
                        }

                        PropertyAction {
                            target: wrap
                            property: "scale"
                            value: 0.4
                        }

                        PropertyAction {
                            target: wrap
                            property: "anchors.verticalCenterOffset"
                            value: 14
                        }

                        PauseAnimation {
                            duration: cell.index * 35
                        }

                        ParallelAnimation {
                            NumberAnimation {
                                target: wrap
                                property: "opacity"
                                to: 1
                                duration: Theme.ms(180)
                                easing.type: Easing.OutCubic
                            }

                            NumberAnimation {
                                target: wrap
                                property: "scale"
                                to: 1
                                duration: Theme.ms(400)
                                easing.type: Easing.OutBack
                                easing.overshoot: 2.2
                            }

                            NumberAnimation {
                                target: wrap
                                property: "anchors.verticalCenterOffset"
                                to: 0
                                duration: Theme.ms(400)
                                easing.type: Easing.OutBack
                                easing.overshoot: 2.2
                            }

                        }

                    }

                    // and the exit mirrors it: a short outward bounce, then back
                    // toward the same state it entered from
                    SequentialAnimation {
                        id: springOut

                        ParallelAnimation {
                            NumberAnimation {
                                target: wrap
                                property: "scale"
                                to: 1.08
                                duration: Theme.ms(80)
                                easing.type: Easing.OutQuad
                            }

                        }

                        ParallelAnimation {
                            NumberAnimation {
                                target: wrap
                                property: "scale"
                                to: 0.4
                                duration: Theme.ms(320)
                                easing.type: Easing.InQuad
                            }

                            NumberAnimation {
                                target: wrap
                                property: "opacity"
                                to: 0
                                duration: Theme.ms(320)
                                easing.type: Easing.InQuad
                            }

                        }

                    }

                }

            }

        }

    }

    LText {
        anchors.centerIn: parent
        visible: root.count === 0
        text: "No apps found"
        role: "bodyMedium"
        color: Theme.subtext
    }

}
