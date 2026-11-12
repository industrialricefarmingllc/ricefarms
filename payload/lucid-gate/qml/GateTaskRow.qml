import QtQuick
import qs
import qs.lucidui
import qs.squircle

// One task line. Used by the desktop card and by the foreground overlay, so
// both hosts stay in step with the daemon without duplicating any logic.
Item {
    id: row

    required property var task
    property bool compact: false
    property color ink: Theme.text
    property color inkDim: Theme.subtext
    property color accent: Theme.accent

    readonly property var session: GateCore.sessionFor(row.task.id)
    readonly property bool running: row.session !== null
    readonly property real remaining: GateCore.remaining(row.session)
    // duolingo (and any future provider that reports its own completion) has
    // no claim button: the page says when the lesson is over, not the clock
    readonly property bool external: row.task.external === true || row.task.kind === "duolingo"
    readonly property bool ready: row.running && !row.external && row.remaining <= 0
    // the reward becomes an unlock while a gate is waiting
    readonly property bool unlocking: GateCore.gate !== null

    signal startRequested(string taskId)

    implicitHeight: row.compact ? Theme.dp(54) : Theme.dp(64)
    width: parent ? parent.width : 0

    SquircleRect {
        anchors.fill: parent
        radius: Theme.rad(14)
        fillColor: row.running ? Theme.alpha(row.accent, 0.10) : Theme.alpha(row.ink, 0.035)
        borderWidth: row.running ? 1 : 0
        borderColor: Theme.alpha(row.accent, 0.24)
    }

    Item {
        id: badge

        x: Theme.dp(8)
        anchors.verticalCenter: parent.verticalCenter
        width: row.compact ? Theme.dp(30) : Theme.dp(36)
        height: width

        SquircleRect {
            anchors.fill: parent
            radius: parent.width / 2
            fillColor: Theme.alpha(row.accent, row.running ? 0.22 : 0.13)
        }

        Icon {
            anchors.centerIn: parent
            name: row.task.icon || "task_alt"
            size: row.compact ? Theme.dp(17) : Theme.dp(20)
            color: row.accent
        }

    }

    Column {
        id: labels

        anchors.left: badge.right
        anchors.leftMargin: Theme.dp(10)
        anchors.right: actions.left
        anchors.rightMargin: Theme.dp(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.dp(2)

        LText {
            width: parent.width
            text: row.task.name || row.task.id
            role: row.compact ? "labelLarge" : "titleSmall"
            color: row.ink
            elide: Text.ElideRight
            maximumLineCount: 1
        }

        LText {
            width: parent.width
            text: {
                if (row.running)
                    return row.external ? "Lesson in progress" : (row.ready ? "Ready to claim" : GateCore.clock(row.remaining) + " left");

                return row.task.detail || "";
            }
            role: "bodySmall"
            color: row.running && row.ready ? row.accent : row.inkDim
            elide: Text.ElideRight
            maximumLineCount: 1
        }

    }

    Item {
        id: actions

        anchors.right: parent.right
        anchors.rightMargin: Theme.dp(7)
        anchors.verticalCenter: parent.verticalCenter
        width: Theme.dp(row.compact ? 78 : 88)
        height: parent.height

        Column {
            visible: !row.running
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            spacing: Theme.dp(2)

            Row {
                anchors.right: parent.right
                height: Theme.dp(15)
                spacing: Theme.dp(1)

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "memory"
                    size: Theme.dp(12)
                    color: row.inkDim
                }

                LText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: (row.unlocking ? "unlock" : String(row.task.reward || 0))
                    role: "labelSmall"
                    color: row.inkDim
                    tabular: true
                }

            }

            Button {
                width: parent.width
                text: row.task.kind === "duolingo" ? "Study" : (row.task.kind === "browser" ? "Open" : "Start")
                variant: "tonal"
                size: "xs"
                onClicked: row.startRequested(row.task.id)
            }

        }

        Button {
            visible: row.running && row.ready
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            text: row.unlocking ? "Claim" : "Done"
            variant: "filled"
            size: "xs"
            onClicked: GateCore.completeTask(row.task.id)
        }

        IconButton {
            visible: row.running && !row.ready
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            icon: "close"
            variant: "standard"
            size: "xs"
            tooltip: "Give up on " + (row.task.name || row.task.id)
            onClicked: {
                if (row.session !== null)
                    GateCore.abandon(row.session.id);

            }
        }

    }

    // a hairline of progress along the bottom edge, so a glance is enough
    Rectangle {
        visible: row.running && !row.external
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Theme.dp(7)
        height: Theme.dp(3)
        radius: height / 2
        color: Theme.alpha(row.accent, 0.16)

        Rectangle {
            width: parent.width * GateCore.progress(row.session)
            height: parent.height
            radius: parent.radius
            color: row.accent

            Behavior on width {
                NumberAnimation {
                    duration: 450
                    easing.type: Easing.OutCubic
                }

            }

        }

    }

}
