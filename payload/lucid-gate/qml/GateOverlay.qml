import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs
import qs.lucidui
import qs.squircle

// The foreground half of lucid-gate.
//
//   gate mode  a full-screen layer surface over the monitor the action came
//              from.  A scrim dims everything; the active window is dimmed
//              again inside a squircle so the card reads as "this, specifically,
//              is waiting".  Input is grabbed, Escape cancels.
//   pill mode  while a task is running (Duolingo needs a browser), the overlay
//              collapses into a small always-on-top card in the corner.  It
//              only covers itself, so the task can actually be done.
Scope {
    id: root

    readonly property bool lessonUp: GateCore.lessonOpen
        && (GateCore.running !== null || GateCore.lessonLinger || GateCore.lessonKeepOpen)
    readonly property bool pillMode: GateCore.pillWanted && GateCore.running !== null && !root.lessonUp
    readonly property bool gatePending: GateCore.loaded && GateCore.gate !== null && !root.pillMode && !root.lessonUp
    // nothing is drawn until the window geometry is known, so the card never
    // appears somewhere else first
    readonly property bool gateUp: root.gatePending && root.geometryReady
    readonly property bool pillUp: GateCore.loaded && root.pillMode
    readonly property bool overlayUp: root.gateUp || root.lessonUp
    property string targetName: ""
    property bool geometryReady: false
    property var frozen: null
    // the WebEngine view is expensive and QtWebEngine does not like being torn
    // down while a JavaScript callback is in flight: once created, keep it
    // warm for the shell's lifetime and hide it between lessons
    // one warm WebEngine per output: switching outputs must not tear the old
    // one down (that was the crash), and a widget on another output opens there
    property var warmScreens: ({})
    readonly property bool lessonWarm: Object.keys(root.warmScreens).length > 0
    property string lessonScreen: ""
    property int lessonSerial: 0

    function rectFromIpc(info) {
        if (!info || !info.at || !info.size)
            return null;

        const at = info.at;
        const size = info.size;
        const ax = at.x !== undefined ? at.x : at[0];
        const ay = at.y !== undefined ? at.y : at[1];
        const aw = size.x !== undefined ? size.x : size[0];
        const ah = size.y !== undefined ? size.y : size[1];
        if (!(aw > 0 && ah > 0))
            return null;

        const monitors = Hyprland.monitors ? Hyprland.monitors.values : [];
        let monitor = null;
        for (let i = 0; i < monitors.length; i++) {
            if (monitors[i].id === info.monitor)
                monitor = monitors[i];
        }
        if (monitor === null)
            return null;

        return {
            "screen": monitor.name,
            "x": ax - monitor.x,
            "y": ay - monitor.y,
            "w": aw,
            "h": ah
        };
    }

    function measure() {
        const toplevel = Hyprland.activeToplevel;
        if (!toplevel || !toplevel.lastIpcObject)
            return null;

        return root.rectFromIpc(toplevel.lastIpcObject);
    }

    function applyRect(rect) {
        root.frozen = rect;
        if (rect !== null && rect.screen !== "")
            root.targetName = rect.screen;
        root.geometryReady = true;
    }

    // Quickshell knows the focused toplevel only after it has seen a focus
    // event, which is not guaranteed on a fresh shell. Ask Hyprland for its
    // focus history in that case; the gate stays hidden until an answer
    // arrives, so the card never shows at a temporary position.
    function absorbClients(raw) {
        let list = null;
        try {
            list = JSON.parse(raw);
        } catch (e) {
            list = null;
        }
        if (!Array.isArray(list)) {
            root.applyRect(null);
            return ;
        }
        let best = null;
        let bestRank = 1e9;
        for (let i = 0; i < list.length; i++) {
            const client = list[i];
            if (!client || client.mapped === false || client.hidden === true)
                continue;

            const rank = client.focusHistoryID !== undefined ? Number(client.focusHistoryID) : 1e9;
            if (rank < bestRank) {
                bestRank = rank;
                best = client;
            }
        }
        root.applyRect(root.rectFromIpc(best));
    }

    function begin() {
        const monitor = Hyprland.focusedMonitor;
        root.targetName = monitor ? monitor.name : (Quickshell.screens.length > 0 ? Quickshell.screens[0].name : "");
        root.geometryReady = false;
        const rect = root.measure();
        if (rect !== null)
            root.applyRect(rect);
        else
            activeWindow.running = true;
    }

    onGatePendingChanged: {
        if (root.gatePending)
            root.begin();
    }
    onPillUpChanged: {
        if (root.pillUp)
            root.begin();

    }

    Process {
        id: activeWindow

        command: ["hyprctl", "-j", "clients"]
        onExited: {
            if (!root.geometryReady)
                root.applyRect(null);
        }
        stdout: StdioCollector {
            onStreamFinished: root.absorbClients(this.text)
        }
        stderr: StdioCollector {}
    }
    onLessonUpChanged: {
        if (!root.lessonUp)
            return ;

        const names = Quickshell.screens.map((screen) => screen.name);
        let target = "";
        const rect = GateCore.launchRect;
        // the widget that was clicked wins: open on its output, even if the
        // warm view currently lives on another one
        if (rect && rect.screen && names.indexOf(rect.screen) >= 0)
            target = rect.screen;
        else if (root.gate !== null && root.targetName && names.indexOf(root.targetName) >= 0)
            target = root.targetName;
        if (target === "") {
            const monitor = Hyprland.focusedMonitor;
            target = (monitor && monitor.name) ? monitor.name : (names.length > 0 ? names[0] : "");
        }

        root.lessonScreen = target;
        root.warmScreens = Object.assign({}, root.warmScreens, { [target]: true });
        GateCore.lessonTargetScreen = target;
        root.targetName = target;
        root.frozen = root.measure();
        GateCore.lessonPageReady = false;
        root.lessonSerial++;
    }

    IpcHandler {
        target: "gate"

        // qs ipc call gate request discord "Send message" 120
        function request(place: string, label: string, cost: string): string {
            GateCore.request(place, label, cost);
            return "requested " + place;
        }

        function status(): string {
            return JSON.stringify({
                "balance": GateCore.balance,
                "gate": GateCore.gate,
                "running": GateCore.running,
                "tasks": GateCore.tasks
            });
        }

        function dismiss(): string {
            const gate = GateCore.gate;
            if (gate !== null)
                GateCore.cancel(gate.id);

            return gate !== null ? "cancelled " + gate.place : "no gate waiting";
        }

        function back(): string {
            GateCore.pillWanted = false;
            return "showing the gate";
        }

        function layout(): string {
            return JSON.stringify({
                "lessonWarm": root.lessonWarm,
                "lessonScreen": root.lessonScreen,
                "targetName": root.targetName,
                "lessonUp": root.lessonUp,
                "gateUp": root.gateUp,
                "target": root.frozen
            });
        }

    }

    // A 1x1 background engine for the Duolingo account XP poll. It stays
    // mapped and click-through; the page never draws anything visible.
    PanelWindow {
        id: progressWindow

        screen: Monitors.mainScreen
        visible: true
        width: 400
        height: 300
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.namespace: "lucid-gate-progress"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}

        anchors {
            top: true
            left: true
        }

        margins {
            top: -500
            left: -600
        }

        GateProgress {
            anchors.fill: parent
        }

    }

    // ---- full gate ------------------------------------------------------
    Variants {
        model: Quickshell.screens

        Scope {
            id: unit

            required property var modelData

            PanelWindow {
                id: win

                readonly property bool live: root.overlayUp && root.targetName === String(unit.modelData.name)
                readonly property var target: (root.frozen !== null && root.frozen.screen === String(unit.modelData.name)) ? root.frozen : null

                screen: unit.modelData
                // keep the layer mapped: mapping it on demand delays the first
                // launch frame until the compositor has shown the surface, which
                // made the morph invisible. The input mask is empty while idle.
                visible: true
                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.namespace: "lucid-gate"
                // the gate owns the keyboard while it is up, so nothing leaks
                // into the window underneath
                WlrLayershell.keyboardFocus: win.live ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
                mask: Region {
                    width: win.live ? win.width : 0
                    height: win.live ? win.height : 0
                }

                anchors {
                    top: true
                    bottom: true
                    left: true
                    right: true
                }

                // swallow everything that is not the card
                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(0, 0, 0, 0.30)
                    // the dim is there on the first frame: a fade here reads as
                    // a delay between Enter and the lock
                    opacity: root.overlayUp ? 1 : 0
                    visible: opacity > 0.001
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: root.overlayUp
                }

                SquircleRect {
                    id: card

                    readonly property var box: win.target
                    readonly property bool up: win.live && root.gateUp

                    // the card *is* the window that asked: its exact rect, no
                    // margins and no recentring, so the gate never floats away
                    // from what it covers
                    x: card.box !== null ? card.box.x : Math.round((win.width - card.width) / 2)
                    y: card.box !== null ? card.box.y : Math.round((win.height - card.height) / 2)
                    width: card.box !== null ? card.box.w : Math.min(Theme.dp(560), win.width - Theme.dp(88))
                    height: card.box !== null ? card.box.h
                        : Math.min(content.implicitHeight, win.height - Theme.dp(88))
                    radius: card.box !== null ? Theme.windowRadius : Theme.rad(26)
                    fillColor: Theme.bgOpaque
                    borderWidth: 1
                    borderColor: Theme.alpha(Theme.accent, 0.30)

                    // geometry stays exact and unmoving; only the transform
                    // runs, so no mask or blur has to chase a growing card
                    opacity: card.up ? 1 : 0
                    visible: card.opacity > 0.001
                    scale: card.up ? 1 : 0.965
                    transformOrigin: Item.Center

                    // visible on the first frame; only the subtle scale settles
                    Behavior on scale {
                        NumberAnimation {
                            duration: Theme.durFastSpatial
                            easing.type: Easing.Bezier
                            easing.bezierCurve: Theme.curveDefaultSpatial
                        }

                    }

                    GateSurface {
                        id: content

                        anchors.fill: parent
                        inset: Theme.dp(22)
                        shown: card.up
                        screenName: String(unit.modelData.name)
                    }




                }

                Shortcut {
                    sequence: "Escape"
                    enabled: win.live && root.gateUp
                    onActivated: {
                        if (GateCore.gate !== null)
                            GateCore.cancel(GateCore.gate.id);

                    }
                }

                // the gate owns the keyboard while it is up; these live on a
                // focused item so they do not depend on Shortcut matching
                Item {
                    anchors.fill: parent
                    focus: win.live && root.gateUp
                    Keys.onLeftPressed: content.step(-1)
                    Keys.onRightPressed: content.step(1)
                    Keys.onReturnPressed: content.activateSelected()
                    Keys.onEnterPressed: content.activateSelected()
                }

                // the lesson card is at its final rect from the start; the
                // GateLaunch inside GateLesson holds the placeholder tile and
                // performs the same morph/iris a normal app launch does
                SquircleRect {
                    id: lessonCard

                    readonly property real margin: Theme.dp(40)
                    readonly property real finalW: Math.min(Theme.dp(1180), win.width - margin * 2)
                    readonly property real finalH: Math.min(Theme.dp(820), win.height - margin * 2)

                    visible: root.lessonUp && win.live
                    clip: false
                    width: finalW
                    height: finalH
                    x: (win.width - finalW) / 2
                    y: (win.height - finalH) / 2
                    radius: 0
                    fillColor: "transparent"
                    borderWidth: 0
                    borderColor: "transparent"
                    opacity: (root.lessonUp && win.live) ? 1 : 0

                    GateLaunch {
                        id: cardLauncher

                        readonly property var origin: GateCore.launchRect
                        readonly property bool hasOrigin: origin !== null && origin.w > 1
                            && (!origin.screen || origin.screen === String(unit.modelData.name))

                        anchors.fill: parent
                        z: 1
                        fromRect: hasOrigin
                            ? Qt.rect(origin.x - lessonCard.x, origin.y - lessonCard.y, origin.w, origin.h)
                            : Qt.rect(0, 0, 1, 1)
                        toRect: Qt.rect(0, 0, parent.width, parent.height)
                        pageReady: GateCore.lessonPageReady
                    }

                    Connections {
                        target: root

                        function onLessonSerialChanged() {
                            // root.overlayUp (and so win.live) is still stale in
                            // the same turn lessonUp flips; compare the target
                            // screen directly so the launch really starts
                            if (!root.lessonUp || root.targetName !== String(unit.modelData.name))
                                return ;

                            if (cardLauncher.hasOrigin) {
                                GateCore.lessonRevealed = false;
                                cardLauncher.start();
                            } else {
                                GateCore.lessonRevealed = true;
                                cardLauncher.reset();
                            }
                        }
                    }

                    Row {
                        z: 2
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: Theme.dp(8)
                        anchors.rightMargin: Theme.dp(10)
                        spacing: Theme.dp(2)
                        visible: root.lessonUp && win.live && GateCore.lessonRevealed

                        IconButton {
                            icon: "home"
                            size: "s"
                            tooltip: Tr.t("Duolingo home")
                            onClicked: {
                                if (lessonLoader.item)
                                    lessonLoader.item.goHome();

                            }
                        }

                        IconButton {
                            icon: "person"
                            size: "s"
                            tooltip: Tr.t("Log in to Duolingo")
                            onClicked: {
                                if (lessonLoader.item)
                                    lessonLoader.item.goLogin();

                            }
                        }

                        IconButton {
                            icon: "refresh"
                            size: "s"
                            tooltip: Tr.t("Reload")
                            onClicked: {
                                if (lessonLoader.item)
                                    lessonLoader.item.reloadView();

                            }
                        }

                        IconButton {
                            icon: "close"
                            size: "s"
                            tooltip: Tr.t("Give up on this lesson")
                            onClicked: GateCore.closeLesson()
                        }

                    }

                    Loader {
                        id: lessonLoader

                        anchors.fill: parent
                        z: 0
                        active: root.warmScreens[String(unit.modelData.name)] === true
                        source: "GateLesson.qml"
                        asynchronous: false
                        onLoaded: {
                            if (item)
                                item.closeRequested.connect(GateCore.closeLesson);

                        }
                    }

                    Binding {
                        target: lessonLoader.item
                        property: "screenName"
                        when: lessonLoader.item !== null
                        value: String(unit.modelData.name)
                    }

                    LText {
                        anchors.centerIn: parent
                        visible: lessonLoader.status === Loader.Error
                        text: Tr.t("Duolingo needs a Quickshell built with QtWebEngine.")
                        role: "bodyMedium"
                        color: Theme.error
                    }

                }

            }

        }

    }

    // ---- the corner pill while a task runs ------------------------------
    Variants {
        model: Quickshell.screens

        Scope {
            id: pillUnit

            required property var modelData

            PanelWindow {
                id: pill

                readonly property bool live: root.pillUp && root.targetName === String(pillUnit.modelData.name)

                screen: pillUnit.modelData
                visible: pill.live
                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.namespace: "lucid-gate-pill"
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                implicitWidth: Theme.dp(392)
                implicitHeight: Theme.dp(180)

                anchors {
                    bottom: true
                    right: true
                }

                margins {
                    bottom: Theme.dp(72)
                    right: Theme.dp(32)
                }

                SquircleRect {
                    anchors.fill: parent
                    radius: Theme.rad(22)
                    fillColor: Theme.bgOpaque
                    borderWidth: 1
                    borderColor: Theme.alpha(Theme.accent, 0.28)
                }

                GateSurface {
                    anchors.fill: parent
                    compact: true
                    screenName: String(pillUnit.modelData.name)
                    inset: Theme.dp(14)
                    showGate: false
                    showTasks: true
                    onlyTask: GateCore.running !== null ? GateCore.running.task : ""
                }

            }

        }

    }

}
