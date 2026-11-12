import QtQuick
import qs

// m3 list item on its own container. in a group the outer corners round large
// and the corners meeting a neighbour stay tight, 2px apart
Item {
    id: li

    property string headline: ""
    property string supporting: ""
    property string overline: ""
    property string icon: ""
    property real iconFill: 0
    property color iconColor: Theme.subtext
    property color containerColor: Theme.surfaceHigh
    property bool first: true
    property bool last: true
    property bool clickable: true
    property bool selected: false
    property bool disabled: false
    property int supportingLines: 1
    property real outerRadius: Theme.dp(20)
    property real innerRadius: Theme.dp(5)
    property string accessibleName: ""
    property string accessibleDescription: ""
    property alias leading: leadSlot.data
    property alias trailing: trailSlot.data
    readonly property bool hasLeading: li.icon !== "" || leadSlot.children.length > 0

    signal clicked()

    function activate() {
        if (li.clickable && !li.disabled)
            li.clicked();
    }

    activeFocusOnTab: li.clickable && !li.disabled
    Accessible.role: Accessible.ListItem
    Accessible.name: li.accessibleName !== "" ? li.accessibleName : (li.headline !== "" ? li.headline : li.supporting)
    Accessible.description: li.accessibleDescription !== "" ? li.accessibleDescription : (li.headline !== "" ? li.supporting : "")
    Accessible.selected: li.selected
    Accessible.focusable: li.clickable && !li.disabled
    Accessible.focused: li.activeFocus
    Accessible.onPressAction: li.activate()
    Keys.onSpacePressed: li.activate()
    Keys.onReturnPressed: li.activate()
    Keys.onEnterPressed: li.activate()

    implicitHeight: Math.max(li.supporting !== "" || li.overline !== "" ? Theme.dp(64) : Theme.dp(52), col.implicitHeight + Theme.dp(20))
    implicitWidth: Theme.dp(320)
    opacity: li.disabled ? Theme.disabledContent : 1

    Rectangle {
        id: box

        anchors.fill: parent
        color: li.selected ? Theme.secondaryContainer : li.containerColor
        topLeftRadius: li.first ? li.outerRadius : li.innerRadius
        topRightRadius: li.first ? li.outerRadius : li.innerRadius
        bottomLeftRadius: li.last ? li.outerRadius : li.innerRadius
        bottomRightRadius: li.last ? li.outerRadius : li.innerRadius

        Behavior on color {
            ColorAnimation {
                duration: Theme.durDefaultEffects
            }

        }

    }

    StateLayer {
        visible: li.clickable
        enabled: li.clickable && !li.disabled
        radius: li.innerRadius
        tint: Theme.text
        onClicked: {
            li.forceActiveFocus();
            li.activate();
        }
    }

    Item {
        id: leadBox

        visible: li.hasLeading
        width: li.hasLeading ? Theme.dp(40) : 0
        height: Theme.dp(40)
        anchors.left: parent.left
        anchors.leftMargin: Theme.dp(14)
        anchors.verticalCenter: parent.verticalCenter

        Icon {
            visible: li.icon !== ""
            anchors.centerIn: parent
            name: li.icon
            size: Theme.dp(22)
            fill: li.selected ? 1 : li.iconFill
            color: li.selected ? Theme.fgSecondaryContainer : li.iconColor
        }

        Item {
            id: leadSlot

            anchors.fill: parent
        }

    }

    Column {
        id: col

        anchors.left: li.hasLeading ? leadBox.right : parent.left
        anchors.leftMargin: li.hasLeading ? Theme.dp(12) : Theme.dp(18)
        anchors.right: trailSlot.left
        anchors.rightMargin: Theme.dp(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1

        LText {
            visible: li.overline !== ""
            width: parent.width
            text: li.overline
            role: "labelSmall"
            color: Theme.subtext
            elide: Text.ElideRight
            Accessible.ignored: true
        }

        LText {
            width: parent.width
            text: li.headline
            role: "bodyLarge"
            weight: 480
            color: li.selected ? Theme.fgSecondaryContainer : Theme.text
            elide: Text.ElideRight
            Accessible.ignored: true
        }

        LText {
            visible: li.supporting !== ""
            width: parent.width
            text: li.supporting
            role: "bodyMedium"
            color: li.selected ? Theme.alpha(Theme.fgSecondaryContainer, 0.8) : Theme.subtext
            wrapMode: li.supportingLines > 1 ? Text.WordWrap : Text.NoWrap
            maximumLineCount: li.supportingLines
            elide: Text.ElideRight
            Accessible.ignored: true
        }

    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -Theme.dp(2)
        radius: (li.first ? li.outerRadius : li.innerRadius) + Theme.dp(2)
        color: "transparent"
        border.width: li.activeFocus && li.clickable && !li.disabled ? Theme.dp(2) : 0
        border.color: Theme.primary
        visible: border.width > 0 && Prefs.a11yFocusRing
        z: 10
    }

    Row {
        id: trailSlot

        anchors.right: parent.right
        anchors.rightMargin: Theme.dp(16)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.dp(8)
    }

}
