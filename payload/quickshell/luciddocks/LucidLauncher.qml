import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs
import qs.lucidui
import qs.lucidprefs as LP
import "../squircle"

// Raycast-like top-centre launcher. It reuses the dock's LauncherFace and its
// models, but owns the surface: top anchored, collapsed to the head row until a
// tab is picked or typing begins, revealed through a growing circle.
PanelWindow {
    id: root

    property var dock: null
    property bool bodyOpen: false
    property real revealSize: 0

    screen: dock ? (dock.launcherScreen || dock.screen) : null
    visible: dock ? dock.menuOpen : false
    color: "transparent"
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    WlrLayershell.namespace: "lucid-launcher"
    mask: Region { item: face }

    anchors {
        top: true
        left: true
        right: true
    }

    margins.top: Theme.dp(72 + 20)
    implicitWidth: dock ? dock.menuWidth : Theme.dp(760)

    readonly property real scaleFactor: 1.35
    readonly property real padH: 6
    readonly property real padV: 8
    readonly property real faceWidth: Math.min(root.dock ? root.dock.menuWidth : Theme.dp(760), root.screen.width - Theme.dp(80))
    readonly property real openContentH: Math.min(root.dock ? root.dock.menuHeight : Theme.dp(520), (root.screen.height - root.margins.top - Theme.dp(32)) / root.scaleFactor - root.padV * 2)
    readonly property real collapsedContentH: root.face ? root.face.headHeight : Prefs.launcherHeadH
    readonly property real contentH: root.bodyOpen ? root.openContentH : root.collapsedContentH
    readonly property int panelPad: dock ? dock.panelPadding : Theme.dp(36)
    implicitHeight: root.contentH * root.scaleFactor + root.padV * 2
    Behavior on implicitHeight {
        NumberAnimation {
            duration: Theme.durDefault
            easing.type: Easing.OutCubic
        }
    }

    // mask sources must live outside the item they mask
    Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Rectangle {
            anchors.centerIn: parent
            width: root.revealSize
            height: root.revealSize
            radius: width / 2
            color: "white"
        }
    }

    onVisibleChanged: {
        if (!visible)
            return ;
        bodyOpen = false;
        revealSize = 0;
        revealAnim.restart();
        if (face)
            face.focusSearch();
    }

    // everything is layered so the window can be revealed through a circle
    Item {
        id: canvas
        anchors.fill: parent
        // mask temporarily disabled: verify the surface, then re-enable the circle

    NumberAnimation {
        id: revealAnim
        target: root
        property: "revealSize"
        from: 0
        to: 2600
        duration: Theme.durEnter
        easing.type: Easing.OutCubic
    }

    SquircleRect {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 0
        width: face.width * root.scaleFactor + root.padH * 2
        height: face.height * root.scaleFactor + root.padV * 2
        fillColor: Theme.bg
        radius: Theme.radiusXl
        smoothing: Prefs.squircleF
        z: -1
    }

    LauncherFace {
        id: face
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.faceWidth
        height: root.contentH
        anchors.topMargin: root.padV
        scale: root.scaleFactor
        transformOrigin: Item.Top
        headOnly: !root.bodyOpen
        opacity: 1
        targetWidth: root.faceWidth - root.panelPad
        targetHeight: root.bodyOpen ? (root.contentH - root.panelPad) : root.collapsedContentH
        mode: root.dock ? root.dock.mode : "apps"
        model: root.dock ? root.dock.launcherResultsModel : null
        resultCount: root.dock ? root.dock.resultCount : 0
        wallpaperModel: root.dock ? root.dock.launcherPickerModel : null
        kindRailWidth: root.dock ? root.dock.wallKindRailWidth : 0
        wallHeroW: root.dock ? root.dock.wallHeroW : 0
        wallHeroH: root.dock ? root.dock.wallHeroH : 0
        wallMidW: root.dock ? root.dock.wallMidW : 0
        wallMidH: root.dock ? root.dock.wallMidH : 0
        wallSmallW: root.dock ? root.dock.wallSmallW : 0
        wallSmallH: root.dock ? root.dock.wallSmallH : 0
        wallTinyW: root.dock ? root.dock.wallTinyW : 0
        wallTinyH: root.dock ? root.dock.wallTinyH : 0
        wallCardGap: root.dock ? root.dock.wallCardGap : 0
        appliedWallpaper: root.dock ? root.dock.appliedWallpaper : ""
        highlightQuery: root.dock ? root.dock.filterQuery : ""
        showPowerChips: Prefs.launcherPowerChips
        powerButtons: String(Prefs.launcherPowerButtons).split(",")
        armedPower: root.dock ? root.dock.armedPower : ""
        onPowerChipTapped: (id) => root.dock && root.dock.requestPower(id)
        onActivated: (index) => root.dock && root.dock.activateResult(index)
        onCloseRequested: if (root.dock) root.dock.menuOpen = false
        onBackRequested: if (root.dock) root.dock.setSearchText(root.dock.mode === "commands" ? "" : ">")
        onModeRequested: (m) => {
            if (!root.dock) return;
            root.bodyOpen = true;
            root.revealSize = Math.max(root.width, root.height) * 1.45;
            if (m === "power") { root.dock.menuOpen = false; root.dock.openSession(); return; }
            if (m === "widgets") { root.dock.openWidgetPanel(); return; }
            root.dock.setSearchText(root.dock.prefixFor(m));
        }
        onDeleteRequested: (index) => root.dock && root.dock.deleteResult(index)
        onHideRequested: (index) => root.dock && root.dock.hideResult(index)
        onClearRequested: Clip.wipe()
        onWallpaperPreviewed: (path) => root.dock && root.dock.requestWallpaper(path)
        onWallpaperChosen: (path) => {
            if (!root.dock) return;
            var picker = face.wallStrip;
            root.dock.applyWallpaper(path, picker ? Qt.point(picker.originX, picker.originY) : Qt.point(-1, -1));
            root.dock.menuOpen = false;
        }
        onSearchTextChanged: if (face.searchText !== "") {
            root.bodyOpen = true;
            root.revealSize = Math.max(root.width, root.height) * 1.45;
        }
    }
    }

    Component.onCompleted: if (root.dock) root.dock.externalFace = face
    Component.onDestruction: if (root.dock) root.dock.externalFace = null

    // Tab cycles only the launcher's tabs; nothing else in the window sees Tab.
    Shortcut {
        sequence: "Tab"
        enabled: root.visible
        onActivated: root.cycleTab(1)
    }
    Shortcut {
        sequence: "Shift+Tab"
        enabled: root.visible
        onActivated: root.cycleTab(-1)
    }
    function cycleTab(dir) {
        if (!face || !face.modes || face.modes.length === 0)
            return;
        root.bodyOpen = true;
        face.cycleMode(dir);
    }
}
