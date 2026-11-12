import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs
import qs.lucidui
import "../squircle"

// The root OpenCode sessions open in your terminal windows, with the one that
// is working marked by a live loading indicator. The TUI plugin writes one
// snapshot per window; opencode-sessions.py merges them here.
WidgetBody {
    id: w

    property var payload: null

    readonly property var sample: ({
        "version": 1,
        "generatedAt": 0,
        "sessions": [{
            "id": "ses_preview_busy",
            "title": "Refactor the settings screen",
            "status": "busy",
            "active": true,
            "attention": false,
            "directory": "/home/you/code/lucid",
            "windows": [1]
        }, {
            "id": "ses_preview_wait",
            "title": "Fix the widget animation",
            "status": "attention",
            "active": false,
            "attention": true,
            "directory": "/home/you/code/opencode",
            "windows": [2]
        }, {
            "id": "ses_preview_idle",
            "title": "Write the release notes",
            "status": "idle",
            "active": false,
            "attention": false,
            "directory": "/home/you/notes",
            "windows": [3]
        }]
    })
    readonly property var allSessions: {
        const source = w.preview ? w.sample : w.payload;
        return source && Array.isArray(source.sessions) ? source.sessions : [];
    }
    readonly property var sessions: {
        if (w.opt("hideIdle") !== true)
            return w.allSessions;

        return w.allSessions.filter((session) => {
            return session.status !== "idle";
        });
    }
    readonly property int busyCount: w.allSessions.filter((session) => {
        return session.status === "busy";
    }).length
    readonly property int attentionCount: w.allSessions.filter((session) => {
        return session.status === "attention";
    }).length
    readonly property bool showPath: w.opt("showPath") !== false
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property int rowH: Theme.dp(54)
    readonly property bool gridOnly: w.variant === "grid"
    readonly property int gridColumns: Math.max(1, Math.ceil(Math.sqrt(w.sessions.length)))
    readonly property int gridRows: Math.max(1, Math.ceil(w.sessions.length / w.gridColumns))
    readonly property bool grid4x3: w.gridColumns === 4 && w.gridRows === 3
    // The morphing indicator repaints every frame; only spend that when the
    // shell is already running a compositor/3D wallpaper effect.
    // The busy marker must not animate just because a visual effect is on.
    // LoadingIndicator is a Shape with CurveRenderer: it rebuilds its path and
    // re-tessellates every frame on the GUI thread, and a busy session runs it
    // forever. Measured: this widget alone held the shell's main thread at
    // ~50% CPU; freezing it drops it to ~6%. Static circle still reads busy.
    readonly property bool animateStatus: false
    readonly property real gridGap: Theme.dp(6)
    readonly property real gridAvailable: Math.min(w.width, w.height) - Theme.dp(20)
    readonly property real gridCell: {
        if (w.sessions.length === 0)
            return Theme.dp(30);

        const byColumns = (w.gridAvailable - (w.gridColumns - 1) * w.gridGap) / w.gridColumns;
        const byRows = (w.gridAvailable - (w.gridRows - 1) * w.gridGap) / w.gridRows;
        return Math.max(Theme.dp(10), Math.min(Theme.dp(96), Math.floor(Math.min(byColumns, byRows))));
    }
    readonly property real markWidth: Math.max(0, Math.min(w.width, w.height) * 0.64 - Theme.dp(40))
    readonly property real markHeight: Math.max(0, Math.min(w.width, w.height) * 0.80 - Theme.dp(40))
    // Draw an opaque colour that *looks* like 10% ink on the card. Alpha
    // compositing on the transparent liquid-glass surface is unreliable, so
    // this bakes the tint into the RGB instead of relying on opacity.
    readonly property color markColor: {
        const base = w.fill;
        const ink = Theme.isLightMode ? 0.0 : 1.0;
        const a = 0.10;
        return Qt.rgba(base.r + (ink - base.r) * a, base.g + (ink - base.g) * a, base.b + (ink - base.b) * a, 1.0);
    }
    // The grid has no room for labels, so it names the item under the pointer
    // in a pill along the bottom edge.
    property string hoveredID: ""
    readonly property string hoveredTitle: {
        if (w.hoveredID === "")
            return "";

        for (let i = 0; i < w.sessions.length; i++) {
            if (w.sessions[i].id === w.hoveredID)
                return w.sessions[i].title || "Untitled session";
        }
        return "";
    }

    defaultTone: "surface"

    function refresh() {
        if (!w.live || reader.running)
            return ;

        reader.running = true;
    }

    function locationOf(path) {
        if (!path)
            return "";

        const clean = String(path).replace(/\/+$/, "") || "/";
        const root = String(w.home).replace(/\/+$/, "");
        // The home directory itself reads as ~; everything else shows only its
        // leaf so the line stays short.
        if (root !== "" && clean === root)
            return "~";

        const parts = clean.split("/").filter((part) => {
            return part !== "";
        });
        return parts.length > 0 ? parts[parts.length - 1] : clean;
    }

    function statusText(status) {
        switch (status) {
        case "busy":
            return "Working";
        case "attention":
            return "Needs you";
        }
        return "Done";
    }

    function detailOf(session) {
        const parts = [w.statusText(session.status)];
        if (w.showPath && w.locationOf(session.directory) !== "")
            parts.push(w.locationOf(session.directory));
        if (Array.isArray(session.windows) && session.windows.length > 1)
            parts.push(session.windows.length + " windows");

        return parts.join("  ");
    }

    // Hyprland has the window address of the terminal this session lives in.
    // Clicking a row brings that window forward.
    function focusSession(session) {
        if (!w.live || !session)
            return ;

        if (session.windowAddress)
            Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow", "address:" + session.windowAddress]);
        else if (session.windowPid)
            Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow", "pid:" + session.windowPid]);
    }

    // Each tick forks python3 (opencode-sessions.py). At 1 Hz that was a
    // process spawn every second for a status card; 2 s is indistinguishable
    // in use and halves the churn.
    Timer {
        interval: 2000
        repeat: true
        running: w.primaryScreen
        triggeredOnStart: true
        onTriggered: w.refresh()
    }

    onLiveChanged: {
        if (w.live)
            w.refresh();
    }

    Process {
        id: reader

        command: ["python3", Qt.resolvedUrl("opencode-sessions.py").toString().replace("file://", "")]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    w.payload = JSON.parse(this.text);
                } catch (e) {
                    w.payload = null;
                }
            }
        }
    }

    Item {
        id: head

        visible: !w.gridOnly
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Theme.dp(16)
        anchors.leftMargin: Theme.dp(18)
        anchors.rightMargin: Theme.dp(18)
        height: Theme.dp(26)

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(8)

            Icon {
                visible: w.allSessions.length > 0
                anchors.verticalCenter: parent.verticalCenter
                name: "terminal"
                size: Theme.dp(17)
                color: w.inkAccent
            }

            LText {
                anchors.verticalCenter: parent.verticalCenter
                role: "titleSmall"
                weight: 560
                color: w.ink
                text: Tr.t("OpenCode")
            }

        }

        LText {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            role: "labelMedium"
            color: w.busyCount > 0 ? w.inkAccent : w.inkDim
            text: w.allSessions.length === 0 ? "none" : (w.busyCount > 0 ? w.busyCount + Tr.t(" working") : w.allSessions.length + Tr.t(" open"))
        }

    }

    ListView {
        id: list

        anchors.top: head.bottom
        anchors.topMargin: Theme.dp(10)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.dp(10)
        anchors.rightMargin: Theme.dp(10)
        anchors.bottomMargin: Theme.dp(12)
        visible: w.sessions.length > 0 && !w.gridOnly
        model: w.sessions
        spacing: Theme.dp(2)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        delegate: SquircleRect {
            id: row

            required property var modelData
            required property int index

            readonly property bool hot: hover.hovered

            width: list.width
            height: w.rowH
            topLeftRadius: row.index === 0 ? Theme.rad(16) : Theme.dp(4)
            topRightRadius: row.index === 0 ? Theme.rad(16) : Theme.dp(4)
            bottomLeftRadius: row.index === w.sessions.length - 1 ? Theme.rad(16) : Theme.dp(4)
            bottomRightRadius: row.index === w.sessions.length - 1 ? Theme.rad(16) : Theme.dp(4)
            fillColor: row.hot ? Theme.surfaceHighest : Theme.surfaceHigh
            borderWidth: 1
            borderColor: Theme.alpha(w.ink, row.hot ? 0.14 : 0.07)
            smoothing: Prefs.squircleF

            Behavior on fillColor {
                ColorAnimation {
                    duration: Theme.durMedium
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveEffects
                }

            }

            Behavior on borderColor {
                ColorAnimation {
                    duration: Theme.durShort
                }

            }

            HoverHandler {
                id: hover
            }

            Item {
                id: status

                anchors.left: parent.left
                anchors.leftMargin: Theme.dp(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.dp(22)
                height: Theme.dp(22)

                // Animated only alongside liquid glass or the 3D/mesh wallpaper
                // effects; otherwise a plain filled circle avoids per-frame
                // repaints.
                LoadingIndicator {
                    anchors.fill: parent
                    visible: row.modelData.status === "busy"
                    running: w.animateStatus
                    circleMorph: w.animateStatus ? 0 : 1
                    color: w.inkAccent
                }

                Rectangle {
                    visible: row.modelData.status === "idle"
                    anchors.centerIn: parent
                    width: Theme.dp(7)
                    height: width
                    radius: width / 2
                    color: w.inkFaint
                }

                Icon {
                    visible: row.modelData.status === "attention"
                    anchors.centerIn: parent
                    name: "error"
                    size: Theme.dp(18)
                    color: Theme.error
                }

            }

            Column {
                anchors.left: status.right
                anchors.leftMargin: Theme.dp(10)
                anchors.right: activeDot.left
                anchors.rightMargin: Theme.dp(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.dp(1)

                LText {
                    width: parent.width
                    role: "bodyMedium"
                    weight: 520
                    color: w.ink
                    text: row.modelData.title || Tr.t("Untitled session")
                    elide: Text.ElideRight
                }

                LText {
                    width: parent.width
                    role: "labelSmall"
                    color: row.modelData.status === "attention" ? Theme.error : w.inkDim
                    text: w.detailOf(row.modelData)
                    elide: Text.ElideRight
                }

            }

            Rectangle {
                id: activeDot

                visible: row.modelData.active === true && row.modelData.status !== "busy"
                anchors.right: parent.right
                anchors.rightMargin: Theme.dp(13)
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.dp(6)
                height: width
                radius: width / 2
                color: w.inkAccent
            }

            WidgetTap {
                anchors.fill: parent
                widget: w
                onTapped: w.focusSession(row.modelData)
            }

        }

    }

    // the logo's O, quiet behind the lights
    Shape {
        id: mark

        visible: w.gridOnly
        width: 240
        height: 300
        anchors.centerIn: parent
        preferredRendererType: Shape.CurveRenderer

        transform: Scale {
            origin.x: mark.width / 2
            origin.y: mark.height / 2
            xScale: w.markWidth / 240
            yScale: w.markHeight / 300
        }

        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillColor: w.markColor

            PathSvg {
                path: "M180 60H60V240H180V60ZM240 300H0V0H240V300Z"
            }

        }

    }

    // grid: only each session's state, sized to fit the square card
    Grid {
        id: grid

        visible: w.gridOnly && w.sessions.length > 0
        anchors.centerIn: parent
        columns: w.gridColumns
        rowSpacing: w.gridGap
        columnSpacing: w.gridGap

        Repeater {
            model: w.sessions

            Item {
                id: cell

                required property var modelData

                width: w.gridCell
                height: w.gridCell
                scale: cellHover.hovered ? 1.18 : 1
                z: cellHover.hovered ? 2 : 0

                Behavior on scale {
                    NumberAnimation {
                        duration: Theme.durFastSpatial
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveFastSpatial
                    }

                }

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Theme.alpha(w.ink, 0.07)
                    visible: cellHover.hovered
                }

                LoadingIndicator {
                    id: busySpinner

                    width: Math.round(cell.width * 0.82)
                    height: width
                    anchors.centerIn: parent
                    visible: cell.modelData.status === "busy"
                    running: w.animateStatus
                    circleMorph: w.animateStatus ? 0 : 1
                    color: w.inkAccent
                    layer.enabled: visible
                    layer.effect: MultiEffect {
                        maskEnabled: true
                        maskSource: busyCutout
                        maskInverted: true
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                    }

                }

                Item {
                    id: busyCutout

                    width: busySpinner.width
                    height: busySpinner.height
                    anchors.centerIn: parent
                    visible: false
                    layer.enabled: true

                    DeepSeekMark {
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: w.grid4x3 ? 0 : Math.round(busySpinner.width * 0.06)
                        anchors.verticalCenterOffset: w.grid4x3 ? 0 : Math.round(busySpinner.width * 0.03)
                        size: Math.round(busySpinner.width * 0.627)
                        color: "white"
                    }

                }

                DeepSeekMark {
                    visible: cell.modelData.status === "idle"
                    anchors.centerIn: parent
                    size: Math.round(cell.width * 0.62)
                    color: w.inkDim
                }

                Icon {
                    visible: cell.modelData.status === "attention"
                    anchors.centerIn: parent
                    name: "error"
                    size: Math.round(cell.width * 0.70)
                    fill: 1
                    color: Theme.error
                }

                HoverHandler {
                    id: cellHover

                    onHoveredChanged: {
                        if (cellHover.hovered)
                            w.hoveredID = cell.modelData.id;
                        else if (w.hoveredID === cell.modelData.id)
                            w.hoveredID = "";
                    }

                }

                WidgetTap {
                    anchors.fill: parent
                    widget: w
                    onTapped: w.focusSession(cell.modelData)
                }

            }

        }

    }

    // measure the title so a short name is centred, while a long one scrolls
    LText {
        id: hoverMeasure

        visible: false
        role: "labelMedium"
        text: w.hoveredTitle
    }

    // the grid names the item under the pointer along its bottom edge. short
    // names sit centred; long ones start scrolling after a short beat.
    Item {
        id: hoverName

        visible: w.gridOnly && w.hoveredTitle !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.dp(8)
        width: Math.min(parent.width - Theme.dp(16), hoverMeasure.implicitWidth)
        height: hoverMeasure.implicitHeight
        clip: hoverName.overflow

        readonly property real gap: Theme.dp(48)
        readonly property bool overflow: hoverMeasure.implicitWidth > width + 1
        readonly property string title: w.hoveredTitle
        property real offset: 0
        onTitleChanged: hoverName.offset = 0

        Row {
            id: hoverRow

            x: hoverName.overflow ? -hoverName.offset : Math.round((hoverName.width - hoverMeasure.implicitWidth) / 2)
            spacing: hoverName.gap

            LText {
                role: "labelMedium"
                color: w.ink
                text: hoverName.title
            }

            LText {
                visible: hoverName.overflow
                role: "labelMedium"
                color: w.ink
                text: hoverName.title
            }

        }

        SequentialAnimation {
            running: hoverName.overflow && hoverName.visible
            loops: Animation.Infinite

            PauseAnimation {
                duration: 350
            }

            NumberAnimation {
                target: hoverName
                property: "offset"
                from: 0
                to: hoverMeasure.implicitWidth + hoverName.gap
                duration: Math.max(1, (hoverMeasure.implicitWidth + hoverName.gap) / 34 * 1000)
            }

            ScriptAction {
                script: hoverName.offset = 0
            }

        }

    }

    Column {
        visible: !w.gridOnly && w.sessions.length === 0
        anchors.centerIn: list
        width: list.width - Theme.dp(16)
        spacing: Theme.dp(7)

        Icon {
            visible: w.allSessions.length > 0
            anchors.horizontalCenter: parent.horizontalCenter
            name: "visibility_off"
            size: Theme.dp(30)
            color: w.inkFaint
        }

        LText {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            role: "bodyMedium"
            color: w.inkDim
            text: w.allSessions.length > 0 ? Tr.t("All open sessions are done") : Tr.t("No OpenCode sessions open")
        }

    }


}
