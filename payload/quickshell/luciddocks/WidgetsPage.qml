import QtQuick
import qs
import qs.lucidui
import "../lucidwidgets"
import "../squircle"

// Native launcher view for the Widgets tab. The launcher already supplies the
// frame, search field and tab strip; this is only the catalogue, laid out in
// the same tile rhythm as the other launcher pages.
Item {
    id: root

    property string query: ""
    property string category: "all"
    property int currentIndex: 0
    signal added(string name)

    readonly property var entries: {
        var q = root.query.trim().toLowerCase();
        var out = [];
        for (var i = 0; i < Widgets.catalogue.length; i++) {
            var type = Widgets.catalogue[i];
            if (root.category !== "all" && type.id !== root.category)
                continue;

            for (var j = 0; j < type.variants.length; j++) {
                var v = type.variants[j];
                var hay = (type.name + " " + v.name + " " + (v.blurb || "")).toLowerCase();
                if (q !== "" && hay.indexOf(q) === -1)
                    continue;
                out.push({
                    "wtype": type.id,
                    "typeName": type.name,
                    "variantId": v.id,
                    "name": v.name,
                    "blurb": v.blurb || "",
                    "w": v.w || 0,
                    "h": v.h || 0
                });
            }
        }
        return out;
    }
    readonly property int columns: Math.max(2, Math.floor(width / Theme.dp(150)))
    readonly property real cellW: columns > 0 ? width / columns : width

    onQueryChanged: root.currentIndex = 0
    onCategoryChanged: root.currentIndex = 0
    onEntriesChanged: if (root.currentIndex >= root.entries.length)
        root.currentIndex = Math.max(0, root.entries.length - 1)

    function stepHorizontal(dir) {
        if (root.entries.length === 0)
            return ;
        root.currentIndex = Math.max(0, Math.min(root.entries.length - 1, root.currentIndex + dir));
        grid.positionViewAtIndex(root.currentIndex, GridView.Contain);
    }
    function stepVertical(dir) {
        if (root.entries.length === 0)
            return ;
        root.currentIndex = Math.max(0, Math.min(root.entries.length - 1, root.currentIndex + dir * root.columns));
        grid.positionViewAtIndex(root.currentIndex, GridView.Contain);
    }
    function pageMove(dir) {
        if (root.entries.length === 0)
            return ;
        var rows = Math.max(1, Math.floor(grid.height / grid.cellHeight));
        root.currentIndex = Math.max(0, Math.min(root.entries.length - 1, root.currentIndex + dir * root.columns * rows));
        grid.positionViewAtIndex(root.currentIndex, GridView.Contain);
    }
    function resetSelection() {
        root.currentIndex = 0;
    }
    function activateCurrent() {
        if (root.currentIndex < 0 || root.currentIndex >= root.entries.length)
            return ;
        var e = root.entries[root.currentIndex];
        if (Widgets.full)
            return ;
        Widgets.spawn(e.wtype, e.variantId);
        root.added(e.name);
    }

    Flickable {
        id: chips

        x: Theme.dp(8)
        y: Theme.dp(4)
        width: root.width - Theme.dp(16)
        height: Theme.dp(30)
        contentWidth: chipRow.width
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Row {
            id: chipRow

            spacing: Theme.dp(6)

            Repeater {
                model: [{
                    "id": "all",
                    "name": "All"
                }].concat(Widgets.catalogue)

                Chip {
                    required property var modelData

                    kind: "filter"
                    text: modelData.name
                    selected: root.category === modelData.id
                    onClicked: root.category = (root.category === modelData.id && modelData.id !== "all") ? "all" : modelData.id
                }
            }
        }
    }

    GridView {
        id: grid

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: chips.bottom
        anchors.bottom: parent.bottom
        anchors.topMargin: Theme.dp(6)
        cellWidth: root.cellW
        cellHeight: Math.min(Theme.dp(184), root.cellW * 1.06)
        clip: true
        cacheBuffer: 180
        boundsBehavior: Flickable.StopAtBounds
        model: root.entries
        currentIndex: root.currentIndex

        delegate: Item {
            id: cell

            required property var modelData
            required property int index
            readonly property bool selected: root.currentIndex === cell.index
            readonly property bool hovered: hover.hovered

            width: grid.cellWidth
            height: grid.cellHeight

            Rectangle {
                anchors.fill: parent
                anchors.margins: Theme.dp(3)
                radius: Theme.radiusLg
                color: cell.selected ? Theme.withBlur(Theme.bgActive) : (cell.hovered ? Theme.withBlur(Theme.surfaceHighest) : Theme.withBlur(Theme.surfaceHigh))
            }

            Item {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.dp(9)
                height: Math.max(Theme.dp(58), cell.height - Theme.dp(56))

                WidgetPreview {
                    anchors.fill: parent
                    wtype: cell.modelData.wtype
                    wvariant: cell.modelData.variantId
                    hovered: cell.hovered
                    staggered: true
                    hold: grid.moving || grid.flicking
                }
            }

            LText {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: blurb.top
                anchors.leftMargin: Theme.dp(12)
                anchors.rightMargin: Theme.dp(12)
                anchors.bottomMargin: Theme.dp(1)
                role: "titleSmall"
                text: cell.modelData.name
                elide: Text.ElideRight
            }

            LText {
                id: blurb

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: Theme.dp(12)
                anchors.rightMargin: Theme.dp(12)
                anchors.bottomMargin: Theme.dp(8)
                role: "bodySmall"
                color: Theme.subtext
                text: cell.modelData.typeName
                elide: Text.ElideRight
            }

            HoverHandler {
                id: hover

                cursorShape: Qt.PointingHandCursor
                onHoveredChanged: if (hover.hovered)
                    root.currentIndex = cell.index
            }

            TapHandler {
                onTapped: {
                    root.currentIndex = cell.index;
                    if (!Widgets.full) {
                        Widgets.spawn(cell.modelData.wtype, cell.modelData.variantId);
                        root.added(cell.modelData.name);
                    }
                }
            }
        }
    }

    LText {
        anchors.centerIn: grid
        visible: root.entries.length === 0
        text: root.query.trim() === "" ? "No widgets available" : "No widgets match"
        role: "bodyMedium"
        color: Theme.subtext
    }
}
