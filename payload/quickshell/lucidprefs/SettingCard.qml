import QtQuick
import qs
import "../squircle"

Item {
    id: card

    property string title: ""
    property string subtitle: ""
    default property alias content: inner.data

    implicitWidth: parent ? parent.width : 400
    implicitHeight: header.height + surface.implicitHeight

    Column {
        id: header

        width: parent.width
        spacing: 2

        Text {
            text: card.title
            color: Theme.accent
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontLabel
            font.bold: true
            font.letterSpacing: 0.8
            visible: card.title !== ""
            bottomPadding: 8
        }

    }

    SquircleRect {
        id: surface

        anchors.top: header.bottom
        width: parent.width
        implicitHeight: inner.implicitHeight + 8
        radius: Theme.radiusXl
        fillColor: Theme.withBlur(Theme.bgTile)
        smoothing: Prefs.squircleF

        Column {
            id: inner

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: 4
            spacing: 0
        }

    }

}
