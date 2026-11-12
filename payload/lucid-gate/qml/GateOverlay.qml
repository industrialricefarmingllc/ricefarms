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

    readonly property bool lessonUp: GateCore.lessonOpen && (GateCore.running !== null || GateCore.lessonLinger)
    readonly property bool pillMode: GateCore.pillWanted && GateCore.running !== null && !root.lessonUp
    readonly property bool gateUp: GateCore.loaded && GateCore.gate !== null && !root.pillMode && !root.lessonUp
    readonly property bool pillUp: GateCore.loaded && root.pillMode
    readonly property bool overlayUp: root.gateUp || root.lessonUp
    property string targetName: ""
    property var frozen: null
    // the WebEngine view is expensive and QtWebEngine does not like being torn
    // down while a JavaScript callback is in flight: once created, keep it
    // warm for the shell's lifetime and hide it between lessons
    property bool lessonWarm: false
    property string lessonScreen: ""
    property bool lessonAtFinal: false

    function measure() {
        const toplevel = Hyprland.activeToplevel;
        if (!toplevel || !toplevel.lastIpcObject)
            return null;

        const info = toplevel.lastIpcObject;
        const at = info.at;
        const size = info.size;
        if (!at || !size)
            return null;

        const monitors = Hyprland.monitors ? Hyprland.monitors.values : [];
        let monitor = null;
        for (let i = 0; i < monitors.length; i++) {
            if (monitors[i].id === info.monitor)
                monitor = monitors[i];
        }
        if (monitor === null)
            return null;

        const ax = at.x !== undefined ? at.x : at[0];
        const ay = at.y !== undefined ? at.y : at[1];
        const aw = size.x !== undefined ? size.x : size[0];
        const ah = size.y !== undefined ? size.y : size[1];
        if (!(aw > 0 && ah > 0))
            return null;

        return {
            "screen": monitor.name,
            "x": ax - monitor.x,
            "y": ay - monitor.y,
            "w": aw,
            "h": ah
        };
    }

    function begin() {
        const monitor = Hyprland.focusedMonitor;
        root.targetName = monitor ? monitor.name : (Quickshell.screens.length > 0 ? Quickshell.screens[0].name : "");
        root.frozen = root.measure();
    }

    onGateUpChanged: {
        if (root.gateUp)
            root.begin();

    }
    onPillUpChanged: {
        if (root.pillUp)
            root.begin();

    }
    onLessonUpChanged: {
        if (!root.lessonUp)
            return ;

        root.lessonWarm = true;
        const names = Quickshell.screens.map((screen) => screen.name);
        let target = "";
        const rect = GateCore.launchRect;
        if (rect && rect.screen && names.indexOf(rect.screen) >= 0)
            target = rect.screen;
        if (target === "") {
            const monitor = Hyprland.focusedMonitor;
            target = (monitor && monitor.name) ? monitor.name : (names.length > 0 ? names[0] : "");
        }
        if (root.lessonScreen === "" || names.indexOf(root.lessonScreen) < 0)
            root.lessonScreen = target;
        root.targetName = root.lessonScreen;
        root.frozen = root.measure();
        root.lessonAtFinal = false;
        lessonLand.restart();
    }

    Timer {
        id: lessonLand

        interval: 20
        onTriggered: root.lessonAtFinal = true
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
                "lessonAtFinal": root.lessonAtFinal,
                "targetName": root.targetName,
                "lessonUp": root.lessonUp
            });
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
                visible: win.live
                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.namespace: "lucid-gate"
                // the gate owns the keyboard while it is up, so nothing leaks
                // into the window underneath
                WlrLayershell.keyboardFocus: win.live ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

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
                }

                MouseArea {
                    anchors.fill: parent
                }

                // the window that asked, dimmed again so the card has a subject
                SquircleRect {
                    visible: root.gateUp && win.target !== null
                    x: win.target ? win.target.x : 0
                    y: win.target ? win.target.y : 0
                    width: win.target ? win.target.w : 0
                    height: win.target ? win.target.h : 0
                    radius: Theme.windowRadius
                    fillColor: Qt.rgba(0, 0, 0, 0.42)
                    borderWidth: 1
                    borderColor: Theme.alpha(Theme.accent, 0.34)
                }

                SquircleRect {
                    id: card

                    visible: root.gateUp
                    readonly property real margin: Theme.dp(44)

                    width: Math.min(Theme.dp(540), win.width - card.margin * 2)
                    height: Math.min(content.implicitHeight, win.height - card.margin * 2)
                    radius: Theme.rad(26)
                    fillColor: Theme.bgOpaque
                    borderWidth: 1
                    borderColor: Theme.alpha(Theme.accent, 0.30)
                    x: {
                        if (win.target === null)
                            return (win.width - card.width) / 2;

                        return Math.max(card.margin, Math.min(win.width - card.width - card.margin,
                            win.target.x + (win.target.w - card.width) / 2));
                    }
                    y: {
                        if (win.target === null)
                            return (win.height - card.height) / 2;

                        return Math.max(card.margin, Math.min(win.height - card.height - card.margin,
                            win.target.y + (win.target.h - card.height) / 2));
                    }
                    scale: win.live ? 1 : 0.97

                    Behavior on scale {
                        NumberAnimation {
                            duration: Theme.durMedium
                            easing.type: Easing.OutCubic
                        }

                    }

                    GateSurface {
                        id: content

                        anchors.fill: parent
                        inset: Theme.dp(22)
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

                // the lesson gets the whole stage: the web engine renders in
                // this card, not in a browser window of its own
                SquircleRect {
                    id: lessonCard

                    readonly property real margin: Theme.dp(40)
                    readonly property real finalW: Math.min(Theme.dp(1180), win.width - margin * 2)
                    readonly property real finalH: Math.min(Theme.dp(820), win.height - margin * 2)
                    // the logo rect passed by the widget; only when it belongs
                    // to this output
                    readonly property var origin: (GateCore.launchRect
                        && (!GateCore.launchRect.screen || GateCore.launchRect.screen === String(unit.modelData.name)))
                        ? GateCore.launchRect : null
                    readonly property bool atFinal: root.lessonAtFinal

                    visible: root.lessonUp
                    clip: true
                    width: (atFinal || origin === null) ? finalW : Math.max(1, origin.w)
                    height: (atFinal || origin === null) ? finalH : Math.max(1, origin.h)
                    x: (atFinal || origin === null) ? (win.width - finalW) / 2 : origin.x
                    y: (atFinal || origin === null) ? (win.height - finalH) / 2 : origin.y
                    // borderless: the page is the window. The controls live in
                    // the transparent strip above it.
                    radius: (atFinal || origin === null) ? 0 : Math.min(width, height) / 2
                    fillColor: "transparent"
                    borderWidth: 0
                    borderColor: "transparent"
                    opacity: root.lessonUp ? 1 : 0

                    Behavior on width {
                        enabled: lessonCard.atFinal
                        NumberAnimation {
                            duration: Theme.durFastSpatial
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on height {
                        enabled: lessonCard.atFinal
                        NumberAnimation {
                            duration: Theme.durFastSpatial
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on x {
                        enabled: lessonCard.atFinal
                        NumberAnimation {
                            duration: Theme.durFastSpatial
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on y {
                        enabled: lessonCard.atFinal
                        NumberAnimation {
                            duration: Theme.durFastSpatial
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on radius {
                        enabled: lessonCard.atFinal
                        NumberAnimation {
                            duration: Theme.durFastSpatial
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.durFastSpatial
                            easing.type: Easing.OutCubic
                        }
                    }

                    Item {
                        id: launchMark

                        readonly property real markSize: Math.min(parent.width, parent.height) * 0.56

                        anchors.fill: parent
                        visible: !lessonCard.atFinal

                        LoadingIndicator {
                            anchors.centerIn: parent
                            width: launchMark.markSize * 1.66 / 0.84
                            height: width
                        }

                        Image {
                            anchors.centerIn: parent
                            width: launchMark.markSize
                            height: width
                            source: GateCore.assetsPath + "/duolingo-owl.png"
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                        }

                    }

                    Loader {
                        id: lessonLoader

                        anchors.fill: parent
                        active: root.lessonWarm && String(unit.modelData.name) === root.lessonScreen
                        opacity: lessonCard.atFinal ? 1 : 0
                        source: "GateLesson.qml"
                        asynchronous: false
                        onLoaded: {
                            if (item)
                                item.closeRequested.connect(GateCore.closeLesson);

                        }

                        Behavior on opacity {
                            NumberAnimation {
                                duration: Theme.durMedium
                                easing.type: Easing.OutCubic
                            }
                        }
                    }

                    LText {
                        anchors.centerIn: parent
                        visible: lessonLoader.status === Loader.Error
                        text: "Duolingo needs a Quickshell built with QtWebEngine."
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
                    inset: Theme.dp(14)
                    showGate: false
                    showTasks: true
                    onlyTask: GateCore.running !== null ? GateCore.running.task : ""
                }

            }

        }

    }

}
