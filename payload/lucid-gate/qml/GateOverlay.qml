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
    // one warm WebEngine per output: switching outputs must not tear the old
    // one down (that was the crash), and a widget on another output opens there
    property var warmScreens: ({})
    readonly property bool lessonWarm: Object.keys(root.warmScreens).length > 0
    property string lessonScreen: ""
    property int lessonSerial: 0

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
                "lessonUp": root.lessonUp
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
                    visible: root.overlayUp
                    color: Qt.rgba(0, 0, 0, 0.30)
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: root.overlayUp
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

                // the lesson card is at its final rect from the start; the
                // GateLaunch inside GateLesson holds the placeholder tile and
                // performs the same morph/iris a normal app launch does
                SquircleRect {
                    id: lessonCard

                    readonly property real margin: Theme.dp(40)
                    readonly property real finalW: Math.min(Theme.dp(1180), win.width - margin * 2)
                    readonly property real finalH: Math.min(Theme.dp(820), win.height - margin * 2)

                    visible: root.lessonUp
                    clip: false
                    width: finalW
                    height: finalH
                    x: (win.width - finalW) / 2
                    y: (win.height - finalH) / 2
                    radius: 0
                    fillColor: "transparent"
                    borderWidth: 0
                    borderColor: "transparent"
                    opacity: root.lessonUp ? 1 : 0

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.durFastSpatial
                            easing.type: Easing.OutCubic
                        }
                    }

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
                            if (!root.lessonUp || !win.live)
                                return ;

                            if (cardLauncher.hasOrigin)
                                cardLauncher.start();
                            else
                                cardLauncher.reset();
                        }
                    }

                    Row {
                        z: 2
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: Theme.dp(8)
                        anchors.rightMargin: Theme.dp(10)
                        spacing: Theme.dp(2)
                        visible: root.lessonUp

                        IconButton {
                            icon: "home"
                            size: "s"
                            tooltip: "Duolingo home"
                            onClicked: {
                                if (lessonLoader.item)
                                    lessonLoader.item.goHome();

                            }
                        }

                        IconButton {
                            icon: "person"
                            size: "s"
                            tooltip: "Log in to Duolingo"
                            onClicked: {
                                if (lessonLoader.item)
                                    lessonLoader.item.goLogin();

                            }
                        }

                        IconButton {
                            icon: "refresh"
                            size: "s"
                            tooltip: "Reload"
                            onClicked: {
                                if (lessonLoader.item)
                                    lessonLoader.item.reloadView();

                            }
                        }

                        IconButton {
                            icon: "close"
                            size: "s"
                            tooltip: "Give up on this lesson"
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
