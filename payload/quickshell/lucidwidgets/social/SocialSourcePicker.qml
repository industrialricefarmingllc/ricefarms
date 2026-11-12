import QtQuick
import QtQuick.Layouts
import qs
import qs.lucidui
import "../../squircle"

// The per-card source sheet.  A source switch turns the whole source on/off;
// opening a source reveals every stream it offers, each with its own switch.
// The two off-lists live in the widget's own opts, so every card remembers a
// different selection.
Item {
    id: picker

    required property var sources
    required property var offSources
    required property var offStreams
    required property var onStreams
    property var host: null

    signal toggleSource(string id)
    signal toggleStream(string id)
    signal saveCredential(string sourceId, string key, string value)
    signal saveAccount(string sourceId, string accountId, string name, string value)
    signal removeAccount(string sourceId, string accountId)
    signal closeRequested()

    property string expanded: ""
    property string authBusyKey: ""
    property string authError: ""
    property string authStatus: ""
    property string newAccountName: ""
    property string newAccountToken: ""

    function contains(list, id) {
        return (list || []).indexOf(id) >= 0;
    }

    function sourceOn(source) {
        return !picker.contains(picker.offSources, source.id);
    }

    function streamOn(stream) {
        return stream.default_selected === false ? picker.contains(picker.onStreams, stream.id) : !picker.contains(picker.offStreams, stream.id);
    }

    function sourceStreamCount(source) {
        return (source.streams || []).length;
    }

    function scrollKey(key) {
        var maxY = Math.max(0, scroll.contentHeight - scroll.height);
        if (key === Qt.Key_PageUp)
            scroll.contentY = Math.max(0, scroll.contentY - scroll.height * 0.9);
        else if (key === Qt.Key_PageDown)
            scroll.contentY = Math.min(maxY, scroll.contentY + scroll.height * 0.9);
        else if (key === Qt.Key_Home)
            scroll.contentY = 0;
        else if (key === Qt.Key_End)
            scroll.contentY = maxY;
        else
            return false;

        return true;
    }

    ColumnLayout {
        anchors.fill: parent
        // Match the main feed's content inset (the post cards' 14 px pad),
        // not the outer header margin.
        anchors.margins: Theme.dp(14)
        spacing: Theme.dp(12)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                LText {
                    role: "titleSmall"
                    text: Tr.t("Sources")
                    color: Theme.text
                }

                LText {
                    role: "labelSmall"
                    text: picker.sources.length + Tr.t(" available · this card remembers its own selection")
                    color: Theme.subtextDim
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

            }

            IconButton {
                icon: "close"
                size: "xs"
                onClicked: picker.closeRequested()
            }

        }

        Flickable {
            id: scroll

            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: (event) => {
                    var angle = Number(event.angleDelta.y || 0);
                    var dy = angle !== 0 ? (angle / 120) * 60 : Number(event.pixelDelta.y || 0);

                    var maxY = Math.max(0, scroll.contentHeight - scroll.height);
                    var from = scroll.contentY;
                    var pending = wheelAnim.running ? Number(wheelAnim.to) - from : 0;
                    var sameWay = (dy > 0 && pending <= 0) || (dy < 0 && pending >= 0);
                    var base = wheelAnim.running && sameWay ? Number(wheelAnim.to) : from;
                    var to = Math.max(0, Math.min(maxY, base - dy * 2.4));
                    if (Math.abs(to - from) >= 0.5) {
                        wheelAnim.stop();
                        wheelAnim.from = from;
                        wheelAnim.to = to;
                        wheelAnim.restart();
                    }
                    event.accepted = true;
                }
            }

            NumberAnimation {
                id: wheelAnim

                target: scroll
                property: "contentY"
                duration: Theme.durQuick
                easing.type: Easing.OutCubic
            }

            Column {
                id: list

                width: scroll.width
                spacing: Theme.dp(10)

                Repeater {
                    model: picker.sources

                    Item {
                        id: sourceBlock

                        required property var modelData

                        width: list.width
                        height: sourceContent.height + Theme.dp(12)

                        readonly property bool open: picker.expanded === sourceBlock.modelData.id
                        readonly property bool on: picker.sourceOn(sourceBlock.modelData)

                        SquircleRect {
                            anchors.fill: parent
                            radius: Theme.rad(20)
                            fillColor: Theme.surfaceHigh
                            borderWidth: 1
                            borderColor: Theme.alpha(Theme.text, 0.08)
                            smoothing: Prefs.squircleF
                        }

                        Column {
                            id: sourceContent

                            x: Theme.dp(6)
                            y: Theme.dp(6)
                            width: parent.width - Theme.dp(12)
                            spacing: 0

                        Item {
                            width: sourceContent.width
                            height: Theme.dp(68)

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.dp(2)
                                anchors.rightMargin: Theme.dp(2)
                                spacing: Theme.dp(12)

                                Rectangle {
                                    Layout.preferredWidth: Theme.dp(40)
                                    Layout.preferredHeight: Theme.dp(40)
                                    radius: Theme.dp(12)
                                    color: sourceBlock.on ? Theme.primaryContainer : Theme.surfaceHigh

                                    LText {
                                        anchors.centerIn: parent
                                        role: "labelLarge"
                                        text: String(sourceBlock.modelData.title || "?").slice(0, 1).toUpperCase()
                                        color: sourceBlock.on ? Theme.primary : Theme.subtextDim
                                    }

                                    Icon {
                                        anchors.centerIn: parent
                                        name: String(sourceBlock.modelData.glyph || "public")
                                        size: Theme.dp(21)
                                        color: sourceBlock.on ? Theme.primary : Theme.subtextDim
                                    }

                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.dp(6)

                                        LText {
                                            role: "titleSmall"
                                            text: sourceBlock.modelData.title
                                            color: sourceBlock.on ? Theme.text : Theme.subtext
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }

                                        LText {
                                            role: "labelSmall"
                                            text: picker.sourceStreamCount(sourceBlock.modelData)
                                            color: Theme.subtextDim
                                        }

                                        Icon {
                                            name: "expand_more"
                                            size: Theme.dp(17)
                                            color: Theme.subtextDim
                                            rotation: sourceBlock.open ? 180 : 0

                                            Behavior on rotation {
                                                NumberAnimation {
                                                    duration: Theme.durFastSpatial
                                                    easing.type: Easing.Bezier
                                                    easing.bezierCurve: Theme.curveFastSpatial
                                                }

                                            }

                                        }

                                    }

                                    LText {
                                        Layout.fillWidth: true
                                        role: "labelSmall"
                                        text: sourceBlock.modelData.configured === true ? (sourceBlock.modelData.description || "") : ((sourceBlock.modelData.auth_fields || []).length > 0 ? Tr.t("Add credentials below") : (sourceBlock.modelData.message || Tr.t("Add settings in the config")))
                                        color: Theme.subtextDim
                                        elide: Text.ElideRight
                                    }

                                }

                                Switch {
                                    Layout.alignment: Qt.AlignVCenter
                                    checked: sourceBlock.on
                                    onToggled: picker.toggleSource(sourceBlock.modelData.id)
                                }

                            }

                            MouseArea {
                                anchors.fill: parent
                                anchors.rightMargin: Theme.dp(62)
                                cursorShape: Qt.PointingHandCursor
                                onClicked: picker.expanded = sourceBlock.open ? "" : sourceBlock.modelData.id
                            }

                        }

                        // Credential form. It is an input instead of an error:
                        // the service writes credentials.toml with 0600 mode and
                        // reloads its config on the next call.
                        Column {
                            id: authBlock

                            width: sourceContent.width
                            spacing: Theme.dp(10)
                            clip: true
                            height: sourceBlock.open && ((sourceBlock.modelData.auth_fields || []).length > 0 || sourceBlock.modelData.supports_accounts === true || (sourceBlock.modelData.auth_accounts || []).length > 0) ? implicitHeight : 0
                            opacity: sourceBlock.open ? 1 : 0
                            visible: height > 0.5

                            Behavior on height {
                                NumberAnimation {
                                    duration: Theme.durFastSpatial
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: Theme.curveDefaultSpatial
                                }

                            }

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: Theme.durShort
                                }

                            }

                            Item {
                                width: parent.width
                                height: Theme.dp(4)
                            }

                            Item {
                                width: parent.width
                                height: picker.authError !== "" || picker.authStatus !== "" ? Theme.dp(28) : 0
                                visible: height > 0

                                LText {
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.dp(54)
                                    anchors.verticalCenter: parent.verticalCenter
                                    role: "labelSmall"
                                    text: picker.authError !== "" ? picker.authError : picker.authStatus
                                    color: picker.authError !== "" ? Theme.error : Theme.primary
                                    elide: Text.ElideRight
                                    width: parent.width - Theme.dp(54)
                                }

                            }

                            Column {
                                width: parent.width
                                spacing: Theme.dp(10)
                                visible: sourceBlock.modelData.supports_accounts === true || (sourceBlock.modelData.auth_accounts || []).length > 0

                                Repeater {
                                    model: sourceBlock.modelData.auth_accounts || []

                                    Column {
                                        id: accountRow

                                        required property var modelData

                                        width: authBlock.width
                                        spacing: Theme.dp(6)

                                        readonly property string busyKey: sourceBlock.modelData.id + "/account/" + accountRow.modelData.id

                                        RowLayout {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.leftMargin: Theme.dp(54)
                                            spacing: Theme.dp(6)

                                            LText {
                                                Layout.fillWidth: true
                                                role: "labelLarge"
                                                text: accountRow.modelData.label
                                                color: Theme.text
                                                elide: Text.ElideRight
                                            }

                                            IconButton {
                                                icon: "delete"
                                                size: "xs"
                                                visible: accountRow.modelData.removable === true
                                                enabled: picker.authBusyKey === ""
                                                onClicked: picker.removeAccount(sourceBlock.modelData.id, accountRow.modelData.id)
                                            }

                                        }

                                        LText {
                                            anchors.left: parent.left
                                            anchors.leftMargin: Theme.dp(54)
                                            role: "labelSmall"
                                            text: accountRow.modelData.detail || Tr.t("Personal account")
                                            color: Theme.subtextDim
                                        }

                                        RowLayout {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.leftMargin: Theme.dp(54)
                                            spacing: Theme.dp(8)

                                            TextField {
                                                id: accountInput

                                                Layout.fillWidth: true
                                                variant: "search"
                                                icon: "lock"
                                                password: true
                                                placeholder: Tr.t("Replace ") + accountRow.modelData.label + Tr.t(" token")
                                                text: ""
                                                onAccepted: picker.saveAccount(sourceBlock.modelData.id, accountRow.modelData.id, accountRow.modelData.label, accountInput.text)

                                                input.onActiveFocusChanged: {
                                                    if (!picker.host)
                                                        return ;

                                                    if (input.activeFocus)
                                                        picker.host.beginEdit();
                                                    else
                                                        picker.host.endEdit();

                                                }

                                                input.Keys.onEscapePressed: {
                                                    if (picker.host)
                                                        picker.host.endEdit();

                                                    input.focus = false;
                                                }
                                            }

                                            IconButton {
                                                icon: picker.authBusyKey === accountRow.busyKey ? "hourglass_top" : "check"
                                                size: "xs"
                                                enabled: picker.authBusyKey === "" || picker.authBusyKey === accountRow.busyKey
                                                onClicked: picker.saveAccount(sourceBlock.modelData.id, accountRow.modelData.id, accountRow.modelData.label, accountInput.text)
                                            }

                                        }

                                        Item {
                                            width: parent.width
                                            height: Theme.dp(8)
                                        }

                                    }

                                }

                                LText {
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.dp(54)
                                    role: "labelLarge"
                                    text: Tr.t("Add account")
                                    color: Theme.text
                                }

                                TextField {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.leftMargin: Theme.dp(54)
                                    id: newAccountNameInput

                                    variant: "search"
                                    icon: "person"
                                    placeholder: Tr.t("Account name")
                                    text: picker.newAccountName
                                    onTextEdited: picker.newAccountName = text

                                    input.onActiveFocusChanged: {
                                        if (!picker.host)
                                            return ;

                                        if (input.activeFocus)
                                            picker.host.beginEdit();
                                        else
                                            picker.host.endEdit();

                                    }

                                    input.Keys.onEscapePressed: {
                                        if (picker.host)
                                            picker.host.endEdit();

                                        input.focus = false;
                                    }
                                }

                                RowLayout {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.leftMargin: Theme.dp(54)
                                    spacing: Theme.dp(8)

                                    TextField {
                                        id: newAccountInput

                                        Layout.fillWidth: true
                                        variant: "search"
                                        icon: "lock"
                                        password: true
                                        placeholder: Tr.t("Personal user token")
                                        text: picker.newAccountToken
                                        onTextEdited: picker.newAccountToken = text

                                        input.onActiveFocusChanged: {
                                            if (!picker.host)
                                                return ;

                                            if (input.activeFocus)
                                                picker.host.beginEdit();
                                            else
                                                picker.host.endEdit();

                                        }

                                        input.Keys.onEscapePressed: {
                                            if (picker.host)
                                                picker.host.endEdit();

                                            input.focus = false;
                                        }
                                    }

                                    IconButton {
                                        icon: picker.authBusyKey === sourceBlock.modelData.id + "/new" ? "hourglass_top" : "add"
                                        size: "xs"
                                        enabled: picker.newAccountName !== "" && picker.newAccountToken !== "" && picker.authBusyKey === ""
                                        onClicked: picker.saveAccount(sourceBlock.modelData.id, "", picker.newAccountName, picker.newAccountToken)
                                    }

                                }

                                Item {
                                    width: parent.width
                                    height: Theme.dp(8)
                                }

                            }

                            Repeater {
                                model: (sourceBlock.modelData.supports_accounts === true || (sourceBlock.modelData.auth_accounts || []).length > 0) ? [] : (sourceBlock.modelData.auth_fields || [])

                                Column {
                                    id: authField

                                    required property var modelData

                                    width: authBlock.width
                                    spacing: Theme.dp(6)

                                    readonly property string busyKey: sourceBlock.modelData.id + "/" + authField.modelData.key

                                    LText {
                                        anchors.left: parent.left
                                        anchors.leftMargin: Theme.dp(54)
                                        role: "labelSmall"
                                        text: authField.modelData.label + (authField.modelData.required === true ? "" : Tr.t(" · optional"))
                                        color: Theme.subtext
                                    }

                                    RowLayout {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.leftMargin: Theme.dp(54)
                                        spacing: Theme.dp(8)

                                        TextField {
                                            id: authInput

                                            Layout.fillWidth: true
                                            // Match the comment composer's pill input.
                                            variant: "search"
                                            icon: authField.modelData.secret === true ? "lock" : "person"
                                            placeholder: authField.modelData.placeholder || authField.modelData.label
                                            password: authField.modelData.secret === true
                                            text: ""
                                            onAccepted: picker.saveCredential(sourceBlock.modelData.id, authField.modelData.key, authInput.text)

                                            input.onActiveFocusChanged: {
                                                if (!picker.host)
                                                    return ;

                                                if (input.activeFocus)
                                                    picker.host.beginEdit();
                                                else
                                                    picker.host.endEdit();

                                            }

                                            input.Keys.onEscapePressed: {
                                                if (picker.host)
                                                    picker.host.endEdit();

                                                input.focus = false;
                                            }
                                        }

                                        IconButton {
                                            icon: picker.authBusyKey === authField.busyKey ? "hourglass_top" : "check"
                                            size: "xs"
                                            enabled: picker.authBusyKey === "" || picker.authBusyKey === authField.busyKey
                                            onClicked: picker.saveCredential(sourceBlock.modelData.id, authField.modelData.key, authInput.text)
                                        }

                                    }

                                    LText {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.leftMargin: Theme.dp(54)
                                        visible: String(authField.modelData.help || "") !== ""
                                        role: "labelSmall"
                                        text: authField.modelData.help || ""
                                        color: Theme.subtextDim
                                        wrapMode: Text.Wrap
                                    }

                                    Item {
                                        width: parent.width
                                        height: Theme.dp(8)
                                    }

                                }

                            }

                        }

                        // Individual streams, only while the source is open.
                        Column {
                            id: streamsBlock

                            width: sourceContent.width
                            spacing: 0
                            clip: true
                            height: sourceBlock.open ? implicitHeight : 0
                            opacity: sourceBlock.open ? 1 : 0
                            visible: height > 0.5

                            Behavior on height {
                                NumberAnimation {
                                    duration: Theme.durFastSpatial
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: Theme.curveDefaultSpatial
                                }

                            }

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: sourceBlock.open ? Theme.durMedium : Theme.durShort
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: Theme.curveEffects
                                }

                            }

                            Item {
                                width: parent.width
                                height: Theme.dp(6)
                            }

                            Repeater {
                                model: sourceBlock.modelData.streams || []

                                Item {
                                    id: streamRow

                                    required property var modelData

                                    width: sourceContent.width
                                    height: Theme.dp(60)

                                    readonly property bool on: picker.streamOn(streamRow.modelData)

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.dp(54)
                                        anchors.rightMargin: 0
                                        spacing: Theme.dp(12)

                                        Rectangle {
                                            Layout.preferredWidth: Theme.dp(30)
                                            Layout.preferredHeight: Theme.dp(30)
                                            radius: Theme.dp(15)
                                            color: streamRow.on ? Theme.secondaryContainer : Theme.surfaceHigh

                                            Icon {
                                                anchors.centerIn: parent
                                                name: String(streamRow.modelData.glyph || sourceBlock.modelData.glyph || "public")
                                                size: Theme.dp(16)
                                                color: streamRow.on ? Theme.secondary : Theme.subtextDim
                                            }

                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0

                                            LText {
                                                Layout.fillWidth: true
                                                role: "bodyMedium"
                                                text: streamRow.modelData.title
                                                color: streamRow.on ? Theme.text : Theme.subtext
                                                elide: Text.ElideRight
                                            }

                                            LText {
                                                Layout.fillWidth: true
                                                role: "labelSmall"
                                                text: streamRow.modelData.configured === false ? Tr.t("Needs credentials") : (streamRow.modelData.subtitle || streamRow.modelData.kind || "")
                                                color: streamRow.modelData.configured === false ? Theme.error : Theme.subtextDim
                                                elide: Text.ElideRight
                                            }

                                        }

                                        Switch {
                                            Layout.alignment: Qt.AlignVCenter
                                            checked: streamRow.on
                                            disabled: streamRow.modelData.configured === false
                                            onToggled: picker.toggleStream(streamRow.modelData.id)
                                        }

                                    }

                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        anchors.leftMargin: Theme.dp(54)
                                        height: 1
                                        color: Theme.alpha(Theme.text, 0.05)
                                    }

                                }

                            }

                            Item {
                                width: sourceContent.width
                                height: (sourceBlock.modelData.streams || []).length === 0 ? Theme.dp(44) : 0
                                visible: height > 0

                                LText {
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.dp(54)
                                    anchors.verticalCenter: parent.verticalCenter
                                    role: "labelSmall"
                                    text: Tr.t("No streams yet — add one in the config.")
                                    color: Theme.subtextDim
                                }

                            }

                        }

                        }

                    }

                }

            }

        }

        LText {
            Layout.fillWidth: true
            role: "labelSmall"
            text: Tr.t("Changes apply to this card only. New Discord streams start off.")
            color: Theme.subtextDim
            wrapMode: Text.Wrap
        }

    }

}
