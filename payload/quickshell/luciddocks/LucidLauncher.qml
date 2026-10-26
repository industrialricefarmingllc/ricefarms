import QtQuick
import Qt5Compat.GraphicalEffects
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
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
    property bool closing: false
    property bool panelVisible: false
    property real revealRadius: 0
    property string wallpaperPath: ""

    screen: dock ? (dock.launcherScreen || dock.screen) : null
    visible: root.panelVisible
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

    readonly property real topHalf: root.screen ? root.screen.height / 2 : Theme.dp(456)
    margins.top: Math.round(root.topHalf * 0.618)
    implicitWidth: dock ? dock.menuWidth : Theme.dp(760)

    readonly property real scaleFactor: 1.35
    readonly property real padH: 6
    readonly property real padV: 8
    readonly property real faceWidth: Math.min(root.dock ? root.dock.menuWidth : Theme.dp(760), root.screen.width - Theme.dp(80)) * 0.75
    readonly property real openContentH: Math.min(root.dock ? root.dock.menuHeight : Theme.dp(520), (root.screen.height - root.margins.top - Theme.dp(32) - root.ring * 2) / root.scaleFactor - root.padV * 2)
    readonly property real collapsedContentH: face ? face.headHeight : Prefs.launcherHeadH
    readonly property real contentH: root.bodyOpen ? root.openContentH : root.collapsedContentH
    readonly property int panelPad: dock ? dock.panelPadding : Theme.dp(36)
    readonly property real revealCenterY: root.ring + root.padV + root.collapsedContentH * root.scaleFactor * 0.5
    readonly property real revealMax: Math.hypot(face.width * root.scaleFactor / 2 + root.padH, Math.max(root.revealCenterY, root.height - root.revealCenterY)) + 8
    readonly property real ring: Theme.dp(4)
    readonly property var activeBorderColours: HyprConfig.coloursOf(HyprConfig.value("general.col.active_border"))
    readonly property color activeBorderColour: root.activeBorderColours.length > 0 ? root.activeBorderColours[0] : Theme.accent
    readonly property real activeBorderWidth: Math.max(1, HyprConfig.num("general.border_size", 1))
    implicitHeight: root.contentH * root.scaleFactor + root.padV * 2 + root.ring * 2
    Behavior on implicitHeight {
        NumberAnimation {
            duration: Theme.durDefault
            easing.type: Easing.OutCubic
        }
    }

    FileView {
        path: Quickshell.env("HOME") + "/.cache/current_wallpaper"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.wallpaperPath = text().trim()
    }

    onVisibleChanged: {
        if (visible)
            root.startOpen();
    }

    Connections {
        target: root.dock

        function onMenuOpenChanged() {
            if (!root.dock)
                return ;

            if (root.dock.menuOpen) {
                closeHide.stop();
                root.panelVisible = true;
                root.startOpen();
            } else {
                openAnim.stop();
                root.panelVisible = true;
                root.closing = true;
                closeAnim.restart();
                closeHide.restart();
            }
        }
    }

    NumberAnimation {
        id: openAnim

        target: root
        property: "revealRadius"
        from: 0
        to: root.revealMax
        duration: Theme.durEnter
        easing.type: Easing.OutCubic
    }

    Timer {
        id: closeHide

        interval: Theme.durExit + 60
        onTriggered: {
            root.closing = false;
            root.panelVisible = false;
        }
    }

    NumberAnimation {
        id: closeAnim

        target: root
        property: "revealRadius"
        to: 0
        duration: Theme.durExit
        easing.type: Easing.InCubic
        onFinished: {
            root.closing = false;
            root.panelVisible = false;
        }
    }

    // everything is layered so the window can be revealed through a circle
    Item {
        id: canvas
        anchors.fill: parent
        layer.enabled: true
        layer.effect: ShaderEffect {
            property vector2d center: Qt.vector2d(0.5, root.revealCenterY / Math.max(1, root.height))
            property real radius: root.revealRadius / Math.max(1, root.width)
            property real aspect: root.height / Math.max(1, root.width)
            fragmentShader: "LauncherMask.qsb"
        }

    Item {
        id: hole

        anchors.horizontalCenter: parent.horizontalCenter
        y: 0
        width: surface.width + root.ring * 2
        height: surface.height + root.ring * 2
        z: -2

        SquircleMask {
            id: holeMask

            anchors.fill: parent
            radius: Theme.radiusXl + root.ring
            smoothing: Prefs.squircleF
            visible: false
        }

        Image {
            id: holeWallpaper

            x: -hole.x
            y: -hole.y - root.margins.top
            width: root.screen.width
            height: root.screen.height
            source: root.wallpaperPath !== "" ? "file://" + root.wallpaperPath : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            visible: false
        }

        OpacityMask {
            anchors.fill: parent
            source: holeWallpaper
            maskSource: holeMask
        }
    }

    SquircleRect {
        id: surface

        anchors.horizontalCenter: parent.horizontalCenter
        y: root.ring
        width: face.width * root.scaleFactor + root.padH * 2
        height: face.height * root.scaleFactor + root.padV * 2
        fillColor: Theme.bg
        radius: Theme.radiusXl
        smoothing: Prefs.squircleF
        z: -1
    }

    SquircleRect {
        anchors.fill: hole
        fillColor: "transparent"
        borderColor: root.activeBorderColour
        borderWidth: root.activeBorderWidth
        radius: Theme.radiusXl + root.ring
        smoothing: Prefs.squircleF
        z: -0.5
    }

    LauncherFace {
        id: face
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.faceWidth
        height: root.contentH
        anchors.topMargin: root.ring + root.padV
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
    Shortcut {
        sequence: "Escape"
        enabled: root.visible
        onActivated: root.closeLauncher()
    }
    function cycleTab(dir) {
        if (!face || !face.modes || face.modes.length === 0)
            return;
        root.bodyOpen = true;
        face.cycleMode(dir);
    }
    function startOpen() {
        root.closing = false;
        root.bodyOpen = face ? face.searchText !== "" : false;
        root.revealRadius = 0;
        closeHide.stop();
        closeAnim.stop();
        openAnim.restart();
        if (face)
            face.focusSearch();
    }
    function closeLauncher() {
        if (root.dock)
            root.dock.menuOpen = false;
    }

    HyprlandFocusGrab {
        id: launcherGrab

        windows: [root]
        active: root.visible && grabArm.armed && root.dock && root.dock.menuOpen
        onCleared: {
            if (grabArm.armed)
                root.closeLauncher();
        }
    }

    Timer {
        id: grabArm

        property bool armed: false

        interval: 80
        running: root.visible && root.dock && root.dock.menuOpen
        onTriggered: {
            grabArm.armed = true;
            if (face)
                face.focusSearch();
        }
        onRunningChanged: {
            if (!grabArm.running)
                grabArm.armed = false;
        }
    }
}
