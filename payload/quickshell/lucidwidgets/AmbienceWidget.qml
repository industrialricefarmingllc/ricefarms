import QtQuick
import QtQuick.Shapes
import Quickshell
import qs
import qs.lucidui
import "../squircle"
import "../lucidui/Shapes.js" as Shapes

// A soundtrack for the wallpaper under this card. The list lives in the
// Ambience singleton and follows wallpaper changes on its own; this card is a
// status face and a manager, never a transport.
//
// The frame makes the container transparent while liquid glass is drawn behind
// it, and uses the body's normal surface fill otherwise. Every label sits on an
// opaque surface panel instead, so contrast never depends on the wallpaper or
// the glass behind it.
WidgetBody {
    id: w

    defaultTone: "surface"

    readonly property color panelFill: Theme.surfaceContainer
    readonly property color chipFill: Theme.surfaceHighest
    readonly property color panelInk: Theme.text
    readonly property color panelSoft: Theme.subtext

    readonly property bool panel: w.variant === "panel"
    readonly property bool compact: w.variant === "row"
    readonly property bool discVariant: w.variant === "disc"
    readonly property bool quarter: w.variant === "quarter"
    readonly property bool playing: w.preview ? true : Ambience.playing
    readonly property bool preparing: w.preview ? false : Ambience.preparing
    readonly property int audible: w.preview ? w.trackCount : Ambience.audible
    readonly property string errorText: w.preview ? "" : Ambience.error
    readonly property var sampleTracks: [{
        "id": "sample1",
        "url": "",
        "title": "Rain on the window"
    }, {
        "id": "sample2",
        "url": "",
        "title": "Late night drive"
    }, {
        "id": "sample3",
        "url": "",
        "title": "Quiet café"
    }]
    readonly property var tracks: w.preview ? w.sampleTracks : Ambience.tracks
    readonly property int trackCount: w.tracks.length
    readonly property string nowTitle: {
        if (w.trackCount === 0)
            return w.preview ? "Rain on the window" : "Nothing queued";

        if (w.preparing)
            return "Preparing " + w.trackCount + (w.trackCount === 1 ? " track" : " tracks");

        if (w.trackCount === 1)
            return "1 track playing";

        return w.trackCount + " tracks playing together";
    }
    readonly property string wallpaperLine: "for " + Ambience.wallpaperName
    readonly property string volumeRange: {
        if (w.trackCount === 0)
            return Ambience.volume + "%";

        var lo = 100;
        var hi = 0;
        for (var i = 0; i < w.trackCount; i++) {
            var v = (typeof w.tracks[i].volume === "number") ? w.tracks[i].volume : Ambience.volume;
            lo = Math.min(lo, v);
            hi = Math.max(hi, v);
        }
        return lo === hi ? (lo + "%") : (lo + "–" + hi + "%");
    }
    readonly property string nowSub: {
        if (w.trackCount === 0)
            return "No soundtrack for this wallpaper";

        if (w.errorText !== "")
            return w.errorText;

        if (w.preparing)
            return "Fetching every track · volumes " + w.volumeRange;

        var layers = w.audible < w.trackCount ? (w.audible + " of " + w.trackCount + " layered") : (w.trackCount === 1 ? "1 layer" : w.trackCount + " layers");
        return layers + " · volumes " + w.volumeRange + " · looping";
    }
    // while a row is held, its fill follows the pointer before the store is written
    property var dragVolumes: ({})
    // a mode change briefly replaces the track name with the filter's label
    property var seenModes: ({})
    property string modeFlashUrl: ""
    property string modeFlashLabel: ""
    // a preset is saved from the current list or merged back into it
    property bool presetOpen: false
    property bool presetSaved: false
    property bool presetNaming: false
    property string presetNameDraft: ""

    // the running order opens as its own screen over the face, like the Social
    // card's source sheet
    property bool manageOpen: false
    readonly property bool manageCompact: w.width < Theme.dp(300) || w.height < Theme.dp(220)
    readonly property real managePad: w.manageCompact ? Theme.dp(10) : Theme.dp(15)
    readonly property real manageHeaderH: w.manageCompact ? Theme.dp(28) : Theme.dp(32)
    readonly property real manageRowH: w.height < Theme.dp(150) ? Theme.dp(24) : (w.manageCompact ? Theme.dp(30) : Theme.dp(38))
    readonly property real manageFieldH: w.manageCompact ? Theme.dp(34) : Theme.dp(42)
    // drives the little equaliser and the record; a clock for every face
    // Kept as a constant: the timer that advanced it was removed so the card
    // never repaints on its own. Bindings that read it stay at phase 0.
    readonly property real pulse: 0

    onVariantChanged: {
        w.closeManage();
        w.closePresetLoad();
        w.cancelPresetName();
    }

    function openManage() {
        if (w.preview)
            return ;

        w.closePresetLoad();
        Ambience.clearError();
        w.manageOpen = true;
        Qt.callLater(function () {
            if (w.manageOpen && manageLoader.item && typeof manageLoader.item.focusField === "function")
                manageLoader.item.focusField();

        });
    }

    function closeManage() {
        if (!w.manageOpen)
            return ;

        w.manageOpen = false;
        Ambience.clearError();
        w.endEdit();
        if (manageLoader.item && typeof manageLoader.item.clearField === "function")
            manageLoader.item.clearField();

    }

    function commitPresetName() {
        if (!w.presetNaming || w.preview)
            return ;

        var name = w.presetNameDraft.trim();
        if (name === "")
            name = "Preset " + (Ambience.presets.length + 1);

        Ambience.savePreset(name);
        w.presetNaming = false;
        w.presetNameDraft = "";
        w.presetSaved = true;
        w.endEdit();
        presetSavedTimer.restart();
    }

    function cancelPresetName() {
        w.presetNaming = false;
        w.presetNameDraft = "";
        w.endEdit();
    }

    function openPresetLoad() {
        if (!w.preview)
            w.presetOpen = true;

    }

    function closePresetLoad() {
        w.presetOpen = false;
    }

    function loadPreset(id) {
        if (w.preview)
            return ;

        Ambience.loadPreset(id);
        w.presetOpen = false;
    }

    Timer {
        id: presetSavedTimer

        interval: 1600
        onTriggered: w.presetSaved = false
    }

    function addLinkFrom(field) {
        if (w.preview || !field)
            return ;

        if (field.text.trim() === "")
            return ;

        if (Ambience.addTrack(field.text))
            field.text = "";

    }

    function rowVolume(track) {
        if (!track)
            return Ambience.volume;

        var draft = w.dragVolumes[track.url];
        if (draft !== undefined)
            return draft;

        return (typeof track.volume === "number") ? track.volume : Ambience.volume;
    }

    function trackMode(track) {
        return Ambience.modeInfo(track ? track.mode : "dry");
    }

    function cycleModeAt(view, index) {
        if (w.preview)
            return ;

        // replacing the library resets the list model, so keep the viewport
        var keep = view ? view.contentY : 0;
        // read the next mode from the store, not the delegate: during a quick
        // run of clicks the row's model data can still be one step behind
        Ambience.cycleMode(index);
        Qt.callLater(function () {
            if (view)
                view.contentY = keep;

        });
    }

    function dragVolume(index, track, px, width) {
        if (!track || width <= 0)
            return 0;

        var v = Math.max(0, Math.min(100, Math.round(px / width * 100)));
        var d = Object.assign({}, w.dragVolumes);
        d[track.url] = v;
        w.dragVolumes = d;
        if (!w.preview)
            Ambience.setVolumeLive(index, v);

        return v;
    }

    function commitVolume(index, track, px, width) {
        var v = w.dragVolume(index, track, px, width);
        if (!w.preview)
            Ambience.setTrackVolume(index, v);

        var d = Object.assign({}, w.dragVolumes);
        delete d[track.url];
        w.dragVolumes = d;
    }

    function commitVolumeAt(view, index, track, px, width) {
        var keep = view ? view.contentY : 0;
        w.commitVolume(index, track, px, width);
        Qt.callLater(function () {
            if (view)
                view.contentY = keep;

        });
    }

    // watch the library rather than the row click: this also catches a mode
    // changed through the ambience ipc
    function noteModes(flash) {
        if (w.preview)
            return ;

        var list = Ambience.library[Ambience.wallpaperKey];
        if (!Array.isArray(list))
            list = [];

        var seen = {};
        var changedUrl = "";
        var changedLabel = "";
        for (var i = 0; i < list.length; i++) {
            var t = list[i];
            var mode = Ambience.modeInfo(t.mode);
            seen[t.url] = mode.id;
            if (flash !== false && w.seenModes[t.url] !== undefined && w.seenModes[t.url] !== mode.id) {
                changedUrl = t.url;
                changedLabel = mode.label;
            }
        }
        w.seenModes = seen;
        if (changedUrl !== "") {
            w.modeFlashUrl = changedUrl;
            w.modeFlashLabel = changedLabel;
            modeFlashTimer.restart();
        }
    }

    Connections {
        function onLibraryChanged() {
            w.noteModes(true);
        }

        function onWallpaperKeyChanged() {
            w.seenModes = ({});
            w.noteModes(false);
        }

        target: Ambience
    }

    Timer {
        id: modeFlashTimer

        interval: 2000
        onTriggered: {
            w.modeFlashUrl = "";
            w.modeFlashLabel = "";
        }
    }

    // The 140 ms pulse was the last thing still repainting this card: it
    // advanced w.pulse at 7 Hz so the decorative bars and the preview wave
    // moved. It is gone, so those bindings now sit at their t=0 phase. This
    // timer dirties the fullscreen widget layer on every output the card is
    // placed on, which is the cost we are removing.

    // ---- shared pieces -----------------------------------------------------

    component Header: SquircleRect {
        id: head

        property bool wallpaper: false
        property bool showAdd: true
        property bool compact: false

        implicitHeight: head.compact ? Theme.dp(28) : Theme.dp(32)
        radius: height / 2
        fillColor: w.panelFill
        smoothing: Prefs.squircleF

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.dp(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(7)

            WidgetGlyph {
                anchors.verticalCenter: parent.verticalCenter
                name: "ambience"
                size: head.compact ? Theme.dp(15) : Theme.dp(17)
                color: Theme.primary
            }

            LText {
                anchors.verticalCenter: parent.verticalCenter
                role: head.compact ? "labelMedium" : "labelLarge"
                color: w.panelInk
                text: Tr.t("Ambience")
            }

            LText {
                visible: head.wallpaper
                anchors.verticalCenter: parent.verticalCenter
                role: "labelSmall"
                color: w.panelSoft
                text: w.wallpaperLine
                elide: Text.ElideRight
                width: Math.min(implicitWidth, Theme.dp(150))
            }

        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(6)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(4)

            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                icon: "add"
                size: "xs"
                visible: head.showAdd && !w.preview
                tintOverride: w.panelInk
                onClicked: w.openManage()
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: volRow.implicitWidth + Theme.dp(12)
                height: Theme.dp(22)
                radius: height / 2
                color: w.chipFill

                Row {
                    id: volRow

                    anchors.centerIn: parent
                    spacing: Theme.dp(3)

                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "volume_up"
                        size: Theme.dp(13)
                        color: w.panelInk
                    }

                    LText {
                        anchors.verticalCenter: parent.verticalCenter
                        role: "labelSmall"
                        color: w.panelInk
                        text: w.volumeRange
                        tabular: true
                    }

                }

            }

        }

    }

    // a record that keeps turning while the wallpaper has a voice
    component Disc: Item {
        id: d

        property real diameter: Theme.dp(124)
        property bool spinning: w.playing
        // only the visible copy on the card's own screen asks cava for bands
        property bool active: false
        property string demandKey: ""
        readonly property int bands: 32
        readonly property real audioSize: d.width * 0.72
        property var levelsCache: []
        property int tick: 0
        // a second circle behind the middle shape: the loading-indicator
        // silhouette, but its edge is the actual output's spectrum
        readonly property var audioRadii: {
            var _ = d.tick;
            var base = Shapes.radii("circle");
            var n = base.length;
            var out = [];
            for (var i = 0; i < n; i++) out.push(base[i] * 0.75 * (1 + d.levelAt(i, n) * 0.3))
            return out;
        }
        readonly property string audioPath: Shapes.svg(d.audioRadii, d.audioSize, 0)

        implicitWidth: d.diameter
        implicitHeight: d.diameter
        width: d.diameter
        height: d.diameter

        function wantBands() {
            // The spectrum silhouette is gone, so this card no longer needs a
            // cava process. Keep the function so existing callers stay valid.
            return ;
        }

        function dropBands() {
            if (d.demandKey !== "")
                Cava.drop(d.demandKey);

        }

        // actual output levels, folded from cava's bands onto the shape's
        // samples; preview tiles use a sample wave because they are silent
        function levelAt(i, count) {
            if (w.preview)
                return 0.08 + 0.22 * Math.abs(Math.sin(w.pulse * 1.1 + i / Math.max(1, count) * Math.PI * 4));

            if (!d.active)
                return 0;

            var src = d.levelsCache;
            var n = src.length;
            if (n === 0)
                return 0;

            if (n === count)
                return src[i];

            var from = Math.floor(i * n / count);
            var to = Math.min(n - 1, Math.max(from, Math.floor((i + 1) * n / count) - 1));
            var peak = 0;
            for (var k = from; k <= to; k++) peak = Math.max(peak, src[k])
            return peak;
        }

        onActiveChanged: d.active ? d.wantBands() : d.dropBands()
        onDemandKeyChanged: {
            d.dropBands();
            d.wantBands();
        }
        Component.onCompleted: d.wantBands()
        Component.onDestruction: d.dropBands()

        // The 40 ms tick that fed the spectrum silhouette is gone with it.
        // This was the last per-frame path in the card: while cava had levels
        // it rebuilt audioRadii -> audioPath -> the Shape 25 times a second.

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Theme.surfaceHigh
            border.width: 1
            border.color: Theme.outline
        }

        Repeater {
            model: 3

            Rectangle {
                anchors.centerIn: parent
                width: d.width * (0.7 - index * 0.16)
                height: width
                radius: width / 2
                color: "transparent"
                border.width: 1
                border.color: Theme.outline
            }

        }

        Item {
            id: dots

            anchors.fill: parent

            Repeater {
                model: 8

                Rectangle {
                    width: Math.max(2, d.width * 0.018)
                    height: width
                    radius: width / 2
                    color: index % 3 === 0 ? Theme.primary : Theme.text
                    x: dots.width / 2 + Math.cos(index * Math.PI / 4) * dots.width * 0.33 - width / 2
                    y: dots.height / 2 + Math.sin(index * Math.PI / 4) * dots.height * 0.33 - height / 2
                }

            }

            // No idle rotation. A 28 s turn moves ~0.2° per frame, so it
            // re-rendered this card (and therefore the whole lucid-widgets
            // surface) on every frame while audio played. Measured: a small
            // surface and a fullscreen one cost the same, so the damage rate,
            // not the surface size, is what has to go. The disc stays still.

        }

        // The spectrum silhouette lived here. It was a Shape with a 4x MSAA
        // layer whose PathSvg was rebuilt from cava's levels; both it and the
        // 40 ms tick that drove it are removed so the card never repaints
        // itself. Track title, state and controls are untouched.

        MaterialShape {
            id: label

            anchors.centerIn: parent
            width: d.width * 0.36
            height: width
            shape: "cookie9"
            to: "circle"
            morph: w.playing ? 1 : 0
            color: Theme.primary

            Behavior on morph {
                NumberAnimation {
                    duration: Theme.durDefaultSpatial
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveDefaultSpatial
                }

            }

        }

        Icon {
            anchors.centerIn: parent
            name: "graphic_eq"
            size: d.width * 0.15
            fill: 1
            color: Theme.fgPrimary
        }

    }

    component Bars: Item {
        id: bars

        property color tint: Theme.primary

        width: Theme.dp(18)
        height: Theme.dp(16)

        Row {
            anchors.centerIn: parent
            spacing: Theme.dp(2)

            Repeater {
                model: 3

                Item {
                    width: Theme.dp(3)
                    height: bars.height

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: Math.max(Theme.dp(3), bars.height * (0.22 + 0.72 * Math.abs(Math.sin(w.pulse * 1.4 + index * 1.7))))
                        radius: width / 2
                        color: bars.tint

                        Behavior on height {
                            NumberAnimation {
                                duration: 120
                                easing.type: Easing.OutCubic
                            }

                        }

                    }

                }

            }

        }

    }

    // the primary fill of a track row: its width is that track's volume
    component VolumeFill: SquircleRect {
        id: fill

        property real fraction: 0
        property real corner: 0

        width: Math.max(0, parent.width * Math.max(0, Math.min(1, fill.fraction)))
        height: parent.height
        radius: 0
        topLeftRadius: fill.corner
        bottomLeftRadius: fill.corner
        topRightRadius: fill.fraction >= 0.995 ? fill.corner : 0
        bottomRightRadius: fill.fraction >= 0.995 ? fill.corner : 0
        fillColor: Theme.primaryContainer
        smoothing: Prefs.squircleF
    }

    // the two preset actions sit after the last track, inside the list
    component PresetFooter: Item {
        id: footer

        property real viewWidth: 0

        function startNaming() {
            if (w.preview || w.trackCount === 0)
                return ;

            w.presetNameDraft = "Preset " + (Ambience.presets.length + 1);
            w.presetNaming = true;
            Qt.callLater(function () {
                nameField.text = w.presetNameDraft;
                nameField.focusField();
                nameField.input.selectAll();
            });
        }

        width: footer.viewWidth
        height: footer.visible ? Theme.dp(42) : 0
        // with no rows the empty screen carries its own Load button
        visible: w.trackCount > 0

        Row {
            anchors.centerIn: parent
            spacing: Theme.dp(6)
            visible: !w.presetNaming

            Button {
                text: w.presetSaved ? Tr.t("Saved") : (w.manageCompact ? Tr.t("Save") : Tr.t("Save preset"))
                variant: "tonal"
                size: "xs"
                icon: w.manageCompact ? "" : "bookmark_add"
                enabled: w.trackCount > 0
                onClicked: footer.startNaming()
            }

            Button {
                text: w.manageCompact ? Tr.t("Load") : Tr.t("Load preset")
                variant: "outlined"
                size: "xs"
                icon: w.manageCompact ? "" : "folder_open"
                onClicked: w.openPresetLoad()
            }

        }

        LinkField {
            id: nameField

            visible: w.presetNaming
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            fieldH: Theme.dp(34)
            compact: true
            placeholder: Tr.t("Preset name…")
            actionIcon: "check"
            onAddRequested: w.commitPresetName()
            onEdited: w.presetNameDraft = nameField.text
            onEscapePressed: w.cancelPresetName()
        }

    }

    // an opaque link field, used by the panel and the manage screen
    component LinkField: Item {
        id: field

        property alias text: input.text
        property alias input: input
        property string placeholder: "Paste a YouTube link…"
        property string actionIcon: "add"
        property bool compact: false
        property int fieldH: field.compact ? Theme.dp(34) : Theme.dp(44)

        signal addRequested()
        signal edited()
        signal escapePressed()

        function focusField() {
            input.forceActiveFocus();
        }

        function clearField() {
            input.text = "";
        }

        implicitHeight: field.fieldH
        height: field.fieldH

        SquircleRect {
            anchors.fill: parent
            radius: height / 2
            fillColor: w.chipFill
            borderWidth: input.activeFocus || w.errorText !== "" ? 1.5 : 1
            borderColor: w.errorText !== "" ? Theme.error : (input.activeFocus ? Theme.primary : Theme.outline)
            smoothing: Prefs.squircleF
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            onClicked: input.forceActiveFocus()
        }

        LText {
            anchors.left: parent.left
            anchors.leftMargin: Theme.dp(12)
            anchors.right: fieldAdd.left
            anchors.rightMargin: Theme.dp(4)
            anchors.verticalCenter: parent.verticalCenter
            role: field.compact ? "bodyMedium" : "bodyLarge"
            color: w.panelSoft
            text: field.placeholder
            visible: input.text === ""
            elide: Text.ElideRight
        }

        TextInput {
            id: input

            anchors.left: parent.left
            anchors.leftMargin: Theme.dp(12)
            anchors.right: fieldAdd.left
            anchors.rightMargin: Theme.dp(4)
            anchors.verticalCenter: parent.verticalCenter
            color: w.panelInk
            selectionColor: Theme.primary
            selectedTextColor: Theme.fgPrimary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.typeSize(field.compact ? "bodyMedium" : "bodyLarge")
            font.variableAxes: Theme.axes(Theme.typeSize(field.compact ? "bodyMedium" : "bodyLarge"), 420, 0)
            clip: true
            onAccepted: field.addRequested()
            onTextEdited: field.edited()
            onActiveFocusChanged: {
                if (input.activeFocus)
                    w.beginEdit();
                else
                    w.endEdit();

            }
            Keys.onEscapePressed: {
                input.focus = false;
                w.endEdit();
                field.escapePressed();
            }

        }

        IconButton {
            id: fieldAdd

            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(2)
            anchors.verticalCenter: parent.verticalCenter
            icon: field.actionIcon
            iconFill: 1
            variant: "filled"
            size: "xs"
            onClicked: field.addRequested()
        }

    }

    // ---- faces -------------------------------------------------------------

    Item {
        anchors.fill: parent
        visible: w.discVariant && !w.manageOpen

        Header {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.dp(18)
            height: Theme.dp(32)
            showAdd: true
        }

        Disc {
            id: faceDisc

            active: w.live && w.discVariant && !w.manageOpen
            demandKey: w.uid + "-amb-disc"
            anchors.left: parent.left
            anchors.leftMargin: Theme.dp(20)
            anchors.verticalCenter: facePanel.verticalCenter
            diameter: Math.min(Theme.dp(120), w.width - Theme.dp(190))
        }

        SquircleRect {
            id: facePanel

            anchors.left: faceDisc.right
            anchors.leftMargin: Theme.dp(14)
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(20)
            anchors.top: parent.top
            anchors.topMargin: Theme.dp(92)
            height: Theme.dp(166)
            radius: Theme.dp(20)
            fillColor: w.panelFill
            smoothing: Prefs.squircleF

            Column {
                anchors.fill: parent
                anchors.margins: Theme.dp(14)
                spacing: Theme.dp(6)

                LText {
                    width: parent.width
                    role: "titleMedium"
                    color: w.panelInk
                    text: w.nowTitle
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }

                LText {
                    width: parent.width
                    role: "bodySmall"
                    color: w.errorText !== "" ? Theme.error : w.panelSoft
                    text: w.nowSub
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }

                Row {
                    visible: w.trackCount > 0
                    width: parent.width
                    spacing: Theme.dp(5)

                    Bars {
                        visible: w.playing && !w.preparing
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    LText {
                        anchors.verticalCenter: parent.verticalCenter
                        role: "labelSmall"
                        color: w.panelSoft
                        text: w.preparing ? Tr.t("Preparing…") : (w.playing ? Tr.t("Playing automatically") : Tr.t("Automatic"))
                    }

                }

                Item {
                    width: parent.width
                    height: Theme.dp(2)
                }

                LText {
                    visible: w.trackCount === 0
                    width: parent.width
                    role: "bodySmall"
                    color: w.panelSoft
                    text: Tr.t("Give this wallpaper its own YouTube loop.")
                    wrapMode: Text.WordWrap
                }

                Button {
                    visible: w.trackCount === 0
                    text: Tr.t("Add tracks")
                    variant: "filled"
                    size: "xs"
                    icon: "add"
                    onClicked: w.openManage()
                }

            }

        }

    }

    // the quarter face: just the record. the whole visual is the way into the
    // running order, so there is no header, footer or transport to get in the way
    Item {
        anchors.fill: parent
        visible: w.quarter && !w.manageOpen

        Item {
            anchors.centerIn: parent
            width: Math.min(w.width, w.height) - Theme.dp(60)
            height: width

            Disc {
                active: w.live && w.quarter && !w.manageOpen
                demandKey: w.uid + "-amb-quarter"
                anchors.centerIn: parent
                diameter: parent.width
            }

            StateLayer {
                anchors.fill: parent
                radius: width / 2
                tint: w.panelInk
                disabled: w.preview
                onClicked: w.openManage()
            }

        }

    }

    // the strip: one line of information, no transport
    Item {
        anchors.fill: parent
        visible: w.compact && !w.manageOpen

        Disc {
            active: w.live && w.compact && !w.manageOpen
            demandKey: w.uid + "-amb-row"
            anchors.left: parent.left
            anchors.leftMargin: Theme.dp(20)
            anchors.verticalCenter: parent.verticalCenter
            diameter: Theme.dp(78)
        }

        SquircleRect {
            anchors.left: parent.left
            anchors.leftMargin: Theme.dp(110)
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(20)
            anchors.verticalCenter: parent.verticalCenter
            height: Theme.dp(78)
            radius: Theme.dp(18)
            fillColor: w.panelFill
            smoothing: Prefs.squircleF

            Column {
                anchors.left: parent.left
                anchors.leftMargin: Theme.dp(12)
                anchors.right: rowAdd.left
                anchors.rightMargin: Theme.dp(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.dp(2)

                LText {
                    width: parent.width
                    role: "labelSmall"
                    color: w.panelSoft
                    text: Tr.t("Ambience")
                }

                LText {
                    width: parent.width
                    role: "titleSmall"
                    color: w.panelInk
                    text: w.nowTitle
                    elide: Text.ElideRight
                }

                LText {
                    width: parent.width
                    role: "labelSmall"
                    color: w.errorText !== "" ? Theme.error : w.panelSoft
                    text: w.nowSub
                    elide: Text.ElideRight
                }

            }

            IconButton {
                id: rowAdd

                anchors.right: parent.right
                anchors.rightMargin: Theme.dp(8)
                anchors.verticalCenter: parent.verticalCenter
                icon: "add"
                size: "xs"
                visible: !w.preview
                tintOverride: w.panelInk
                onClicked: w.openManage()
            }

        }

    }

    // the full programme: header, now panel, opaque rows and an add panel
    Item {
        anchors.fill: parent
        visible: w.panel && !w.manageOpen

        Header {
            id: panelHead

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.dp(20)
            height: Theme.dp(32)
            wallpaper: true
            showAdd: false
        }

        SquircleRect {
            id: nowPanel

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: panelHead.bottom
            anchors.leftMargin: Theme.dp(20)
            anchors.rightMargin: Theme.dp(20)
            anchors.topMargin: Theme.dp(12)
            height: Theme.dp(72)
            radius: Theme.dp(18)
            fillColor: w.panelFill
            smoothing: Prefs.squircleF

            Disc {
                active: w.live && w.panel && !w.manageOpen
                demandKey: w.uid + "-amb-panel"
                anchors.left: parent.left
                anchors.leftMargin: Theme.dp(8)
                anchors.verticalCenter: parent.verticalCenter
                diameter: Theme.dp(56)
            }

            Column {
                anchors.left: parent.left
                anchors.leftMargin: Theme.dp(78)
                anchors.right: parent.right
                anchors.rightMargin: Theme.dp(14)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.dp(3)

                LText {
                    width: parent.width
                    role: "titleSmall"
                    color: w.panelInk
                    text: w.nowTitle
                    elide: Text.ElideRight
                }

                LText {
                    width: parent.width
                    role: "labelSmall"
                    color: w.errorText !== "" ? Theme.error : w.panelSoft
                    text: w.nowSub
                    elide: Text.ElideRight
                }

            }

        }

        Item {
            id: listBox

            clip: true
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: nowPanel.bottom
            anchors.bottom: addPanel.top
            anchors.leftMargin: Theme.dp(20)
            anchors.rightMargin: Theme.dp(20)
            anchors.topMargin: Theme.dp(10)
            anchors.bottomMargin: Theme.dp(10)

            ListView {
                id: list

                anchors.fill: parent
                clip: true
                spacing: Theme.dp(2)
                boundsBehavior: Flickable.StopAtBounds
                model: w.tracks

                delegate: Item {
                    id: row

                    required property int index
                    required property var modelData

                    readonly property bool hovered: hover.hovered
                    readonly property real rowRadius: Math.min(Theme.rad(14), row.height / 2)
                    readonly property bool modeFlash: row.modelData.url === w.modeFlashUrl && w.modeFlashLabel !== ""

                    width: list.width
                    height: Theme.dp(44)

                    SquircleRect {
                        anchors.fill: parent
                        radius: row.rowRadius
                        fillColor: row.hovered ? w.chipFill : w.panelFill
                        borderWidth: row.hovered ? 1 : 0
                        borderColor: Theme.outline
                        smoothing: Prefs.squircleF

                        Behavior on fillColor {
                            ColorAnimation {
                                duration: Theme.durFastEffects
                            }

                        }

                    }

                    VolumeFill {
                        fraction: w.rowVolume(row.modelData) / 100
                        corner: row.rowRadius
                    }

                    Item {
                        id: modeButton

                        z: 2
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.dp(3)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Theme.dp(30)
                        height: parent.height

                        Icon {
                            anchors.centerIn: parent
                            name: Ambience.modeInfo(row.modelData.mode).icon
                            size: Theme.dp(17)
                            color: Theme.fgPrimaryContainer
                        }

                        StateLayer {
                            anchors.fill: parent
                            radius: width / 2
                            tint: Theme.fgPrimaryContainer
                            onClicked: w.cycleModeAt(list, row.index)
                        }

                    }

                    LText {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.dp(38)
                        anchors.right: remove.left
                        anchors.rightMargin: Theme.dp(8)
                        anchors.verticalCenter: parent.verticalCenter
                        role: "bodyMedium"
                        weight: row.modeFlash ? 620 : 420
                        color: Theme.fgPrimaryContainer
                        text: row.modeFlash ? w.modeFlashLabel : row.modelData.title
                        elide: Text.ElideRight
                    }

                    MouseArea {
                        id: dragArea

                        property real pressX: 0
                        property real pressY: 0
                        property bool dragging: false

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.SizeHorCursor
                        onPressed: (mouse) => {
                            dragArea.pressX = mouse.x;
                            dragArea.pressY = mouse.y;
                            dragArea.dragging = false;
                        }
                        onPositionChanged: (mouse) => {
                            if (!pressed)
                                return ;

                            var dx = Math.abs(mouse.x - dragArea.pressX);
                            var dy = Math.abs(mouse.y - dragArea.pressY);
                            if (!dragArea.dragging && dx > 3 && dx > dy)
                                dragArea.dragging = true;
                            if (dragArea.dragging)
                                w.dragVolume(row.index, row.modelData, mouse.x, width);

                        }
                        onReleased: (mouse) => {
                            w.commitVolumeAt(list, row.index, row.modelData, mouse.x, width);
                            dragArea.dragging = false;
                        }
                        onCanceled: {
                            if (dragArea.dragging)
                                w.commitVolumeAt(list, row.index, row.modelData, w.rowVolume(row.modelData) / 100 * width, width);
                            dragArea.dragging = false;
                        }
                    }

                    IconButton {
                        id: remove

                        z: 2
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.dp(6)
                        anchors.verticalCenter: parent.verticalCenter
                        icon: "close"
                        size: "xs"
                        visible: !w.preview && row.hovered
                        opacity: visible ? 1 : 0
                        tintOverride: Theme.fgPrimaryContainer
                        onClicked: {
                            if (!w.preview)
                                Ambience.removeTrack(row.index);

                        }

                        Behavior on opacity {
                            NumberAnimation {
                                duration: Theme.durFastEffects
                            }

                        }

                    }

                    HoverHandler {
                        id: hover
                    }

                }

                footer: PresetFooter {
                    viewWidth: list.width
                }

            }

            SquircleRect {
                anchors.centerIn: parent
                width: Math.min(parent.width, Theme.dp(300))
                height: Math.min(parent.height, Theme.dp(128))
                radius: Theme.dp(18)
                fillColor: w.panelFill
                smoothing: Prefs.squircleF
                visible: w.trackCount === 0

                Column {
                    anchors.centerIn: parent
                    width: parent.width - Theme.dp(24)
                    spacing: Theme.dp(6)

                    LText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        role: "titleSmall"
                        color: w.panelInk
                        text: Tr.t("No soundtrack yet")
                    }

                    LText {
                        width: parent.width
                        role: "bodySmall"
                        color: w.panelSoft
                        text: Tr.t("Paste a YouTube link below and this wallpaper gets its own loop.")
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                    Button {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Tr.t("Load preset")
                        variant: "outlined"
                        size: "xs"
                        icon: "folder_open"
                        onClicked: w.openPresetLoad()
                    }

                }

            }

        }

        SquircleRect {
            id: addPanel

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: Theme.dp(20)
            anchors.rightMargin: Theme.dp(20)
            anchors.bottomMargin: Theme.dp(20)
            height: Theme.dp(64)
            radius: Theme.dp(18)
            fillColor: w.panelFill
            smoothing: Prefs.squircleF

            LinkField {
                id: panelField

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Theme.dp(10)
                anchors.rightMargin: Theme.dp(10)
                anchors.verticalCenter: parent.verticalCenter
                placeholder: Tr.t("Paste a YouTube link…")
                onAddRequested: w.addLinkFrom(panelField)
                onEdited: {
                    if (!w.preview)
                        Ambience.clearError();

                }
            }

        }

    }

    // ---- the running order screen -----------------------------------------

    Loader {
        id: manageLoader

        anchors.fill: parent
        z: 20
        active: visible
        visible: w.manageOpen || manageLoader.opacity > 0.01
        opacity: w.manageOpen ? 1 : 0
        scale: 0.985 + manageLoader.opacity * 0.015
        transformOrigin: Item.Center
        sourceComponent: manageScreen

        Behavior on opacity {
            NumberAnimation {
                duration: w.manageOpen ? Theme.durEnter : Theme.durExit
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveDefaultSpatial
            }

        }

        onLoaded: {
            if (w.manageOpen && item && typeof item.focusField === "function")
                item.focusField();

        }
    }

    Component {
        id: manageScreen

        Item {
            id: manage

            anchors.fill: parent

            function focusField() {
                manageField.focusField();
            }

            function clearField() {
                manageField.clearField();
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onWheel: (wheel) => wheel.accepted = true
            }

            SquircleRect {
                id: manageHead

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: w.managePad
                anchors.rightMargin: w.managePad
                anchors.topMargin: w.managePad
                height: w.manageHeaderH
                radius: height / 2
                fillColor: w.panelFill
                smoothing: Prefs.squircleF

                IconButton {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.dp(3)
                    anchors.verticalCenter: parent.verticalCenter
                    icon: "arrow_back"
                    size: "xs"
                    tintOverride: w.panelInk
                    onClicked: w.closeManage()
                }

                LText {
                    id: manageTitle

                    anchors.left: parent.left
                    anchors.leftMargin: Theme.dp(34)
                    anchors.verticalCenter: parent.verticalCenter
                    role: "labelLarge"
                    color: w.panelInk
                    text: Tr.t("Tracks")
                }

                LText {
                    anchors.left: manageTitle.right
                    anchors.leftMargin: Theme.dp(6)
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(8)
                    anchors.verticalCenter: parent.verticalCenter
                    role: "labelSmall"
                    color: w.errorText !== "" ? Theme.error : w.panelSoft
                    text: w.errorText !== "" ? w.errorText : w.wallpaperLine
                    elide: Text.ElideRight
                }

            }

            Item {
                id: manageListBox

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: manageHead.bottom
                anchors.bottom: manageField.top
                anchors.leftMargin: w.managePad
                anchors.rightMargin: w.managePad
                anchors.topMargin: Theme.dp(6)
                anchors.bottomMargin: Theme.dp(6)
                clip: true

                ListView {
                    id: manageList

                    anchors.fill: parent
                    clip: true
                    spacing: Theme.dp(2)
                    model: w.tracks
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height

                    delegate: Item {
                        id: manageRow

                        required property int index
                        required property var modelData

                        readonly property bool hovered: hover.hovered
                        readonly property real rowRadius: Math.min(Theme.rad(10), manageRow.height / 2)
                        readonly property bool modeFlash: manageRow.modelData.url === w.modeFlashUrl && w.modeFlashLabel !== ""

                        width: manageList.width
                        height: w.manageRowH

                        SquircleRect {
                            anchors.fill: parent
                            radius: manageRow.rowRadius
                            fillColor: manageRow.hovered ? w.chipFill : w.panelFill
                            borderWidth: manageRow.hovered ? 1 : 0
                            borderColor: Theme.outline
                            smoothing: Prefs.squircleF

                            Behavior on fillColor {
                                ColorAnimation {
                                    duration: Theme.durFastEffects
                                }

                            }

                        }

                        VolumeFill {
                            fraction: w.rowVolume(manageRow.modelData) / 100
                            corner: manageRow.rowRadius
                        }

                        Item {
                            id: modeButton

                            z: 2
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.dp(2)
                            anchors.verticalCenter: parent.verticalCenter
                            width: w.manageCompact ? Theme.dp(22) : Theme.dp(26)
                            height: parent.height

                            Icon {
                                anchors.centerIn: parent
                                name: Ambience.modeInfo(manageRow.modelData.mode).icon
                                size: w.manageCompact ? Theme.dp(14) : Theme.dp(16)
                                color: Theme.fgPrimaryContainer
                            }

                            StateLayer {
                                anchors.fill: parent
                                radius: width / 2
                                tint: Theme.fgPrimaryContainer
                                onClicked: w.cycleModeAt(manageList, manageRow.index)
                            }

                        }

                        LText {
                            anchors.left: parent.left
                            anchors.leftMargin: w.manageCompact ? Theme.dp(26) : Theme.dp(32)
                            anchors.right: manageRemove.left
                            anchors.rightMargin: Theme.dp(4)
                            anchors.verticalCenter: parent.verticalCenter
                            role: "bodyMedium"
                            weight: manageRow.modeFlash ? 620 : 420
                            color: Theme.fgPrimaryContainer
                            text: manageRow.modeFlash ? w.modeFlashLabel : manageRow.modelData.title
                            elide: Text.ElideRight
                        }

                        MouseArea {
                            id: dragArea

                            property real pressX: 0
                            property real pressY: 0
                            property bool dragging: false

                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.SizeHorCursor
                            onPressed: (mouse) => {
                                dragArea.pressX = mouse.x;
                                dragArea.pressY = mouse.y;
                                dragArea.dragging = false;
                            }
                            onPositionChanged: (mouse) => {
                                if (!pressed)
                                    return ;

                                var dx = Math.abs(mouse.x - dragArea.pressX);
                                var dy = Math.abs(mouse.y - dragArea.pressY);
                                if (!dragArea.dragging && dx > 3 && dx > dy)
                                    dragArea.dragging = true;
                                if (dragArea.dragging)
                                    w.dragVolume(manageRow.index, manageRow.modelData, mouse.x, width);

                            }
                            onReleased: (mouse) => {
                                w.commitVolumeAt(manageList, manageRow.index, manageRow.modelData, mouse.x, width);
                                dragArea.dragging = false;
                            }
                            onCanceled: {
                                if (dragArea.dragging)
                                    w.commitVolumeAt(manageList, manageRow.index, manageRow.modelData, w.rowVolume(manageRow.modelData) / 100 * width, width);
                                dragArea.dragging = false;
                            }
                        }

                        Item {
                            id: manageRemove

                            z: 2
                            anchors.right: parent.right
                            width: w.manageCompact ? Theme.dp(22) : Theme.dp(28)
                            height: parent.height

                            Icon {
                                anchors.centerIn: parent
                                name: "close"
                                size: w.manageCompact ? Theme.dp(14) : Theme.dp(16)
                                color: Theme.fgPrimaryContainer
                            }

                            StateLayer {
                                anchors.fill: parent
                                radius: width / 2
                                tint: Theme.fgPrimaryContainer
                                onClicked: Ambience.removeTrack(manageRow.index)
                            }

                        }

                        HoverHandler {
                            id: hover
                        }

                    }

                    footer: PresetFooter {
                        viewWidth: manageList.width
                    }

                }

                SquircleRect {
                    anchors.centerIn: parent
                    width: Math.min(parent.width, Theme.dp(260))
                    height: Math.min(parent.height, w.manageCompact ? Theme.dp(46) : Theme.dp(96))
                    radius: Theme.dp(12)
                    fillColor: w.panelFill
                    smoothing: Prefs.squircleF
                    visible: w.trackCount === 0

                    Column {
                        anchors.centerIn: parent
                        width: parent.width - Theme.dp(16)
                        spacing: Theme.dp(4)

                        LText {
                            visible: !w.manageCompact
                            width: parent.width
                            role: "labelSmall"
                            color: w.panelInk
                            text: Tr.t("No tracks yet · paste a link below")
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                        }

                        Button {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: w.manageCompact ? Tr.t("Load") : Tr.t("Load preset")
                            variant: "outlined"
                            size: "xs"
                            icon: w.manageCompact ? "" : "folder_open"
                            onClicked: w.openPresetLoad()
                        }

                    }

                }

            }

            LinkField {
                id: manageField

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: w.managePad
                anchors.rightMargin: w.managePad
                anchors.bottomMargin: w.managePad
                fieldH: w.manageFieldH
                compact: w.manageCompact
                placeholder: w.manageCompact ? Tr.t("Paste a link…") : Tr.t("Paste a YouTube link…")
                onAddRequested: w.addLinkFrom(manageField)
                onEdited: Ambience.clearError()
            }

        }

    }

    // ---- presets ----------------------------------------------------------

    Loader {
        id: presetLoader

        anchors.fill: parent
        z: 21
        active: visible
        visible: w.presetOpen || presetLoader.opacity > 0.01
        opacity: w.presetOpen ? 1 : 0
        scale: 0.985 + presetLoader.opacity * 0.015
        transformOrigin: Item.Center
        sourceComponent: presetScreen

        Behavior on opacity {
            NumberAnimation {
                duration: w.presetOpen ? Theme.durEnter : Theme.durExit
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveDefaultSpatial
            }

        }

    }

    Component {
        id: presetScreen

        Item {
            anchors.fill: parent

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onWheel: (wheel) => wheel.accepted = true
            }

            SquircleRect {
                id: presetPanel

                anchors.fill: parent
                anchors.margins: w.managePad
                radius: Theme.dp(18)
                fillColor: w.panelFill
                smoothing: Prefs.squircleF

                Item {
                    id: presetHead

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.leftMargin: Theme.dp(6)
                    anchors.rightMargin: Theme.dp(10)
                    anchors.topMargin: Theme.dp(6)
                    height: w.manageHeaderH

                    IconButton {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        icon: "arrow_back"
                        size: "xs"
                        tintOverride: w.panelInk
                        onClicked: w.closePresetLoad()
                    }

                    LText {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.dp(34)
                        anchors.verticalCenter: parent.verticalCenter
                        role: "labelLarge"
                        color: w.panelInk
                        text: Tr.t("Load preset")
                    }

                    LText {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        role: "labelSmall"
                        color: w.panelSoft
                        text: Ambience.presets.length + (Ambience.presets.length === 1 ? Tr.t(" preset") : Tr.t(" presets"))
                    }

                }

                Item {
                    id: presetListBox

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: presetHead.bottom
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: Theme.dp(6)
                    anchors.rightMargin: Theme.dp(6)
                    anchors.topMargin: Theme.dp(4)
                    anchors.bottomMargin: Theme.dp(6)
                    clip: true

                    ListView {
                        id: presetList

                        anchors.fill: parent
                        clip: true
                        spacing: Theme.dp(2)
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: contentHeight > height
                        model: Ambience.presets

                        delegate: Item {
                            id: presetRow

                            required property int index
                            required property var modelData

                            readonly property bool hovered: presetHover.hovered
                            readonly property real rowRadius: Math.min(Theme.rad(10), presetRow.height / 2)

                            width: presetList.width
                            height: w.manageCompact ? Theme.dp(30) : Theme.dp(38)

                            SquircleRect {
                                anchors.fill: parent
                                radius: presetRow.rowRadius
                                fillColor: presetRow.hovered ? w.chipFill : w.panelFill
                                smoothing: Prefs.squircleF
                            }

                            Column {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.dp(10)
                                anchors.right: presetRemove.left
                                anchors.rightMargin: Theme.dp(6)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.dp(1)

                                LText {
                                    width: parent.width
                                    role: "bodyMedium"
                                    color: w.panelInk
                                    text: presetRow.modelData.name
                                    elide: Text.ElideRight
                                }

                                LText {
                                    visible: !w.manageCompact
                                    width: parent.width
                                    role: "labelSmall"
                                    color: w.panelSoft
                                    text: presetRow.modelData.tracks.length + (presetRow.modelData.tracks.length === 1 ? Tr.t(" track") : Tr.t(" tracks"))
                                    elide: Text.ElideRight
                                }

                            }

                            StateLayer {
                                anchors.fill: parent
                                radius: presetRow.rowRadius
                                tint: w.panelInk
                                onClicked: w.loadPreset(presetRow.modelData.id)
                            }

                            IconButton {
                                id: presetRemove

                                z: 2
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.dp(6)
                                anchors.verticalCenter: parent.verticalCenter
                                icon: "close"
                                size: "xs"
                                tintOverride: presetRow.hovered ? Theme.error : w.panelSoft
                                onClicked: Ambience.deletePreset(presetRow.modelData.id)
                            }

                            HoverHandler {
                                id: presetHover
                            }

                        }

                    }

                    LText {
                        anchors.centerIn: parent
                        width: Math.min(parent.width - Theme.dp(20), Theme.dp(220))
                        visible: Ambience.presets.length === 0
                        role: "bodySmall"
                        color: w.panelSoft
                        text: Tr.t("No presets saved yet. Use Save preset at the end of the track list.")
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                }

            }

        }

    }

}
