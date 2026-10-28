import QtQuick
import "squircle"

// One chat turn. User turns sit on the right in the primary container; replies
// sit on the left on a surface container, with the language that produced them
// in a small label above the bubble.
Item {
    id: root

    property string kind: "assistant"
    property string text: ""
    property string languageName: ""
    property int order: 0

    readonly property bool user: root.kind === "user"
    readonly property bool error: root.kind === "error"
    readonly property bool instruction: root.kind === "instruction"
    readonly property bool answer: root.kind === "answer"
    readonly property bool refined: root.kind === "refined"
    readonly property bool markdown: !root.user && !root.error && !root.instruction
    readonly property bool labelled: !root.user && !root.error && !root.instruction && root.languageName !== ""
    // The body copy is deliberately 0.8 of the old 15/14 px sizes; labels and
    // controls keep their own type steps.
    readonly property real bodyScale: 0.8
    readonly property int bodySize: Theme.fs((root.instruction ? 14 : 15) * root.bodyScale)
    readonly property int padH: Theme.dp(15)
    readonly property int padV: Theme.dp(10)
    readonly property real maxBubble: root.width * 0.86
    readonly property color fill: root.error ? Theme.errorContainer : (root.user ? Theme.userBubble : (root.instruction ? Theme.surfaceHighest : Theme.assistantBubble))
    readonly property color ink: root.error ? Theme.onErrorContainer : (root.user ? Theme.userText : Theme.text)

    width: parent ? parent.width : 0
    height: content.height
    opacity: 0
    scale: 0.97

    Item {
        id: content

        width: root.width
        height: (labelRow.visible ? labelRow.height + Theme.dp(3) : 0) + bubble.height

        Row {
            id: labelRow

            visible: root.labelled
            x: Theme.dp(6)
            height: visible ? Theme.dp(17) : 0
            spacing: Theme.dp(6)

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.languageName
                color: Theme.subtext
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fs(11)
                font.variableAxes: Theme.axes(Theme.fs(11), 560, 0)
                font.letterSpacing: 0.3
            }

        }

        SquircleRect {
            id: bubble

            y: labelRow.height + (labelRow.visible ? Theme.dp(3) : 0)
            x: (root.user || root.instruction) ? content.width - width : 0
            width: Math.min(root.maxBubble, body.implicitWidth + root.padH * 2)
            height: body.implicitHeight + root.padV * 2
            radius: Theme.rad(22)
            topLeftRadius: Theme.rad(22)
            topRightRadius: Theme.rad(22)
            bottomLeftRadius: (root.user || root.instruction) ? Theme.rad(22) : Theme.rad(7)
            bottomRightRadius: (root.user || root.instruction) ? Theme.rad(7) : Theme.rad(22)
            smoothing: Theme.squircleF
            fillColor: root.fill

            Behavior on fillColor {
                ColorAnimation {
                    duration: Theme.ms(220)
                }

            }

            Text {
                id: body

                x: root.padH
                y: root.padV
                width: bubble.width - root.padH * 2
                text: root.text
                textFormat: root.markdown ? Text.MarkdownText : Text.PlainText
                wrapMode: Text.Wrap
                color: root.ink
                linkColor: Theme.accent
                onLinkActivated: (link) => {
                    if (/^https?:\/\//i.test(link))
                        Qt.openUrlExternally(link);
                }
                font.family: Theme.fontFamily
                font.pixelSize: root.bodySize
                font.variableAxes: Theme.axes(root.bodySize, 420, 0)
                font.italic: root.instruction
                // Keep the line box at the font's natural height; a larger
                // multiplier adds visible space below the last line.
                lineHeight: 1.0
            }

        }

    }

    ParallelAnimation {
        id: enter

        PauseAnimation {
            duration: Math.min(180, Math.max(0, root.order) * 38)
        }

        NumberAnimation {
            target: root
            property: "opacity"
            from: 0
            to: 1
            duration: Theme.ms(280)
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveEmphasized
        }

        // Animate the inner content, never the delegate's own y: a ListView
        // owns the delegate position, and writing y there collapses every
        // turn to the top-left.
        NumberAnimation {
            target: content
            property: "y"
            from: 12
            to: 0
            duration: Theme.ms(420)
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveSpatial
        }

        NumberAnimation {
            target: root
            property: "scale"
            from: 0.97
            to: 1
            duration: Theme.ms(420)
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveSpatial
        }

    }

    Component.onCompleted: enter.start()

}
