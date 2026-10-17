import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Hyprland._FocusGrab
import Quickshell.Services.Notifications
import Quickshell.Widgets
import qs


BarPill {
    id: root

    readonly property bool dnd: Prefs.doNotDisturb
    property var toastNotification: null
    property bool ready: false
    readonly property int horizontalPadding: 10
    readonly property real screenW: root.hostWindow ? root.hostWindow.screen.width : 1600
    readonly property real screenH: root.hostWindow ? root.hostWindow.screen.height : 900
    readonly property int maxPanelHeight: Math.min(420, Math.max(200, root.screenH - 40))
    readonly property int chromeHeight: 102
    readonly property int notifCount: notifServer.trackedNotifications ? notifServer.trackedNotifications.values.length : 0
    readonly property string badgeDisplayText: root.notifCount > 9 ? "9+" : String(root.notifCount)
    property var sortedNotifications: []

    function refreshSorted() {
        const v = notifServer.trackedNotifications ? notifServer.trackedNotifications.values.slice() : [];
        v.sort((a, b) => b.id - a.id);
        root.sortedNotifications = v;
    }

    function clearAll() {
        for (const n of root.sortedNotifications.slice()) n.dismiss()
        root.refreshSorted();
    }

    property var shownIds: ({})
    property bool shownIdsSeeded: false

    function markShown(id) {
        if (!root.shownIdsSeeded) {
            for (const n of root.sortedNotifications) root.shownIds[n.id] = true
            root.shownIdsSeeded = true;
        }
        if (root.shownIds[id])
            return false;

        root.shownIds[id] = true;
        return true;
    }

    function normAppId(s) {
        if (s === undefined || s === null)
            return "";
        var v = String(s).toLowerCase().trim();
        if (v.endsWith(".desktop"))
            v = v.slice(0, -8);
        return v;
    }

    function tailAppId(s) {
        var v = root.normAppId(s);
        var i = v.lastIndexOf(".");
        return i >= 0 ? v.slice(i + 1) : v;
    }

    function candidateIds(n) {
        var out = [];
        if (!n)
            return out;
        var raw = [];
        if (n.desktopEntry)
            raw.push(n.desktopEntry);
        if (n.hints && n.hints["desktop-entry"])
            raw.push(n.hints["desktop-entry"]);
        if (n.appName)
            raw.push(n.appName);
        if (n.appIcon) {
            var ai = String(n.appIcon);
            raw.push(ai.indexOf("image://icon/") === 0 ? ai.slice(13) : ai);
        }
        for (var i = 0; i < raw.length; i++) {
            var full = root.normAppId(raw[i]);
            var tail = root.tailAppId(raw[i]);
            if (full && out.indexOf(full) < 0)
                out.push(full);
            if (tail && out.indexOf(tail) < 0)
                out.push(tail);
        }
        return out;
    }

    // Tokens from notification text usable to tell same-app windows apart
    // (e.g. Discord sender "kevin1991" vs window "@kevin1991 - Discord").
    function notifTokens(n) {
        var text = "";
        try {
            text += " " + (n.summary || "");
        } catch (e) {
        }
        try {
            text += " " + (n.body || "");
        } catch (e) {
        }
        var parts = text.toLowerCase().split(/[^a-z0-9]+/);
        var out = [];
        for (var i = 0; i < parts.length; i++) {
            if (parts[i].length >= 3 && out.indexOf(parts[i]) < 0)
                out.push(parts[i]);
        }
        return out;
    }

    function titleScore(title, tokens) {
        if (!title || tokens.length === 0)
            return 0;
        var t = String(title).toLowerCase();
        var score = 0;
        for (var i = 0; i < tokens.length; i++) {
            if (t.indexOf(tokens[i]) >= 0)
                score += tokens[i].length;
        }
        return score;
    }

    // Best-effort match of a notification to an open Hyprland window so an
    // action press (e.g. "View") can also take you to the app's workspace.
    // Compares the notification's desktop-entry/appName against each
    // toplevel's class/appId (full and reverse-domain tail forms). When
    // several windows of the same app are open, ranks them: urgent windows
    // first (the notifier usually demands attention), then notification
    // text (sender/channel) matched against window titles, then most
    // recently focused.
    function findWindowForNotification(n) {
        var ids = root.candidateIds(n);
        if (ids.length === 0)
            return null;
        var tls = [];
        try {
            tls = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        } catch (e) {
            return null;
        }
        var tokens = root.notifTokens(n);
        var best = null;
        var bestKey = null;
        for (var i = 0; i < tls.length; i++) {
            var t = tls[i];
            if (!t)
                continue;
            var ipc = null;
            try {
                ipc = t.lastIpcObject;
            } catch (e) {
                ipc = null;
            }
            var addrs = [];
            if (ipc) {
                if (ipc.class)
                    addrs.push(ipc.class);
                if (ipc.initialClass)
                    addrs.push(ipc.initialClass);
            }
            try {
                if (t.wayland && t.wayland.appId)
                    addrs.push(t.wayland.appId);
            } catch (e) {
            }
            var winAddr = (ipc && ipc.address) ? ipc.address : (t.address ? t.address : "");
            if (!winAddr)
                continue;
            var appMatch = false;
            for (var a = 0; a < addrs.length && !appMatch; a++) {
                var cFull = root.normAppId(addrs[a]);
                var cTail = root.tailAppId(addrs[a]);
                if (!cFull)
                    continue;
                for (var j = 0; j < ids.length; j++) {
                    if (ids[j] === cFull || ids[j] === cTail) {
                        appMatch = true;
                        break;
                    }
                }
            }
            if (!appMatch)
                continue;
            var urgent = 0;
            try {
                urgent = t.urgent === true ? 1 : 0;
            } catch (e) {
            }
            var title = "";
            try {
                title = t.title || "";
            } catch (e) {
                title = "";
            }
            // lastIpcObject is only refreshed on Hyprland.refreshToplevels
            // (see the calls in onNotification/onExpandedChanged) - the
            // dedicated title property above stays live between refreshes,
            // which is what keeps per-window titles (e.g. Discord's
            // "@user - Discord") fresh enough to tell same-app windows
            // apart. The cached copy is only a fallback.
            if (!title && ipc && ipc.title)
                title = ipc.title;
            var tScore = root.titleScore(title, tokens);
            var focusOrder = 9999;
            try {
                if (ipc && ipc.focusHistoryID !== undefined && ipc.focusHistoryID !== null)
                    focusOrder = Number(ipc.focusHistoryID);
            } catch (e) {
            }
            // Compare tuple (urgent, titleScore, -focusOrder): urgent wins,
            // then text match, then most recently focused (lowest id).
            var key = [urgent, tScore, -focusOrder];
            if (bestKey === null || key[0] > bestKey[0] || (key[0] === bestKey[0] && (key[1] > bestKey[1] || (key[1] === bestKey[1] && key[2] > bestKey[2])))) {
                bestKey = key;
                best = {
                    "address": winAddr
                };
            }
        }
        return best;
    }

    // Focus the sender's window; Hyprland switches to its workspace as part
    // of the focus. No-op when the app has no open window. Returns bool.
    function focusNotificationApp(n) {
        var m = root.findWindowForNotification(n);
        if (!m || !m.address)
            return false;
        try {
            Hyprland.dispatch("hl.dsp.focus({window='address:" + m.address + "'})");
            return true;
        } catch (e) {
            return false;
        }
    }

    // Only view-like actions (View/Open/Show + the default action) jump to
    // the app; acting on anything else (mark-read, snooze, delete...) just
    // invokes without yanking you to another workspace.
    function isViewLike(action) {
        if (!action)
            return false;
        var id = "";
        var tx = "";
        try {
            id = String(action.identifier || "");
        } catch (e) {
        }
        try {
            tx = String(action.text || "");
        } catch (e) {
        }
        if (id === "default")
            return true;
        return /view|open|show|go to|jump|reveal/i.test(id) || /view|open|show|go to|jump|reveal/i.test(tx);
    }

    function invokeAndMaybeFocus(action, n) {
        if (!action)
            return;
        action.invoke();
        if (root.isViewLike(action)) {
            root.focusNotificationApp(n);
            // we're leaving for the app's workspace - retract the panel
            // rather than leaving it open behind. (Harmless for toast
            // chips, where expanded is already false.)
            root.expanded = false;
        }
    }

    shown: Prefs.showNotifications
    compactWidth: compactRow.implicitWidth + root.horizontalPadding * 2
    panelWidth: Math.min(320, root.screenW - 34)
    panelHeight: Math.min(root.maxPanelHeight, mainColumn.implicitHeight + 28)
    altOpen: root.shown && root.toastNotification !== null && !root.expanded
    altWidth: Math.min(300, root.screenW - 34)
    altHeight: Math.min(root.maxPanelHeight, toastBody.implicitHeight + 20)
    expandedRadius: 20

    onExpandedChanged: {
        if (expanded) {
            root.toastNotification = null;
            toastTimer.stop();
            // Heavy warmup (sort + Hyprland IPC round-trip) runs after the
            // morph starts so it can't hitch frame 0; the panel fades in
            // over ~150ms anyway (BarPill panelFadePause).
            expandWarmupTimer.restart();
        } else {
            expandWarmupTimer.stop();
        }
    }

    Timer {
        id: expandWarmupTimer

        interval: 150
        repeat: false
        onTriggered: {
            if (!root.expanded)
                return;
            root.refreshSorted();
            // lastIpcObject titles/focus order only refresh on demand -
            // warm the cache now so a View-press picks the right window
            // among same-app ones (e.g. two Discord DMs).
            try {
                Hyprland.refreshToplevels();
            } catch (e) {
            }
        }
    }

    NotificationServer {
        id: notifServer

        keepOnReload: true
        bodySupported: true
        bodyMarkupSupported: false
        bodyHyperlinksSupported: false
        bodyImagesSupported: false
        actionsSupported: true
        actionIconsSupported: false
        imageSupported: true
        inlineReplySupported: false
        persistenceSupported: false
        Component.onCompleted: root.refreshSorted()
        onNotification: (notification) => {
            notification.tracked = true;
            // Warm the window cache up front so the title/focus data a
            // later View-press matches against is fresh (see above).
            try {
                Hyprland.refreshToplevels();
            } catch (e) {
            }
            if (!root.ready)
                return ;

            if (root.expanded)
                return ;

            if (root.dnd)
                return ;

            if (root.toastNotification && root.toastNotification.expireTimeout === 0)
                return ;

            root.toastNotification = notification;
            if (notification.expireTimeout === 0)
                toastTimer.stop();
            else
                toastTimer.restart();
        }
    }

    Timer {
        interval: 300
        running: true
        onTriggered: root.ready = true
    }

    Timer {
        id: toastTimer

        interval: Prefs.toastTimeout * 1000
        onTriggered: root.toastNotification = null
    }

    Timer {
        id: panelTransitionTimer

        interval: 400
        onTriggered: root.panelTransitioning = false
        onRunningChanged: {
            if (running)
                root.panelTransitioning = true;

        }
    }

    Connections {
        function onClosed() {
            toastTimer.stop();
            root.toastNotification = null;
        }

        target: root.toastNotification
    }

    Connections {
        function onValuesChanged() {
            root.refreshSorted();
        }

        target: notifServer.trackedNotifications
    }

    ScriptModel {
        id: notifModel

        values: root.sortedNotifications
    }




    compactContent: [
        Row {
            id: compactRow

            anchors.centerIn: parent
            spacing: 4

            Item {
                width: 16
                height: 16
                anchors.verticalCenter: parent.verticalCenter

                Shape {
                    visible: opacity > 0.01
                    opacity: root.dnd ? 0 : 1
                    scale: (16 / 24) * (root.dnd ? 0.55 : 1)
                    rotation: root.dnd ? -35 : 0
                    width: 24
                    height: 24
                    anchors.centerIn: parent
                    preferredRendererType: Shape.CurveRenderer

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.barMs(220)
                            easing.type: Easing.OutCubic
                        }

                    }

                    Behavior on scale {
                        NumberAnimation {
                            duration: Theme.barMs(220)
                            easing.type: Easing.OutCubic
                        }

                    }

                    Behavior on rotation {
                        NumberAnimation {
                            duration: Theme.barMs(220)
                            easing.type: Easing.OutCubic
                        }

                    }

                    ShapePath {
                        fillColor: Theme.text
                        strokeWidth: 0

                        PathSvg {
                            path: "M12 22a2.5 2.5 0 0 0 2.45-2h-4.9A2.5 2.5 0 0 0 12 22Zm7-6v-5c0-3.07-1.63-5.64-4.5-6.32V4a1.5 1.5 0 0 0-3 0v.68C8.64 5.36 7 7.92 7 11v5l-2 2v1h14v-1l-2-2Z"
                        }

                    }

                }

                Shape {
                    visible: opacity > 0.01
                    opacity: root.dnd ? 1 : 0
                    scale: (16 / 24) * (root.dnd ? 1 : 0.55)
                    rotation: root.dnd ? 0 : 35
                    width: 24
                    height: 24
                    anchors.centerIn: parent
                    preferredRendererType: Shape.CurveRenderer

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.barMs(220)
                            easing.type: Easing.OutCubic
                        }

                    }

                    Behavior on scale {
                        NumberAnimation {
                            duration: Theme.barMs(220)
                            easing.type: Easing.OutCubic
                        }

                    }

                    Behavior on rotation {
                        NumberAnimation {
                            duration: Theme.barMs(220)
                            easing.type: Easing.OutCubic
                        }

                    }

                    ShapePath {
                        fillColor: Theme.accent
                        strokeWidth: 0

                        PathSvg {
                            path: "M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79Z"
                        }

                    }

                }

            }

            Rectangle {
                id: badge

                anchors.verticalCenter: parent.verticalCenter
                height: 16
                width: root.notifCount > 0 ? Math.max(16, badgeText.implicitWidth + 8) : 0
                radius: 999
                color: Theme.accent
                opacity: root.notifCount > 0 ? 1 : 0
                scale: root.notifCount > 0 ? 1 : 0.4
                clip: true

                Text {
                    id: badgeText

                    property string displayedText: ""
                    property real morphOffset: 0

                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: morphOffset
                    text: displayedText
                    color: Theme.bgOpaque
                    font.family: Theme.fontFamily
                    font.bold: true
                    font.pixelSize: Theme.fs(11)

                    Component.onCompleted: displayedText = root.badgeDisplayText
                }

                Connections {
                    function onBadgeDisplayTextChanged() {
                        badgeMorph.restart();
                    }

                    target: root
                }

                SequentialAnimation {
                    id: badgeMorph

                    ParallelAnimation {
                        NumberAnimation {
                            target: badgeText
                            property: "opacity"
                            to: 0
                            duration: Theme.barMs(90)
                            easing.type: Easing.InCubic
                        }

                        NumberAnimation {
                            target: badgeText
                            property: "morphOffset"
                            to: -6
                            duration: Theme.barMs(90)
                            easing.type: Easing.InCubic
                        }

                    }

                    ScriptAction {
                        script: {
                            badgeText.displayedText = root.badgeDisplayText;
                            badgeText.morphOffset = 6;
                        }
                    }

                    ParallelAnimation {
                        NumberAnimation {
                            target: badgeText
                            property: "opacity"
                            to: 1
                            duration: Theme.barMs(140)
                            easing.type: Easing.OutCubic
                        }

                        NumberAnimation {
                            target: badgeText
                            property: "morphOffset"
                            to: 0
                            duration: Theme.barMs(140)
                            easing.type: Easing.OutCubic
                        }

                    }

                }

                // no bounce here, it fights the pop below
                Behavior on width {
                    NumberAnimation {
                        duration: Theme.barMs(160)
                        easing.type: Easing.OutCubic
                    }

                }

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.barMs(180)
                    }

                }

                Behavior on scale {
                    NumberAnimation {
                        duration: Theme.barMs(220)
                        easing.type: Easing.OutBack
                    }

                }

            }

        }
    ]

    altContent: [
        Item {
            id: toastFace

        anchors.fill: parent

        readonly property var notif: root.toastNotification
        readonly property string notifImage: notif ? notif.image : ""
        readonly property string themeIconName: notif ? (notif.appIcon || (notifImage.indexOf("image://icon/") === 0 ? notifImage.slice(13) : "")) : ""
        readonly property string directImage: notifImage.indexOf("image://icon/") === 0 ? "" : notifImage
        readonly property string iconSource: directImage || (themeIconName ? Quickshell.iconPath(themeIconName) : "")
        readonly property bool hovered: toastHover.hovered

        clip: true
        onNotifChanged: {
            if (notif)
                toastContent.y = 0;

        }

        HoverHandler {
            id: toastHover
        }

        // y is driven by the drag or the anims below, never both
        Item {
            id: toastContent

            width: parent.width
            height: parent.height
            opacity: Math.max(0, 1 - (-y) / 120)

            MouseArea {
                id: toastDragArea

                property bool dragged: false

                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                drag.target: toastContent
                drag.axis: Drag.YAxis
                drag.minimumY: -(toastContent.height + 40)
                drag.maximumY: 0
                onPressed: {
                    dragged = false;
                    toastTimer.stop();
                }
                onPositionChanged: {
                    if (Math.abs(toastContent.y) > 4)
                        dragged = true;
                }
                onReleased: {
                    if (-toastContent.y > 36) {
                        toastDismissAnim.start();
                    } else {
                        toastSnapAnim.start();
                        toastTimer.restart();
                    }
                }
                onClicked: {
                    if (!dragged)
                        root.expanded = true;
                }
            }

            NumberAnimation {
                id: toastSnapAnim

                target: toastContent
                property: "y"
                to: 0
                duration: Theme.barMs(200)
                easing.type: Easing.OutCubic
            }

            NumberAnimation {
                id: toastDismissAnim

                target: toastContent
                property: "y"
                to: -(toastContent.height + 40)
                duration: Theme.barMs(180)
                easing.type: Easing.InCubic
                onFinished: root.toastNotification = null
            }

            Column {
                id: toastBody

                x: 14
                y: 10
                width: parent.width - 28
                spacing: 4

                Row {
                    width: parent.width
                    spacing: 8

                    Item {
                        width: 20
                        height: 20
                        anchors.top: parent.top

                        IconImage {
                            id: toastIcon

                            anchors.fill: parent
                            source: toastFace.iconSource
                            asynchronous: true
                            visible: status === Image.Ready
                        }

                        Shape {
                            visible: !toastIcon.visible
                            width: 24
                            height: 24
                            scale: 16 / 24
                            anchors.centerIn: parent
                            preferredRendererType: Shape.CurveRenderer

                            ShapePath {
                                fillColor: Theme.subtextDim
                                strokeWidth: 0

                                PathSvg {
                                    path: "M12 22a2.5 2.5 0 0 0 2.45-2h-4.9A2.5 2.5 0 0 0 12 22Zm7-6v-5c0-3.07-1.63-5.64-4.5-6.32V4a1.5 1.5 0 0 0-3 0v.68C8.64 5.36 7 7.92 7 11v5l-2 2v1h14v-1l-2-2Z"
                                }

                            }

                        }

                    }

                    Column {
                        width: parent.width - 20 - 8 - 24
                        spacing: 1

                        Text {
                            width: parent.width
                            visible: toastFace.notif && toastFace.notif.appName !== ""
                            text: toastFace.notif ? toastFace.notif.appName : ""
                            color: Theme.subtextDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fs(9)
                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width
                            text: toastFace.notif ? toastFace.notif.summary : ""
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.bold: true
                            font.pixelSize: Theme.fs(12)
                            wrapMode: Text.WordWrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }

                    }

                }

            Text {
                width: parent.width
                leftPadding: 28
                visible: toastFace.notif && toastFace.notif.body !== ""
                text: toastFace.notif ? toastFace.notif.body : ""
                color: Theme.subtext
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fs(11)
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
            }

            Row {
                leftPadding: 28
                visible: toastFace.notif && toastFace.notif.actions.length > 0
                spacing: 6

                Repeater {
                    model: toastFace.notif ? toastFace.notif.actions : []

                    Rectangle {
                        id: toastActionChip

                        required property var modelData

                        height: 22
                        width: toastActionLabel.implicitWidth + 16
                        radius: 999
                        color: toastActionArea.containsMouse ? Theme.accentHover : Theme.accent

                        Text {
                            id: toastActionLabel

                            anchors.centerIn: parent
                            text: toastActionChip.modelData.text
                            color: Theme.bgOpaque
                            font.family: Theme.fontFamily
                            font.bold: true
                            font.pixelSize: Theme.fs(10)
                        }

                        MouseArea {
                            id: toastActionArea

                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.invokeAndMaybeFocus(toastActionChip.modelData, toastFace.notif)
                        }

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.barMs(120)
                            }

                        }

                    }

                }

            }

            }

            Item {
                id: toastCloseButton

                width: 20
                height: 20
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 6

                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    color: toastCloseArea.containsMouse ? Theme.text : Theme.subtextDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fs(11)
                    opacity: toastFace.hovered ? 1 : 0

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.barMs(140)
                            easing.type: Easing.OutCubic
                        }

                    }

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.barMs(120)
                        }

                    }

                }

                MouseArea {
                    id: toastCloseArea

                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        toastTimer.stop();
                        root.toastNotification = null;
                    }
                }

            }

        }
        }
    ]

    panelContent: [
        Column {
            id: mainColumn

            anchors.fill: parent
            anchors.margins: 14
            spacing: 10

            Item {
                width: parent.width
                height: 28

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: Theme.outline
                }

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Notifications"
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.bold: true
                    font.pixelSize: Theme.fs(13)
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Do Not Disturb"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fs(11)
                    }

                    Rectangle {
                        id: dndSwitch

                        anchors.verticalCenter: parent.verticalCenter
                        width: 32
                        height: 18
                        radius: 999
                        color: root.dnd ? Theme.accent : Theme.outlineStrong

                        Rectangle {
                            width: 14
                            height: 14
                            radius: 7
                            color: Theme.bgOpaque
                            anchors.verticalCenter: parent.verticalCenter
                            x: root.dnd ? parent.width - width - 2 : 2

                            Behavior on x {
                                NumberAnimation {
                                    duration: Theme.barMs(200)
                                    easing.type: Easing.OutCubic
                                }

                            }

                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Prefs.doNotDisturb = !Prefs.doNotDisturb
                        }

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.barMs(200)
                            }

                        }

                    }

                }

            }

            Item {
                width: parent.width
                height: 26

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.notifCount > 0
                    text: root.notifCount === 1 ? "1 notification" : root.notifCount + " notifications"
                    color: Theme.subtext
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fs(11)
                }

                Text {
                    id: clearAllText

                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Clear all"
                    color: clearAllArea.containsMouse ? Theme.accentHover : Theme.accent
                    opacity: root.notifCount > 0 ? 1 : 0.35
                    font.family: Theme.fontFamily
                    font.bold: true
                    font.pixelSize: Theme.fs(11)

                    MouseArea {
                        id: clearAllArea

                        anchors.fill: parent
                        anchors.margins: -6
                        enabled: root.notifCount > 0
                        hoverEnabled: true
                        cursorShape: root.notifCount > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: root.clearAll()
                    }

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.barMs(120)
                        }

                    }

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.barMs(150)
                        }

                    }

                }

            }

            Item {
                width: parent.width
                height: 48
                visible: root.notifCount === 0

                Text {
                    anchors.centerIn: parent
                    text: "No notifications"
                    color: Theme.subtext
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fs(12)
                }

            }

            ListView {
                id: notifList

                property int prevCount: 0

                width: parent.width
                visible: root.notifCount > 0
                clip: true
                spacing: 6
                model: notifModel
                height: Math.min(contentHeight, root.maxPanelHeight - root.chromeHeight)
                flickDeceleration: 6000
                maximumFlickVelocity: 6000
                onCountChanged: {
                    if (count > prevCount && contentY > 0)
                        scrollToNewest.restart();

                    prevCount = count;
                }

                NumberAnimation {
                    id: scrollToNewest

                    target: notifList
                    property: "contentY"
                    to: 0
                    duration: Theme.barMs(320)
                    easing.type: Easing.OutCubic
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    onWheel: (wheel) => {
                        const maxY = Math.max(0, notifList.contentHeight - notifList.height);
                        notifList.contentY = Math.max(0, Math.min(maxY, notifList.contentY - (wheel.angleDelta.y / 120) * 90));
                        wheel.accepted = true;
                    }
                }

                delegate: NotifCard {
                }

                removeDisplaced: Transition {
                    NumberAnimation {
                        properties: "x,y"
                        duration: Theme.barMs(300)
                        easing.type: Easing.OutCubic
                    }

                    NumberAnimation {
                        property: "opacity"
                        to: 1
                        duration: Theme.barMs(200)
                    }

                }

                remove: Transition {
                    NumberAnimation {
                        property: "opacity"
                        to: 0
                        duration: Theme.barMs(200)
                        easing.type: Easing.InCubic
                    }

                    NumberAnimation {
                        property: "scale"
                        to: 0.85
                        duration: Theme.barMs(200)
                        easing.type: Easing.InCubic
                    }

                    NumberAnimation {
                        property: "x"
                        to: 26
                        duration: Theme.barMs(200)
                        easing.type: Easing.InCubic
                    }

                }

                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded

                    contentItem: Rectangle {
                        implicitWidth: 4
                        radius: 2
                        color: Theme.accent
                        opacity: 0.55
                    }

                    background: Item {
                    }

                }

            }

        }
    ]

    component NotifCard: Rectangle {
        id: card

        required property var modelData
        readonly property var notification: modelData
        property string notifAppName: ""
        property string notifSummary: ""
        property string notifBody: ""
        property string notifImage: ""
        property string notifAppIcon: ""
        property int notifUrgency: NotificationUrgency.Normal
        property var notifActions: []
        readonly property string themeIconName: card.notifAppIcon || (card.notifImage.indexOf("image://icon/") === 0 ? card.notifImage.slice(13) : "")
        readonly property string directImage: card.notifImage.indexOf("image://icon/") === 0 ? "" : card.notifImage
        readonly property string iconSource: directImage || (themeIconName ? Quickshell.iconPath(themeIconName) : "")
        readonly property color accentColor: card.notifUrgency === NotificationUrgency.Critical ? Theme.error : (card.notifUrgency === NotificationUrgency.Low ? Theme.subtextDim : Theme.accent)
        readonly property bool isHovered: cardHover.hovered
        property real arrivalGlow: 0
        readonly property real fullHeight: cardColumn.implicitHeight + 20
        property real enterProgress: 0

        function syncNotification() {
            const n = card.notification;
            if (!n)
                return ;

            card.notifAppName = n.appName;
            card.notifSummary = n.summary;
            card.notifBody = n.body;
            card.notifImage = n.image;
            card.notifAppIcon = n.appIcon;
            card.notifUrgency = n.urgency;
            card.notifActions = n.actions.map((a) => {
                return {
                    "identifier": a.identifier,
                    "text": a.text,
                    "invoke": () => {
                        return a.invoke();
                    }
                };
            });
        }

        onNotificationChanged: card.syncNotification()
        Component.onCompleted: {
            card.syncNotification();
            if (card.notification && root.markShown(card.notification.id))
                cardEnter.start();
            else
                card.enterProgress = 1;
        }
        // deferred — straight from a delegate handler this crashes mid-incubation
        function relayout() {
            if (card.ListView.view)
                card.ListView.view.forceLayout();

        }

        onHeightChanged: Qt.callLater(card.relayout)
        width: ListView.view.width - 12
        height: card.fullHeight * card.enterProgress
        radius: 14
        color: Theme.withBlur(card.arrivalGlow > 0 ? Theme._mix(Theme.bgHover, card.accentColor, card.arrivalGlow * 0.32) : Theme.bgHover)
        clip: true
        transform: Translate {
            x: (1 - card.enterProgress) * 22
        }

        ParallelAnimation {
            id: cardEnter

            NumberAnimation {
                target: card
                property: "enterProgress"
                from: 0
                to: 1
                duration: Theme.barMs(400)
                easing.type: Easing.OutCubic
            }

            NumberAnimation {
                target: card
                property: "opacity"
                from: 0
                to: 1
                duration: Theme.barMs(300)
                easing.type: Easing.OutCubic
            }

            NumberAnimation {
                target: card
                property: "arrivalGlow"
                from: 1
                to: 0
                duration: Theme.barMs(900)
                easing.type: Easing.InCubic
            }

        }

        Connections {
            function onAppNameChanged() {
                card.syncNotification();
            }

            function onAppIconChanged() {
                card.syncNotification();
            }

            function onSummaryChanged() {
                card.syncNotification();
            }

            function onBodyChanged() {
                card.syncNotification();
            }

            function onImageChanged() {
                card.syncNotification();
            }

            function onUrgencyChanged() {
                card.syncNotification();
            }

            function onActionsChanged() {
                card.syncNotification();
            }

            target: card.notification
        }

        HoverHandler {
            id: cardHover
        }

        Column {
            id: cardColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            anchors.topMargin: 10
            spacing: 4

            Row {
                width: parent.width
                spacing: 8

                Rectangle {
                    id: avatar

                    width: 20
                    height: 20
                    radius: 999
                    color: Theme.bgTrack
                    anchors.top: parent.top

                    IconImage {
                        id: iconImage

                        anchors.fill: parent
                        anchors.margins: 1
                        source: card.iconSource
                        asynchronous: true
                        visible: status === Image.Ready
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: !iconImage.visible
                        text: (card.notifAppName || "?").charAt(0).toUpperCase()
                        color: card.accentColor
                        font.family: Theme.fontFamily
                        font.bold: true
                        font.pixelSize: Theme.fs(9)
                    }

                }

                Column {
                    width: parent.width - 20 - 20 - 16
                    spacing: 1
                    height: (cardAppNameText.visible ? cardAppNameText.height + spacing : 0) + cardSummaryText.height

                    Text {
                        id: cardAppNameText

                        width: parent.width
                        visible: card.notifAppName !== ""
                        text: card.notifAppName
                        color: Theme.subtextDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fs(9)
                        elide: Text.ElideRight
                    }

                    Text {
                        id: cardSummaryText

                        width: parent.width
                        text: card.notifSummary
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.bold: true
                        font.pixelSize: Theme.fs(12)
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }

                }

                Item {
                    width: 20
                    height: 20
                    anchors.top: parent.top

                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        color: dismissArea.containsMouse ? Theme.text : Theme.subtextDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fs(11)
                        opacity: card.isHovered ? 1 : 0

                        Behavior on opacity {
                            NumberAnimation {
                                duration: Theme.barMs(140)
                                easing.type: Easing.OutCubic
                            }

                        }

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.barMs(120)
                            }

                        }

                    }

                    MouseArea {
                        id: dismissArea

                        anchors.fill: parent
                        anchors.margins: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (card.notification)
                                card.notification.dismiss();

                        }
                    }

                }

            }

            Text {
                width: parent.width
                leftPadding: 28
                visible: card.notifBody !== ""
                text: card.notifBody
                color: Theme.subtext
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fs(11)
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
            }

            Row {
                leftPadding: 28
                visible: card.notifActions.length > 0
                spacing: 6

                Repeater {
                    model: card.notifActions

                    Rectangle {
                        id: actionChip

                        required property var modelData

                        height: 22
                        width: actionLabel.implicitWidth + 16
                        radius: 999
                        color: card.accentColor
                        opacity: actionArea.containsMouse ? 0.85 : 1

                        Text {
                            id: actionLabel

                            anchors.centerIn: parent
                            text: actionChip.modelData.text
                            color: Theme.bgOpaque
                            font.family: Theme.fontFamily
                            font.bold: true
                            font.pixelSize: Theme.fs(10)
                        }

                        MouseArea {
                            id: actionArea

                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.invokeAndMaybeFocus(actionChip.modelData, card.notification)
                        }

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.barMs(120)
                            }

                        }

                    }

                }

            }

            Item {
                width: parent.width
                height: 6
            }

        }

    }

}
