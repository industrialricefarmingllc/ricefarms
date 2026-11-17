import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QQC
import qs
import qs.lucidui

// A compact emoji grid for reactions. It reuses the composer's catalogue:
// Unicode entries paint as Twemoji SVGs, server entries as their CDN image.
QQC.Popup {
    id: picker

    property var catalog: []
    property var usage: ({})
    property string query: ""
    // Do not walk the whole catalogue or build delegates while closed; every
    // card and comment owns one of these popups.
    readonly property var filtered: picker.opened ? picker.matches() : []

    signal picked(var entry)

    width: Theme.dp(292)
    height: Theme.dp(330)
    padding: Theme.dp(8)
    modal: false
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    background: Rectangle {
        color: Theme.surfaceHigh
        radius: Theme.rad(16)
        border.width: 1
        border.color: Theme.alpha(Theme.outline, 0.5)
    }

    function matches() {
        var text = String(picker.query || "").trim().toLowerCase();
        var source = picker.catalog || [];
        var out = [];
        for (var i = 0; i < source.length; i++) {
            var entry = source[i];
            if (!entry)
                continue;
            if (text !== "" && String(entry.hay || entry.s || entry.n || "").indexOf(text) < 0)
                continue;
            out.push(entry);
            if (out.length >= 240)
                break;
        }
        return out;
    }

    function choose(entry) {
        if (!entry)
            return ;
        picker.picked(entry);
        picker.close();
    }

    onOpened: {
        picker.query = "";
        search.text = "";
        grid.positionViewAtBeginning();
        Qt.callLater(function () { search.forceActiveFocus(); });
    }

    contentItem: ColumnLayout {
        spacing: Theme.dp(6)

        QQC.TextField {
            id: search

            Layout.fillWidth: true
            placeholderText: Tr.t("Search emoji")
            placeholderTextColor: Theme.subtextDim
            color: Theme.text
            font.pixelSize: Theme.typeSize("bodySmall")
            background: Rectangle {
                color: Theme.surfaceHighest
                radius: Theme.rad(10)
            }
            onTextChanged: picker.query = text
            Keys.onEscapePressed: picker.close()
        }

        GridView {
            id: grid

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            cellWidth: Math.max(1, Math.floor(width / 6))
            cellHeight: cellWidth
            model: picker.opened ? picker.filtered : []

            delegate: Rectangle {
                id: cell

                required property var modelData
                required property int index

                width: grid.cellWidth
                height: grid.cellHeight
                radius: Theme.rad(8)
                color: cellArea.containsMouse ? Theme.surfaceHighest : "transparent"

                Twemoji {
                    anchors.centerIn: parent
                    size: Math.round(cell.width * 0.62)
                    emoji: String(cell.modelData.e || "")
                    imageSource: String(cell.modelData.image || "")
                    animated: cell.modelData.animated === true
                    fallbackColor: Theme.text
                }

                MouseArea {
                    id: cellArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: picker.choose(cell.modelData)
                }

            }

        }

    }

}
