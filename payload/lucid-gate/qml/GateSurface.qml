import QtQuick
import qs
import qs.lucidui
import qs.squircle

// The reusable gate face.
//
//   gate mode     Compute top-left, then a horizontal marquee of ways past
//                 the gate: spend the balance first, then the tasks.  The
//                 host stretches this over the window that asked.
//   compact mode  the corner pill while a task runs: just that task's row.
Item {
    id: surface

    property bool compact: false
    property bool showHeader: true
    property bool showGate: true
    property bool showTasks: true
    // true while the host is presenting this face; replays the entrance
    property bool shown: false
    // "" shows the whole task list; a task id narrows it to the running one
    property string onlyTask: ""
    property color ink: Theme.text
    property color inkDim: Theme.subtext
    property color accent: Theme.accent
    property int inset: surface.compact ? Theme.dp(16) : Theme.dp(22)
    property int introSerial: 0
    // the card the arrows move and Enter opens; mouse taps move it too
    property int selectedIndex: 0
    // output this face lives on, so a launch can name its target
    property string screenName: ""

    implicitHeight: surface.compact ? compactColumn.implicitHeight + surface.inset * 2 : Theme.dp(320)

    readonly property var pending: surface.showGate ? GateCore.gate : null
    readonly property var visibleTasks: {
        const all = GateCore.tasks;
        if (surface.onlyTask === "")
            return all;

        return all.filter((task) => task.id === surface.onlyTask);
    }
    // the marquee: an unlock always leads, then every task that can pay for it
    readonly property var options: {
        const list = [];
        if (surface.pending !== null)
            list.push({
                "kind": "unlock",
                "gate": surface.pending
            });

        const tasks = GateCore.tasks || [];
        for (let i = 0; i < tasks.length; i++) {
            if (!surface.showTasks)
                break;

            list.push({
                "kind": "task",
                "task": tasks[i]
            });
        }
        return list;
    }

    onShownChanged: {
        if (surface.shown)
            surface.introSerial++;

    }
    // state reloads hand back a fresh gate object for the same gate; only a
    // different id means the marquee should go back to the unlock card
    readonly property string pendingGateId: surface.pending !== null ? String(surface.pending.id) : ""
    onPendingGateIdChanged: {
        if (surface.pendingGateId === "")
            return ;

        surface.selectedIndex = 0;
        strip.centerOn(0);
    }
    onOptionsChanged: {
        if (surface.selectedIndex >= surface.options.length)
            surface.selectedIndex = Math.max(0, surface.options.length - 1);

    }

    // the selected card's rect in window coordinates, so the lesson launch
    // grows out of the card that was chosen here just like the desktop card
    function originForIndex(index) {
        if (!stripRow || !strip || index < 0 || index >= surface.options.length)
            return null;

        const point = stripRow.mapToItem(null, index * strip.step, 0);
        return {
            "x": point.x,
            "y": point.y,
            "w": strip.cardWidth,
            "h": strip.cardHeight,
            "screen": surface.screenName
        };
    }

    function activateIndex(index) {
        surface.selectedIndex = index;
        const option = surface.options[index];
        if (!option)
            return ;

        if (option.kind === "unlock") {
            const gate = option.gate;
            if (gate !== null && (GateCore.freeUnlock
                || GateCore.balance >= Number(gate.cost || 0)))
                GateCore.unlock(gate.id);
        } else if (option.task) {
            if (GateCore.sessionFor(option.task.id) === null)
                GateCore.startTask(option.task.id, surface.originForIndex(index));
        }
    }

    function activateSelected() {
        surface.activateIndex(surface.selectedIndex);
    }

    function step(delta) {
        if (surface.options.length === 0)
            return ;

        const next = Math.max(0, Math.min(surface.options.length - 1,
            surface.selectedIndex + Number(delta)));
        if (next === surface.selectedIndex)
            return ;

        surface.selectedIndex = next;
        strip.centerOn(next);
    }

    // ---- compact: the corner pill ---------------------------------------
    Column {
        id: compactColumn

        visible: surface.compact
        x: surface.inset
        y: surface.inset
        width: Math.max(0, surface.width - surface.inset * 2)
        spacing: Theme.dp(10)

        Item {
            width: parent.width
            height: Theme.dp(32)
            visible: surface.showHeader

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.dp(7)

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
                    role: "titleLarge"
                    color: surface.ink
                    tabular: true
                }

            }

            LText {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: surface.pending !== null ? Tr.t("A PLACE IS WAITING") : ""
                role: "labelSmall"
                color: surface.pending !== null ? surface.accent : surface.inkDim
            }

        }

        Column {
            width: parent.width
            spacing: Theme.dp(6)
            visible: surface.showTasks

            Repeater {
                model: surface.visibleTasks

                delegate: GateTaskRow {
                    required property var modelData

                    width: compactColumn.width
                    compact: true
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
                text: Tr.t("No tasks configured. Add one to ~/.config/lucid-gate/config.json.")
                role: "bodySmall"
                color: surface.inkDim
                wrapMode: Text.WordWrap
            }

        }

        Item {
            width: parent.width
            height: footerRow.implicitHeight

            Row {
                id: footerRow

                width: parent.width
                spacing: Theme.dp(8)

                LText {
                    width: parent.width
                    text: {
                        if (GateCore.lastError !== "")
                            return GateCore.lastError;

                        if (!GateCore.available)
                            return Tr.t("The gate daemon is not answering; run: gate status");

                        if (surface.pending !== null)
                            return Tr.t("Tasks done now open the place for free.");

                        return Tr.t("Voluntary tasks add to the balance.");
                    }
                    role: "bodySmall"
                    color: GateCore.lastError !== "" ? Theme.error : surface.inkDim
                    wrapMode: Text.WordWrap
                }

            }

        }

    }

    // ---- gate: Compute + the marquee of options --------------------------
    Item {
        id: face

        anchors.fill: parent
        visible: !surface.compact

        // compute, top-left, unchanged from the desktop card
        Row {
            id: faceCompute

            x: surface.inset
            y: surface.inset
            spacing: Theme.dp(7)

            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.dp(30)
                height: width

                SquircleRect {
                    anchors.fill: parent
                    radius: width / 2
                    fillColor: Theme.primary
                }

                Icon {
                    anchors.centerIn: parent
                    name: "memory"
                    size: Theme.dp(18)
                    color: "#ffffff"
                }

            }

            LText {
                anchors.verticalCenter: parent.verticalCenter
                text: GateCore.balance
                role: "headlineMedium"
                color: surface.ink
                tabular: true
            }

        }

        Item {
            id: bottomBar

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: surface.inset
            height: dots.visible ? dots.height + Theme.dp(10) : 0

            Row {
                id: dots

                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.dp(6)
                visible: surface.options.length > 1 && strip.scrollable

                Repeater {
                    model: surface.options.length

                    Rectangle {
                        required property int index

                        anchors.verticalCenter: parent.verticalCenter
                        width: index === strip.page ? Theme.dp(18) : Theme.dp(6)
                        height: Theme.dp(6)
                        radius: height / 2
                        color: index === strip.page ? surface.accent : Theme.alpha(surface.ink, 0.18)

                        Behavior on width {
                            NumberAnimation {
                                duration: Theme.durFastSpatial
                                easing.type: Easing.Bezier
                                easing.bezierCurve: Theme.curveDefaultSpatial
                            }

                        }

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.durFastEffects
                                easing.type: Easing.Bezier
                                easing.bezierCurve: Theme.curveEffects
                            }

                        }

                    }

                }

            }

        }

        Item {
            id: stripArea

            anchors.top: faceCompute.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: bottomBar.top
            anchors.topMargin: Theme.dp(10)
            anchors.bottomMargin: Theme.dp(10)
            anchors.leftMargin: surface.inset
            anchors.rightMargin: surface.inset

            Flickable {
                id: strip

                anchors.fill: parent
                // leading/trailing gutters let the first and last card reach
                // the middle of the viewport just like every card between them
                // always leave half a viewport on each side, so any card can
                // sit in the middle even when every card already fits
                contentWidth: Math.max(width, rowWidth + leading * 2)
                contentHeight: height
                boundsBehavior: Flickable.DragAndOvershootBounds
                flickableDirection: Flickable.HorizontalFlick
                clip: true
                pressDelay: 0

                readonly property real gap: Theme.dp(12)
                readonly property real cardWidth: Math.max(Theme.dp(196),
                    Math.min(Theme.dp(340), (strip.width - gap * 3) / 4))
                readonly property real cardHeight: Math.min(strip.height,
                    Math.max(Theme.dp(240), strip.cardWidth * 1.35))
                readonly property real step: strip.cardWidth + strip.gap
                readonly property real rowWidth: surface.options.length * strip.cardWidth
                    + Math.max(0, surface.options.length - 1) * strip.gap
                // half a viewport less half a card on each side, so card i
                // rests at exactly i * step
                readonly property real leading: Math.max(0, (width - strip.cardWidth) / 2)
                // a card wider than the viewport still centres: it just has
                // to start with the same overhang on both sides
                readonly property real firstCenter: Math.max(0, (strip.cardWidth - width) / 2)
                // true once there is more than one card to move between
                readonly property bool scrollable: contentWidth > width + 1
                readonly property int page: {
                    if (!strip.scrollable || surface.options.length <= 1)
                        return 0;

                    return Math.max(0, Math.min(surface.options.length - 1,
                        Math.round((contentX - firstCenter) / step)));
                }

                function restOf(index) {
                    const clamped = Math.max(0, Math.min(surface.options.length - 1, index));
                    return Math.max(0, Math.min(contentWidth - width,
                        firstCenter + clamped * step));
                }

                // the same gesture as the desktop card: let the drag settle,
                // then glide the nearest card to the middle
                function stopAtPage() {
                    if (!scrollable || surface.options.length <= 1) {
                        snap.to = 0;
                        snap.start();
                        return ;
                    }
                    const index = page;
                    surface.selectedIndex = index;
                    snap.stop();
                    snap.stop();
                    snap.to = restOf(index);
                    snap.start();
                }

                function centerOn(index) {
                    if (!scrollable || surface.options.length <= 1)
                        return ;

                    snap.stop();
                    snap.to = restOf(index);
                    snap.start();
                }

                onMovementEnded: stopAtPage()

                NumberAnimation {
                    id: snap

                    target: strip
                    property: "contentX"
                    duration: Theme.durMedium
                    easing.type: Easing.OutCubic
                }

                Row {
                    id: stripRow

                    x: strip.leading
                    height: strip.cardHeight
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: strip.gap

                    Repeater {
                        model: surface.options

                        delegate: SquircleRect {
                            id: optionCard

                            required property var modelData
                            required property int index

                            readonly property bool unlock: modelData.kind === "unlock"
                            readonly property var gate: modelData.gate || null
                            readonly property var task: modelData.task || null
                            readonly property bool affords: optionCard.gate !== null
                                && (GateCore.freeUnlock
                                    || GateCore.balance >= Number(optionCard.gate.cost || 0))
                            readonly property var session: optionCard.task !== null
                                ? GateCore.sessionFor(optionCard.task.id) : null
                            readonly property bool running: optionCard.session !== null
                            readonly property string logo: optionCard.task !== null
                                ? (optionCard.task.logo || (optionCard.task.kind === "duolingo" ? "duolingo-owl.png" : "")) : ""
                            // the whole card is the action; a disabled unlock
                            // or a running task simply does not react
                            readonly property bool actionable: optionCard.unlock
                                ? optionCard.affords : (optionCard.task !== null && !optionCard.running)
                            readonly property bool selected: optionCard.index === surface.selectedIndex
                            readonly property bool lit: optionCard.selected
                                || (optionCard.hovered && optionCard.actionable)
                            property real intro: 0
                            property bool hovered: false

                            function activate() {
                                surface.selectedIndex = optionCard.index;
                                surface.activateIndex(optionCard.index);
                            }

                            width: strip.cardWidth
                            height: strip.cardHeight
                            radius: Theme.rad(20)
                            fillColor: optionCard.lit
                                ? Theme.alpha(surface.accent, optionCard.selected ? 0.12 : 0.07)
                                : Theme.alpha(surface.ink, 0.035)
                            borderWidth: optionCard.selected ? 2 : 1
                            borderColor: optionCard.lit
                                ? Theme.alpha(surface.accent, optionCard.selected ? 0.55 : 0.30)
                                : Theme.alpha(surface.ink, 0.07)
                            opacity: optionCard.intro * (optionCard.unlock && !optionCard.affords ? 0.55 : 1)
                            transform: Translate {
                                y: (1 - optionCard.intro) * Theme.dp(14)
                            }
                            scale: (0.94 + 0.06 * optionCard.intro)
                                * (optionCard.lit ? 1.02 : 1)

                            Behavior on scale {
                                NumberAnimation {
                                    duration: Theme.durFastSpatial
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: Theme.curveDefaultSpatial
                                }

                            }

                            HoverHandler {
                                enabled: optionCard.actionable
                                cursorShape: Qt.PointingHandCursor
                                onHoveredChanged: optionCard.hovered = hovered
                            }

                            TapHandler {
                                enabled: optionCard.actionable
                                onTapped: optionCard.activate()
                            }

                            Component.onCompleted: {
                                if (surface.shown && !enter.running)
                                    enter.start();

                            }

                            Connections {
                                target: surface

                                function onIntroSerialChanged() {
                                    enter.restart();
                                }
                            }

                            SequentialAnimation {
                                id: enter

                                PauseAnimation {
                                    duration: optionCard.index * 55
                                }

                                NumberAnimation {
                                    target: optionCard
                                    property: "intro"
                                    from: 0
                                    to: 1
                                    duration: Theme.durDefaultEffects
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: Theme.curveEffects
                                }

                            }

                            // ---- unlock: the balance is the first way out --
                            Column {
                                id: cardBody

                                anchors.centerIn: parent
                                width: optionCard.width - Theme.dp(28)
                                spacing: optionCard.height < Theme.dp(280) ? Theme.dp(6) : Theme.dp(10)
                                scale: Math.min(1, (optionCard.height - Theme.dp(24)) / Math.max(1, implicitHeight))
                                transformOrigin: Item.Center
                                visible: optionCard.unlock

                                Item {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: Theme.dp(64)
                                    height: width

                                    Icon {
                                        anchors.centerIn: parent
                                        name: "lock"
                                        size: Theme.dp(34)
                                        color: surface.accent
                                        scale: optionCard.hovered ? 1.06 : 1

                                        Behavior on scale {
                                            NumberAnimation {
                                                duration: Theme.durShort * 1.5
                                                easing.type: Easing.Bezier
                                                easing.bezierCurve: Theme.curveDefaultSpatial
                                            }

                                        }

                                    }

                                }

                                LText {
                                    width: parent.width
                                    text: Tr.t("Unlock with credits")
                                    role: "titleLarge"
                                    color: surface.ink
                                    horizontalAlignment: Text.AlignHCenter
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                }

                                SquircleRect {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: costRow.implicitWidth + Theme.dp(18)
                                    height: Theme.dp(26)
                                    radius: height / 2
                                    fillColor: optionCard.affords ? Theme.primary : Theme.alpha(surface.ink, 0.07)

                                    Row {
                                        id: costRow

                                        anchors.centerIn: parent
                                        spacing: Theme.dp(4)

                                        Icon {
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: "memory"
                                            size: Theme.dp(13)
                                            color: optionCard.affords ? Theme.fgPrimary : surface.inkDim
                                        }

                                        Item {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: costText.implicitWidth
                                            height: costText.implicitHeight
                                            opacity: GateCore.freeUnlock ? 0.55 : 1

                                            LText {
                                                id: costText

                                                text: optionCard.gate !== null
                                                    ? String(optionCard.gate.cost || 0) : ""
                                                role: "labelMedium"
                                                color: optionCard.affords ? Theme.fgPrimary : surface.inkDim
                                                tabular: true
                                            }

                                            Rectangle {
                                                visible: GateCore.freeUnlock
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: parent.width + Theme.dp(2)
                                                height: Math.max(1, Theme.dp(1))
                                                color: optionCard.affords ? Theme.fgPrimary : surface.inkDim
                                            }

                                        }

                                        LText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: GateCore.freeUnlock
                                            text: "0"
                                            role: "labelMedium"
                                            color: optionCard.affords ? Theme.fgPrimary : surface.inkDim
                                            tabular: true
                                        }

                                    }

                                }

                                LText {
                                    width: parent.width
                                    visible: GateCore.freeUnlock || GateCore.freeAfter > 0
                                    text: GateCore.freeUnlock
                                        ? Tr.t("Quota reached!")
                                        : Tr.fmt("%1/%2", GateCore.dailyDone, GateCore.freeAfter)
                                    role: "labelMedium"
                                    color: GateCore.freeUnlock ? surface.accent : surface.inkDim
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }

                            }

                            // ---- a task that pays the way through ---------
                            Column {
                                anchors.centerIn: parent
                                width: optionCard.width - Theme.dp(28)
                                spacing: optionCard.height < Theme.dp(280) ? Theme.dp(6) : Theme.dp(10)
                                scale: Math.min(1, (optionCard.height - Theme.dp(24)) / Math.max(1, implicitHeight))
                                transformOrigin: Item.Center
                                visible: !optionCard.unlock

                                Item {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: Theme.dp(64)
                                    height: width

                                    Image {
                                        anchors.fill: parent
                                        visible: optionCard.logo !== ""
                                        source: optionCard.logo ? (GateCore.assetsPath + "/" + optionCard.logo) : ""
                                        sourceSize.width: Math.round(width * 2)
                                        sourceSize.height: Math.round(height * 2)
                                        fillMode: Image.PreserveAspectFit
                                        asynchronous: true
                                        smooth: true
                                        scale: optionCard.hovered ? 1.06 : 1

                                        Behavior on scale {
                                            NumberAnimation {
                                                duration: Theme.durShort * 1.5
                                                easing.type: Easing.Bezier
                                                easing.bezierCurve: Theme.curveDefaultSpatial
                                            }

                                        }

                                    }

                                    Icon {
                                        anchors.centerIn: parent
                                        visible: optionCard.logo === ""
                                        name: optionCard.task !== null ? (optionCard.task.icon || "task_alt") : "task_alt"
                                        size: Theme.dp(34)
                                        color: surface.accent
                                        scale: optionCard.hovered ? 1.06 : 1

                                        Behavior on scale {
                                            NumberAnimation {
                                                duration: Theme.durShort * 1.5
                                                easing.type: Easing.Bezier
                                                easing.bezierCurve: Theme.curveDefaultSpatial
                                            }

                                        }

                                    }

                                }

                                LText {
                                    width: parent.width
                                    text: optionCard.task !== null
                                        ? Tr.t(optionCard.task.name || optionCard.task.id) : ""
                                    role: "titleLarge"
                                    color: surface.ink
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }

                                SquircleRect {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: rewardRow.implicitWidth + Theme.dp(18)
                                    height: Theme.dp(26)
                                    radius: height / 2
                                    fillColor: Theme.primary

                                    Row {
                                        id: rewardRow

                                        anchors.centerIn: parent
                                        spacing: Theme.dp(4)

                                        Icon {
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: "memory"
                                            size: Theme.dp(13)
                                            color: Theme.fgPrimary
                                        }

                                        LText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: optionCard.task !== null
                                                ? String(optionCard.task.reward || 0) : ""
                                            role: "labelMedium"
                                            color: Theme.fgPrimary
                                            tabular: true
                                        }

                                    }

                                }

                            }

                        }

                    }

                }

            }

        }

    }

}
