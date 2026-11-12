import QtQuick
import qs
import qs.lucidui
import qs.squircle

// The reusable gate face.  The desktop card mounts it small; the foreground
// overlay mounts it large.  All state comes from GateCore, so the two hosts
// never disagree about the balance or a running task.
Item {
    id: surface

    property bool compact: false
    property bool showHeader: true
    property bool showGate: true
    property bool showTasks: true
    // "" shows the whole task list; a task id narrows it to the running one
    property string onlyTask: ""
    property color ink: Theme.text
    property color inkDim: Theme.subtext
    property color accent: Theme.accent
    property int inset: surface.compact ? Theme.dp(16) : Theme.dp(22)

    implicitHeight: column.implicitHeight + surface.inset * 2

    readonly property var pending: surface.showGate ? GateCore.gate : null
    readonly property var visibleTasks: {
        const all = GateCore.tasks;
        if (surface.onlyTask === "")
            return all;

        return all.filter((task) => task.id === surface.onlyTask);
    }

    function spendLabel(gate) {
        return "Spend " + Number(gate.cost || 0);
    }

    function shortfall(gate) {
        return Math.max(0, Number(gate.cost || 0) - GateCore.balance);
    }

    Column {
        id: column

        x: surface.inset
        y: surface.inset
        width: Math.max(0, surface.width - surface.inset * 2)
        spacing: surface.compact ? Theme.dp(10) : Theme.dp(14)

        // ---- balance ----------------------------------------------------
        Item {
            width: parent.width
            height: surface.compact ? Theme.dp(32) : Theme.dp(42)
            visible: surface.showHeader

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.dp(7)

                Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: surface.compact ? Theme.dp(24) : Theme.dp(30)
                    height: width

                    SquircleRect {
                        anchors.fill: parent
                        radius: width / 2
                        fillColor: Theme.primary
                    }

                    Icon {
                        anchors.centerIn: parent
                        name: "memory"
                        size: surface.compact ? Theme.dp(15) : Theme.dp(18)
                        color: "#ffffff"
                    }

                }

                LText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: GateCore.balance
                    role: surface.compact ? "titleLarge" : "headlineMedium"
                    color: surface.ink
                    tabular: true
                }

            }

            LText {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: GateCore.pendingCount > 1 ? GateCore.pendingCount + " PLACES WAITING"
                    : (surface.pending !== null ? "A PLACE IS WAITING" : "")
                role: "labelSmall"
                color: surface.pending !== null ? surface.accent : surface.inkDim
            }

        }

        // ---- the place asking to be let in ------------------------------
        Item {
            width: parent.width
            height: visible ? gateBox.implicitHeight + Theme.dp(24) : 0
            visible: surface.showGate && surface.pending !== null

            SquircleRect {
                anchors.fill: parent
                radius: Theme.rad(16)
                fillColor: Theme.alpha(surface.accent, 0.10)
                borderWidth: 1
                borderColor: Theme.alpha(surface.accent, 0.28)
            }

            Column {
                id: gateBox

                x: Theme.dp(14)
                y: Theme.dp(12)
                width: parent.width - Theme.dp(28)
                spacing: Theme.dp(4)

                Row {
                    height: Theme.dp(18)
                    spacing: Theme.dp(5)

                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "lock"
                        size: Theme.dp(15)
                        color: surface.accent
                    }

                    LText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: surface.pending !== null ? surface.pending.place : ""
                        role: "labelLarge"
                        color: surface.ink
                    }

                    LText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "wants in"
                        role: "bodySmall"
                        color: surface.inkDim
                    }

                }

                LText {
                    width: parent.width
                    text: surface.pending !== null ? surface.pending.label : ""
                    role: "bodySmall"
                    color: surface.inkDim
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                Row {
                    spacing: Theme.dp(10)

                    Button {
                        text: surface.pending !== null ? surface.spendLabel(surface.pending) : ""
                        variant: "filled"
                        size: "xs"
                        disabled: surface.pending === null || surface.shortfall(surface.pending) > 0
                        onClicked: {
                            if (surface.pending !== null)
                                GateCore.unlock(surface.pending.id);

                        }
                    }

                    LText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            if (surface.pending === null)
                                return "";

                            const missing = surface.shortfall(surface.pending);
                            if (missing > 0)
                                return "or finish a task — " + missing + " more to spend";

                            return "or finish a task below";
                        }
                        role: "bodySmall"
                        color: surface.inkDim
                    }

                }

            }

        }

        // ---- the tasks that pay for it ----------------------------------
        Column {
            width: parent.width
            spacing: Theme.dp(6)
            visible: surface.showTasks

            Repeater {
                model: surface.visibleTasks

                delegate: GateTaskRow {
                    required property var modelData

                    width: column.width
                    compact: surface.compact
                    ink: surface.ink
                    inkDim: surface.inkDim
                    accent: surface.accent
                    task: modelData
                    onStartRequested: (taskId) => GateCore.startTask(taskId)
                }

            }

            LText {
                width: parent.width
                visible: surface.visibleTasks.length === 0
                text: "No tasks configured. Add one to ~/.config/lucid-gate/config.json."
                role: "bodySmall"
                color: surface.inkDim
                wrapMode: Text.WordWrap
            }

        }

        // ---- footer -----------------------------------------------------
        Item {
            width: parent.width
            height: footerRow.implicitHeight

            Row {
                id: footerRow

                width: parent.width
                spacing: Theme.dp(8)

                LText {
                    width: parent.width - (back.visible ? back.width + Theme.dp(8) : 0)
                    text: {
                        if (GateCore.lastError !== "")
                            return GateCore.lastError;

                        if (!GateCore.available)
                            return "The gate daemon is not answering; run: gate status";

                        if (surface.pending !== null)
                            return "Tasks done now open the place for free. Without one, they add to the balance.";

                        return "Voluntary tasks add to the balance. The balance opens the next place.";
                    }
                    role: "bodySmall"
                    color: GateCore.lastError !== "" ? Theme.error : surface.inkDim
                    wrapMode: Text.WordWrap
                }

                Button {
                    id: back

                    anchors.verticalCenter: parent.verticalCenter
                    visible: surface.onlyTask !== "" && GateCore.gate !== null
                    text: "Back to gate"
                    variant: "text"
                    size: "xs"
                    onClicked: GateCore.pillWanted = false
                }

            }

        }

    }

}
