import QtQuick
import qs
import qs.lucidui
import qs.squircle

// The desktop face: a 152 px quarter card.
//
// Compute top-left, one swipeable task per page (only Duolingo for now) and
// what that task pays below. There is no start button: the logo is the target,
// and the strip bounces back like an embla carousel when there is one page.
WidgetBody {
    id: w

    defaultTone: "surface"

    readonly property var items: {
        const out = [];
        for (let i = 0; i < GateCore.tasks.length; i++) {
            const task = GateCore.tasks[i];
            if (task.logo || task.kind === "duolingo" || task.kind === "instant") {
                out.push(Object.assign({}, task, {
                    "logo": task.logo || (task.kind === "duolingo" ? "duolingo-owl.png" : "")
                }));
            }
        }
        return out;
    }
    readonly property var current: carousel.page < items.length ? items[carousel.page] : null
    readonly property int pad: Theme.dp(11)

    // ---- compute ---------------------------------------------------------
    Row {
        id: computeRow

        x: w.pad
        y: w.pad
        spacing: Theme.dp(6)

        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.dp(24)
            height: width

            SquircleRect {
                anchors.fill: parent
                radius: width / 2
                fillColor: Theme.primary
            }

            Icon {
                anchors.centerIn: parent
                name: "memory"
                size: Theme.dp(15)
                color: "#ffffff"
            }

        }

        LText {
            anchors.verticalCenter: parent.verticalCenter
            text: GateCore.balance
            role: "labelMedium"
            color: Theme.text
            tabular: true
        }

    }

    // ---- the task strip --------------------------------------------------
    Flickable {
        id: carousel

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: computeRow.bottom
        anchors.topMargin: Theme.dp(2)
        anchors.bottom: reward.top
        anchors.bottomMargin: Theme.dp(2)
        contentWidth: width * Math.max(1, w.items.length)
        contentHeight: height
        boundsBehavior: Flickable.DragAndOvershootBounds
        flickableDirection: Flickable.HorizontalFlick
        clip: true
        pressDelay: 0

        readonly property int page: {
            if (w.items.length <= 1)
                return 0;

            return Math.max(0, Math.min(w.items.length - 1, Math.round(contentX / Math.max(1, width))));
        }

        function snapToPage() {
            if (w.items.length <= 1) {
                snap.to = 0;
                snap.start();
                return ;
            }
            const target = Math.max(0, Math.min(w.items.length - 1, Math.round(contentX / Math.max(1, width)))) * width;
            snap.to = target;
            snap.start();
        }

        onMovementEnded: snapToPage()

        NumberAnimation {
            id: snap

            target: carousel
            property: "contentX"
            duration: Theme.durMedium
            easing.type: Easing.OutCubic
        }

        Repeater {
            model: w.items

            delegate: Item {
                required property var modelData
                required property int index

                x: index * carousel.width
                width: carousel.width
                height: carousel.height

                Image {
                    id: mark

                    anchors.centerIn: parent
                    visible: modelData.logo !== ""
                    width: Math.min(parent.width - Theme.dp(24), Theme.dp(58))
                    height: width
                    source: modelData.logo ? (GateCore.assetsPath + "/" + modelData.logo) : ""
                    sourceSize.width: Math.round(width * 2)
                    sourceSize.height: Math.round(height * 2)
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                    scale: w.hovered ? 1.06 : 1

                    Behavior on scale {
                        NumberAnimation {
                            duration: Math.round(Theme.durShort * 1.5)
                            easing.type: Theme.easeStandard
                        }
                    }
                }

                Icon {
                    anchors.centerIn: parent
                    visible: modelData.logo === ""
                    name: modelData.icon || "developer_board"
                    size: Theme.dp(44)
                    color: Theme.primary
                    scale: w.hovered ? 1.06 : 1

                    Behavior on scale {
                        NumberAnimation {
                            duration: Math.round(Theme.durShort * 1.5)
                            easing.type: Theme.easeStandard
                        }
                    }
                }

                function engage() {
                    const point = mark.mapToItem(null, mark.width / 2, mark.height / 2);
                    GateCore.startTask(modelData.id, {
                        "x": point.x - mark.width / 2,
                        "y": point.y - mark.height / 2,
                        "w": mark.width,
                        "h": mark.height,
                        "screen": (w.host && w.host.board && w.host.board.screenName !== "")
                            ? w.host.board.screenName : ""
                    });
                }

                TapHandler {
                    onTapped: engage()
                }

            }

        }

    }

    // ---- what it pays ----------------------------------------------------
    SquircleRect {
        id: reward

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.dp(10)
        visible: w.current !== null
        width: rewardRow.implicitWidth + Theme.dp(16)
        height: Theme.dp(22)
        radius: height / 2
        fillColor: Theme.primary

        Row {
            id: rewardRow

            anchors.centerIn: parent
            spacing: Theme.dp(3)

            Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "memory"
                size: Theme.dp(12)
                color: Theme.fgPrimary
            }

            LText {
                id: rewardLabel

                anchors.verticalCenter: parent.verticalCenter
                text: w.current !== null ? String(w.current.reward || 0) : ""
                role: "labelMedium"
                color: Theme.fgPrimary
                tabular: true
            }

        }

    }

}
