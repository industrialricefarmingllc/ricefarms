import QtQuick
import Quickshell
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
    property var toast: null
    property bool bodyOpen: false
    property bool closing: false
    property bool panelVisible: false
    property bool maskActive: false
    property real revealRadius: 0

    screen: dock ? (dock.launcherScreen || dock.screen) : null
    // Keep the layer surface mapped from startup: mapping it on Super was the
    // remaining ~100 ms first-frame cost. Closed means transparent + no input.
    visible: root.dock !== null
    color: "transparent"
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.panelVisible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    WlrLayershell.namespace: "lucid-launcher"
    mask: Region { item: root.panelVisible ? face : null }

    anchors {
        top: true
        left: true
        right: true
    }

    readonly property real topHalf: root.screen ? root.screen.height / 2 : Theme.dp(456)
    readonly property real collapsedPanelH: root.collapsedContentH * root.scaleFactor + root.padV * 2 + root.ring * 2
    readonly property real panelHeight: root.contentH * root.scaleFactor + root.padV * 2 + root.ring * 2
    readonly property real collapsedTop: root.topHalf * 0.618
    // the space the launcher is allowed to use starts under the top bar
    readonly property real barBottom: Prefs.barEnabled ? Prefs.effectiveBarTopMargin + Prefs.barHeight + Prefs.shellGap : 0
    // the collapsed head stays at the golden mark; the open panel centres
    // itself in the space below the bar instead of keeping a top bias
    readonly property real openTop: Math.round(root.barBottom + Math.max(0, root.screen.height - root.barBottom - root.panelHeight) / 2)
    margins.top: root.bodyOpen ? root.openTop : Math.round(root.collapsedTop)
    implicitWidth: dock ? dock.menuWidth : Theme.dp(760)
    // The surface used to span the whole output through the left/right anchors,
    // while the panel is only ~790 px of it. QuickShell damages the whole
    // surface on every commit, so the empty sides were ~40 % of the pixels
    // pushed to the compositor on every reveal frame, hover and keystroke, and
    // the glass capture region reached past the glass. Equal side margins leave
    // the panel exactly where it was and keep the surface at the panel + 1 px.
    readonly property real surfaceWidth: Math.ceil(face.width * root.scaleFactor + root.padH * 2 + root.ring * 2 + Theme.dp(2))
    margins.left: root.screen ? Math.max(0, Math.round((root.screen.width - root.surfaceWidth) / 2)) : 0
    margins.right: root.screen ? Math.max(0, Math.round((root.screen.width - root.surfaceWidth) / 2)) : 0

    readonly property real scaleFactor: 1.35
    readonly property real padH: 6
    readonly property real padV: 8
    // wide enough for seven cards exactly when the wallpaper picker is up;
    // every other mode keeps the normal launcher width
    readonly property real pickerWidth: (face && face.pickerMode && face.wallStrip && face.wallStrip.idealWidth > 0) ? face.wallStrip.idealWidth + (face.kindRailWidth || 0) : 0
    readonly property real faceWidth: {
        var base = Math.min(root.dock ? root.dock.menuWidth : Theme.dp(760), root.screen.width - Theme.dp(80)) * 0.75;
        if (root.pickerWidth > 0)
            return Math.min(root.screen.width - Theme.dp(80), root.pickerWidth);
        return base;
    }
    // fixed open height: reading dock.menuHeight made the surface resize while
    // the app/list rows and picker populated, which is itself a visible jitter.
    // It reads barBottom rather than margins.top, which now depends on the
    // panel height this feeds.
    readonly property real openContentH: Math.min(Theme.dp(430), (root.screen.height - root.barBottom - Theme.dp(40) - root.ring * 2) / root.scaleFactor - root.padV * 2)
    readonly property real collapsedContentH: face ? face.headHeight : Prefs.launcherHeadH
    readonly property real contentH: root.bodyOpen ? root.openContentH : root.collapsedContentH
    readonly property int panelPad: dock ? dock.panelPadding : Theme.dp(36)
    readonly property real revealCenterY: root.ring + root.padV + root.collapsedContentH * root.scaleFactor * 0.5
    readonly property real revealMax: Math.hypot(face.width * root.scaleFactor / 2 + root.padH + root.ring, Math.max(root.revealCenterY, root.height - root.revealCenterY)) + 8
    readonly property real ring: Theme.dp(4)
    readonly property var activeBorderColours: HyprConfig.coloursOf(HyprConfig.value("general.col.active_border"))
    readonly property color activeBorderColour: root.activeBorderColours.length > 0 ? root.activeBorderColours[0] : Theme.accent
    readonly property real activeBorderWidth: Math.max(1, HyprConfig.num("general.border_size", 1))
    // one rung up the matugen surface ladder, keeping the panel's translucency
    readonly property color panelFill: Theme.withBlur(Theme.bgTile)
    // the window border lifted the same rung, so it still reads against the fill
    readonly property color panelBorder: Theme.atTone(root.activeBorderColour, Theme.toneOf(root.activeBorderColour) + (Theme.isLight ? -5 : 5))
    implicitHeight: root.panelHeight
    onBodyOpenChanged: {
        // once the body is out, the circle must release the whole surface
        if (root.bodyOpen && !root.closing) {
            root.revealRadius = Math.max(root.width, root.height) * 2;
            root.maskActive = false;
        }
    }

    Connections {
        target: face

        function onModeChanged() {
            if (face.mode === "translate")
                root.bodyOpen = true;
        }
    }

    Connections {
        target: root.dock

        function onMenuOpenChanged() {
            if (!root.dock)
                return ;

            if (root.dock.menuOpen) {
                closeHide.stop();
                // settle the body before the surface becomes visible, so a
                // reopen never shows the last session's expanded content
                // retracting under the reveal
                root.bodyOpen = face ? face.searchText !== "" : false;
                root.panelVisible = true;
                root.startOpen();
            } else {
                openAnim.stop();
                root.panelVisible = true;
                root.closing = true;
                root.maskActive = true;
                root.revealRadius = root.revealMax;
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
        onFinished: {
            root.revealRadius = Math.max(root.width, root.height) * 2;
            root.maskActive = false;
        }
    }

    Timer {
        id: closeHide

        interval: Theme.ms(180)
        onTriggered: {
            root.closing = false;
            root.maskActive = false;
            root.panelVisible = false;
            root.bodyOpen = false;
        }
    }

    NumberAnimation {
        id: closeAnim

        target: root
        property: "revealRadius"
        to: 0
        duration: Theme.ms(140)
        easing.type: Easing.OutCubic
        onFinished: {
            root.closing = false;
            root.maskActive = false;
            root.panelVisible = false;
            root.bodyOpen = false;
        }
    }

    // everything is layered so the window can be revealed through a circle
    Item {
        id: canvas
        anchors.fill: parent
        visible: root.panelVisible || root.closing
        layer.enabled: root.maskActive
        layer.effect: ShaderEffect {
            property vector2d center: Qt.vector2d(0.5, root.revealCenterY / Math.max(1, root.height))
            property real radius: root.revealRadius / Math.max(1, root.width)
            property real aspect: root.height / Math.max(1, root.width)
            fragmentShader: "LauncherMask.qsb"
        }

    SquircleRect {
        id: surface

        anchors.horizontalCenter: parent.horizontalCenter
        y: 0
        width: face.width * root.scaleFactor + root.padH * 2 + root.ring * 2
        height: face.height * root.scaleFactor + root.padV * 2 + root.ring * 2
        fillColor: root.panelFill
        borderColor: root.panelBorder
        borderWidth: root.activeBorderWidth
        radius: Theme.radiusXl + root.ring
        smoothing: Prefs.squircleF
        z: -1
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
        targetHeight: root.bodyOpen ? root.contentH : root.collapsedContentH
        mode: root.dock ? root.dock.mode : "apps"
        model: root.dock ? root.dock.launcherResultsModel : null
        appsModel: root.dock ? root.dock.launcherAppsModel : null
        emojiModel: root.dock ? root.dock.launcherEmojiModel : null
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
        onAppActivated: (index) => root.dock && root.dock.activateApp(index)
        onEmojiCopied: (emoji) => {
            Quickshell.execDetached(["wl-copy", "--", emoji]);
            if (root.toast)
                root.toast.popup("copy", emoji + " copied!", false);
            if (root.dock)
                root.dock.menuOpen = false;
        }
        onCloseRequested: if (root.dock) root.dock.menuOpen = false
        onBackRequested: if (root.dock) root.dock.setSearchText(root.dock.mode === "commands" ? "" : ">")
        onTranslateSubmitted: (text) => {
            face.submitTranslate(text);
            if (root.dock) root.dock.setSearchText("");
        }
        onModeRequested: (m) => {
            if (!root.dock) return;
            root.bodyOpen = true;
            if (m === "power") { root.dock.menuOpen = false; root.dock.openSession(); return; }
            if (m === "widgets") { root.dock.openWidgetPanel(); return; }
            root.dock.selectMode(m);
        }
        onDeleteRequested: (index) => root.dock && root.dock.deleteResult(index)
        onHideRequested: (index) => root.dock && root.dock.hideResult(index)
        onClearRequested: Clip.wipe()
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

    // Tab walks the launcher tabs until the language rail is engaged; then the
    // rail's own keys cycle languages without the window shortcut intercepting.
    Shortcut {
        sequence: "Tab"
        enabled: root.visible && !(face && (face.tabsFocused || (face.displayMode === "translate" && face.translateLanguageEngaged)))
        onActivated: root.cycleTab(1)
    }
    Shortcut {
        sequence: "Shift+Tab"
        enabled: root.visible && !(face && (face.tabsFocused || (face.displayMode === "translate" && face.translateLanguageEngaged)))
        onActivated: root.cycleTab(-1)
    }
    // Arrow Down is the deliberate way into the language rail. The search
    // field has the same handler for the dock-embedded launcher, which has no
    // window-level shortcuts. It never changes the choice: the current chip
    // pulses instead.
    Shortcut {
        sequence: "Down"
        enabled: root.visible && face && face.displayMode === "translate" && !face.tabsFocused
        onActivated: if (face) face.activateTranslateLanguage()
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
        // Direct tab selection leaves the field empty; Translate still needs
        // its body, unlike the folded app-launcher head.
        root.bodyOpen = face ? (face.searchText !== "" || face.mode === "translate") : false;
        // The surface is already mapped, so the circular gate can start in the
        // same frame without paying the old window-creation cost. Start at a
        // few pixels rather than zero so the first visible frame is the dot.
        root.maskActive = true;
        root.revealRadius = 2;
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
    function toggleLauncher() {
        const d = root.dock;
        if (!d)
            return ;
        if (!d.menuOpen) {
            d.pinnedMode = "apps";
            d.setSearchText("");
        }
        d.aimLauncher();
        d.menuOpen = !d.menuOpen;
    }

    // Hyprland calls this directly as `global, quickshell:launcher`; it avoids
    // spawning `qs ipc call` (a ~450 ms process start) on the Super keybind.
    GlobalShortcut {
        name: "launcher"
        description: "Toggle the Lucid application launcher"
        onPressed: root.toggleLauncher()
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
            if (face && face.consumeTranslateLanguageFocus && face.consumeTranslateLanguageFocus())
                return;
            // Do not steal focus back from a language row the user has just
            // engaged while the focus grab was arming.
            if (face && !face.translateLanguageEngaged)
                face.focusSearch();
        }
        onRunningChanged: {
            if (!grabArm.running)
                grabArm.armed = false;
        }
    }
}
