import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import qs
import qs.lucidui
import qs.lucidprefs as LP
import "../squircle"
import "../lucidbar" as LucidBar

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
    // Toggle the layer's keyboard focus once after the wallpaper iris closes;
    // mapping an overlay above this surface can leave it drawn but unfocused.
    property bool focusKick: false
    // SUPER arms the launcher on press (before the tap is recognised on
    // release). Take the keyboard at that instant and buffer what is typed, so
    // characters pressed while the panel is still laying out are handed to the
    // search field instead of falling into the window underneath.
    property bool inputArmed: false
    property string queuedInput: ""

    property bool launcherGlassReady: false
    readonly property bool glassOn: root.launcherGlassReady && Prefs.liquidGlassEnabled
    readonly property bool maskedGlass: root.maskActive && root.maskCapable
    property bool maskCapable: false
    // Probe cadence. A compositor without the plugin used to be asked twice a
    // second for the whole session (~2 process spawns/s). Back off to one ask
    // per 5 s, still fast enough to notice a plugin option being enabled.
    property int probeDelay: 500

    function noteProbe(ok) {
        if (!ok)
            root.probeDelay = Math.min(5000, root.probeDelay * 2);
    }

    // This plugin build can clip its glass to a published circle. Until the
    // compositor restarts onto one, keep the opaque reveal (publishing the
    // full pill without the clip would flash a rectangle behind the iris).
    Process {
        id: maskProbe

        command: ["hyprctl", "getoption", "plugin:liquidglass:mask_support"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                root.maskCapable = text.indexOf("int: 1") !== -1;
                root.noteProbe(root.maskCapable);
            }
        }
    }

    Timer {
        interval: root.probeDelay
        repeat: true
        running: !root.maskCapable
        onTriggered: maskProbe.running = true
    }

    Process {
        id: glassProbe

        command: ["hyprctl", "getoption", "plugin:liquidglass:launcher_glass"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                root.launcherGlassReady = text.indexOf("int: 1") !== -1;
                root.noteProbe(root.launcherGlassReady);
            }
        }
    }

    Timer {
        interval: root.probeDelay
        repeat: true
        running: !root.launcherGlassReady
        onTriggered: glassProbe.running = true
    }

    screen: dock ? (dock.launcherScreen || dock.screen) : null
    // Keep the layer surface mapped from startup: mapping it on Super was the
    // remaining ~100 ms first-frame cost. Closed means transparent + no input.
    visible: root.dock !== null
    color: "transparent"
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: (root.inputArmed || (root.panelVisible && !root.closing && !root.focusKick))
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None
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
    // Use the panel height that is actually being revealed, not the largest
    // possible body: a collapsed open shows a 64 px head, and sizing the circle
    // to the expanded body crossed that head at t ~ 0.15 (two frames), which
    // read as "no mask". panelHeight is a binding, not a laid-out height, so a
    // direct-tab open still gets the full body on the first frame.
    readonly property real revealMax: Math.hypot(face.width * root.scaleFactor / 2 + root.padH + root.ring, Math.max(root.revealCenterY, root.panelHeight - root.revealCenterY)) + 8
    // The fully open body, and the circle that covers it. Both are derived from
    // openContentH instead of panelHeight/revealMax on purpose: onBodyOpenChanged
    // runs in the same notification turn as bodyOpen, and reading revealMax there
    // still yields the collapsed size (panelHeight's binding has not re-evaluated
    // yet). That stale target was the bug behind "typing freezes the reveal": the
    // circle retargeted to the 64 px head's radius, never covered the 604 px body,
    // and the mask was cut off mid-way.
    readonly property real openPanelH: root.openContentH * root.scaleFactor + root.padV * 2 + root.ring * 2
    readonly property real bodyRevealMax: Math.hypot(face.width * root.scaleFactor / 2 + root.padH + root.ring, Math.max(root.revealCenterY, root.openPanelH - root.revealCenterY)) + 8
    readonly property real ring: Theme.dp(4)
    // Collapsed, the launcher is a search pill: a true stadium (radius half
    // the surface height, no smoothing). Opened, it uses the same squircle
    // geometry as the compositor's windows, so the panel and the apps it
    // launches read as one shape family.
    readonly property real collapsedRadius: Theme.pill(root.collapsedPanelH)
    readonly property real expandedRadius: Theme.windowRadius
    readonly property real surfaceRadius: root.bodyOpen ? root.expandedRadius : root.collapsedRadius
    readonly property real surfaceSmoothing: root.bodyOpen ? Prefs.squircleF : 0
    readonly property var activeBorderColours: HyprConfig.coloursOf(HyprConfig.value("general.col.active_border"))
    readonly property color activeBorderColour: root.activeBorderColours.length > 0 ? root.activeBorderColours[0] : Theme.accent
    readonly property real activeBorderWidth: Math.max(1, HyprConfig.num("general.border_size", 1))
    // one rung up the matugen surface ladder, keeping the panel's translucency
    readonly property color panelFill: Theme.withBlur(Theme.bgTile)
    // the window border lifted the same rung, so it still reads against the fill
    readonly property color panelBorder: Theme.atTone(root.activeBorderColour, Theme.toneOf(root.activeBorderColour) + (Theme.isLight ? -5 : 5))
    implicitHeight: root.panelHeight

    // Typing during the grow used to switch the mask off outright, which popped
    // the body in. If the body arrives mid-reveal the window gets taller, so
    // grow the circle from where it is to a target that covers the *open* body
    // instead of cutting it. bodyRevealMax, not revealMax: see above.
    onBodyOpenChanged: {
        if (!root.bodyOpen || root.closing || !root.maskActive)
            return;
        const from = root.revealRadius;
        const to = root.bodyRevealMax;
        if (to <= from + 1) {
            // the circle already covers the body; release the layer rather
            // than run a retarget that cannot grow
            root.finishOpen();
            return;
        }
        openAnim.stop();
        retargetAnim.from = from;
        retargetAnim.to = to;
        retargetAnim.restart();
    }

    onMaskActiveChanged: if (root.dock)
        root.dock.launcherAnimating = root.maskActive

    // Freeze the idle 3D wallpaper drift while the launcher is up. It is
    // invisible behind the panel and its 30 Hz fullscreen repaint on every
    // output is the largest source of render-thread contention during the
    // reveal. SpatialShake parks its timer rather than resetting the pose.
    onPanelVisibleChanged: SpatialWall.launcherOpen = root.panelVisible

    Connections {
        target: face

        function onModeChanged() {
            if (face.mode !== "apps")
                root.bodyOpen = true;
        }
    }

    Connections {
        target: root.dock

        function onMenuOpenChanged() {
            if (!root.dock)
                return ;

            if (root.dock.menuOpen) {
                // An open that came through IPC (the tmux Super path, older
                // keybinds) never reaches toggleLauncher(), so take the queued
                // characters here instead of leaving them buffered and the
                // catcher holding focus.
                if (root.inputArmed) {
                    const queued = root.queuedInput;
                    root.inputArmed = false;
                    root.queuedInput = "";
                    if (queued !== "")
                        root.dock.setSearchText(queued);
                }
                closeHide.stop();
                // settle the body before the surface becomes visible, so a
                // reopen never shows the last session's expanded content
                // retracting under the reveal
                // A direct tab (Super+W, Super+T, emoji) needs its body even though the
        // search field is intentionally blank. The pinned mode is set before
        // menuOpen, while `face.mode` may still be settling from the old tab.
        root.bodyOpen = root.dock ? (root.dock.pinnedMode !== "apps" || (face && face.searchText !== "")) : false;
                root.panelVisible = true;
                root.startOpen();
            } else {
                openAnim.stop();
                retargetAnim.stop();
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
        // A few pixels, not zero: the first visible frame is the dot. startOpen
        // sets 2 before restart; the animation used to override it with 0.
        from: 2
        to: root.revealMax
        duration: Theme.ms(280)
        easing.type: Easing.OutCubic
        onFinished: root.finishOpen()
    }

    // A body that arrives mid-reveal (typing, a tab) grows the window. Continue
    // from the current radius to the new revealMax for a short beat instead of
    // either cutting the mask or jumping the radius to the new target.
    NumberAnimation {
        id: retargetAnim

        target: root
        property: "revealRadius"
        duration: Theme.ms(200)
        easing.type: Easing.OutCubic
        onFinished: root.finishOpen()
    }

    function finishOpen() {
        // release the whole surface once the circle covers it
        root.revealRadius = Math.max(root.width, root.height) * 2;
        root.maskActive = false;
    }

    Timer {
        id: closeHide

        interval: Theme.ms(180)
        onTriggered: root.finishClose()
    }

    NumberAnimation {
        id: closeAnim

        target: root
        property: "revealRadius"
        to: 0
        duration: Theme.ms(140)
        easing.type: Easing.OutCubic
        onFinished: root.finishClose()
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
        // The compositor glass + rim owns the edge when the transparent
        // glass body is actually drawing. Keep the QML hairline only for the
        // opaque fallback (glass not ready or mask unsupported).
        readonly property bool glassSurface: root.glassOn && (!root.maskActive || root.maskedGlass)
        fillColor: glassSurface ? "transparent" : root.panelFill
        borderColor: glassSurface ? "transparent" : root.panelBorder
        borderWidth: glassSurface ? 0 : root.activeBorderWidth
        radius: root.surfaceRadius
        smoothing: root.surfaceSmoothing
        z: -1
    }

    LucidBar.GlassLayout {
        name: "launcher"
        surfaceNamespace: "lucid-launcher"
        targetScreen: root.screen
        surfaceW: root.width
        surfaceH: root.height
        // 8 ms = one frame at 120 Hz. The reveal runs at the output's rate
        // (165 Hz here), and publishing at the default 4 ms queued more writes
        // than FileView could finish: the extra ones were canceled, and the
        // churn competed with the animation itself. One frame of glass lag is
        // invisible on a feathered circular mask.
        coalesceMs: 8
        // Shape is the live committed surface box while the launcher is open.
        // The layer surface stays mapped even when closed, so gate on the
        // actual open state, not on the always-mapped layer. `closing` is
        // included: the mask circle is still shrinking over the body, and the
        // same circle clips the glass, so dropping it here made the panel lose
        // its backdrop for the whole close animation.
        full: root.panelVisible
        pills: root.panelVisible ? [{
            x: root.maskActive ? 0 : surface.x,
            y: root.maskActive ? 0 : surface.y,
            w: root.maskActive ? root.width : surface.width,
            h: root.maskActive ? root.height : surface.height,
            // The real radius/squircle even while masked: the mask discards
            // outside the circle anyway, and sending zeros made the last
            // frames of the iris reveal a square-cornered sheet until the
            // mask was released and the next geometry write landed.
            r: [root.surfaceRadius, root.surfaceRadius,
                root.surfaceRadius, root.surfaceRadius],
            sq: root.surfaceSmoothing
        }] : []
        // Same hard circle as LauncherMask.qsb: centre (width/2, revealCenterY),
        // radius revealRadius, in surface-local logical px.
        mask: root.maskedGlass ? { x: root.width / 2, y: root.revealCenterY, r: root.revealRadius } : null
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
        hostScreen: root.screen
        windowX: root.margins.left
        windowY: root.margins.top
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
        wallpaperLocalCount: root.dock ? root.dock.pickerLocalCount : 0
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
        onActivated: (index, newInstance) => root.dock && root.dock.activateResult(index, newInstance)
        onAppActivated: (index, newInstance) => root.dock && root.dock.activateApp(index, newInstance)
        onWidgetAdded: (name) => {
            if (root.toast)
                root.toast.popup("widgets", name + " added", false);
        }
        onEmojiCopied: (emoji, image, label, animated, key) => {
            if (root.dock)
                root.dock.recordEmojiUse(key);
            Quickshell.execDetached(["wl-copy", "--", emoji]);
            if (root.toast)
                root.toast.present({
                    "image": image,
                    "animated": animated,
                    "icon": image === "" ? "copy" : "",
                    "label": (label || emoji) + " copied!"
                });
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
            root.dock.selectMode(m);
        }
        onDeleteRequested: (index) => root.dock && root.dock.deleteResult(index)
        onHideRequested: (index) => root.dock && root.dock.hideResult(index)
        onClearRequested: Clip.wipe()
        onWallpaperChosen: (path) => {
            if (!root.dock) return;
            // A local pick closes immediately. A remote result must stay up
            // while it downloads/subscribes; the dock closes it when
            // RemoteWall.downloadFinished reports success.
            const remote = path.indexOf("wh:") === 0
                || (path.indexOf("skwd:we:") === 0 && !SkwdWall.entryForPath(path));
            var picker = face.wallStrip;
            root.dock.applyWallpaper(path, picker ? Qt.point(picker.originX, picker.originY) : Qt.point(-1, -1));
            if (!remote)
                root.dock.menuOpen = false;
        }
        onWallpaperDeleteRequested: (path) => {
            if (root.dock)
                root.dock.deleteWallpaper(path);
        }
        onWallpaperUndoRequested: {
            if (root.dock)
                root.dock.undoDeleteWallpaper();
        }
        onSearchTextChanged: if (face.searchText !== "") {
            root.bodyOpen = true;
        }
    }
    }

    Component.onCompleted: if (root.dock) root.dock.externalFace = face
    Component.onDestruction: if (root.dock) root.dock.externalFace = null

    // A transparent focus holder, outside the visual reveal. It exists only
    // while SUPER is down so the compositor already has a place to send keys
    // before the face is shown; every character is queued here and handed to
    // the search field when the tap opens the launcher.
    Item {
        id: inputCatcher

        anchors.fill: parent
        visible: root.inputArmed
        enabled: root.inputArmed
        focus: root.inputArmed
        z: 1000

        Keys.onPressed: (event) => {
            if (!root.inputArmed)
                return ;
            // A chord, not typing: let its bind act. The launcher is disarmed
            // by the same key in Hyprland, which also clears this buffer.
            if ((event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) !== 0)
                return ;
            if (event.key === Qt.Key_Backspace) {
                root.queuedInput = root.queuedInput.slice(0, Math.max(0, root.queuedInput.length - 1));
                event.accepted = true;
                return ;
            }
            if (event.text !== "" && event.text.charCodeAt(0) >= 32) {
                root.queuedInput += event.text;
                event.accepted = true;
            }
        }
    }

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
    function restorePickerFocus() {
        if (!root.panelVisible || root.closing || !face)
            return ;
        root.focusKick = true;
        refocusTimer.restart();
    }

    Timer {
        id: refocusTimer

        interval: 60
        repeat: false
        onTriggered: {
            root.focusKick = false;
            if (face)
                face.focusSearch();
        }
    }

    Connections {
        target: Theme

        function onRevealActiveChanged() {
            if (!Theme.revealActive)
                root.restorePickerFocus();
        }
    }

    function startOpen() {
        root.closing = false;
        // A pending focus kick from a previous wallpaper/iris session must not
        // leave the freshly opened panel without keyboard focus.
        root.focusKick = false;
        refocusTimer.stop();
        // An interrupted close may not have reached finishClose yet. Start from
        // the collapsed head, then re-derive the body from the requested tab so
        // the previous session's expanded body cannot be inherited.
        root.bodyOpen = false;
        // Direct tab selection leaves the field empty; every non-Apps tab
        // still needs its body. pinnedMode is set before menuOpen, while
        // face.mode may still be settling from the old tab.
        root.bodyOpen = root.dock ? (root.dock.pinnedMode !== "apps" || (face && face.searchText !== "")) : false;
        // The surface is already mapped, so the circular gate can start in the
        // same frame without paying the old window-creation cost. Start at a
        // few pixels rather than zero so the first visible frame is the dot.
        root.maskActive = true;
        root.revealRadius = 2;
        closeHide.stop();
        closeAnim.stop();
        retargetAnim.stop();
        openAnim.restart();
        if (face)
            face.focusSearch();
    }
    function finishClose() {
        // closeHide can land after closeAnim already finished (or after a new
        // open cancelled the close): only the first pass owns the reset.
        if (!root.closing)
            return;
        root.closing = false;
        // The reveal radius is at zero here. Reset the tab and the body while
        // the canvas is still considered visible, so QML re-lays the face out
        // now; hiding it first can leave the old expanded layout to be polished
        // on the next open, which reads as the body animating back in.
        root.bodyOpen = false;
        // Put the dock's mode, query and selection back to the first frame only
        // after the surface is no longer drawn. The window stays mapped while
        // closed, so resetting here lets Hyprland settle the surface's new
        // width and margins before the next reveal instead of moving the panel
        // sideways while it opens.
        if (root.dock)
            root.dock.resetLauncherState();
        // Resetting the tab must not leave the body open behind it: the next
        // open is the collapsed head unless it explicitly asks for a tab.
        root.bodyOpen = false;
        root.maskActive = false;
        root.panelVisible = false;
    }
    function closeLauncher() {
        if (root.dock)
            root.dock.menuOpen = false;
    }
    // Called the moment SUPER goes down, not when the tap is recognised. The
    // keyboard is taken immediately; anything typed before the panel is ready
    // stays in queuedInput and is replayed by toggleLauncher().
    function armLauncher() {
        if (!root.dock || root.dock.menuOpen || root.inputArmed)
            return ;
        root.queuedInput = "";
        root.inputArmed = true;
        inputCatcher.forceActiveFocus();
    }
    // A SUPER chord won: give the keyboard straight back and drop whatever was
    // buffered, because no launcher will open from this press.
    function disarmLauncher() {
        if (!root.inputArmed)
            return ;
        root.inputArmed = false;
        root.queuedInput = "";
    }
    function toggleLauncher() {
        const d = root.dock;
        if (!d)
            return ;
        const queued = root.inputArmed ? root.queuedInput : "";
        root.inputArmed = false;
        if (!d.menuOpen) {
            d.pinnedMode = "apps";
            d.setSearchText(queued);
        }
        d.aimLauncher();
        d.menuOpen = !d.menuOpen;
        root.queuedInput = "";
    }

    // Direct-tab entry from a compositor global. No `qs ipc call` process, so
    // the chord cannot race the Super release or leave the tap armed.
    function openEmoji() {
        const d = root.dock;
        if (!d)
            return ;
        root.inputArmed = false;
        root.queuedInput = "";
        d.selectMode("emoji");
        d.aimLauncher();
        d.menuOpen = true;
    }

    // If a release or a disarm is ever lost, never leave the launcher holding
    // exclusive keyboard focus invisibly.
    Timer {
        interval: 6000
        running: root.inputArmed
        onTriggered: root.disarmLauncher()
    }

    // Hyprland calls this directly as `global, quickshell:launcher`; it avoids
    // spawning `qs ipc call` (a ~450 ms process start) on the Super keybind.
    GlobalShortcut {
        name: "launcher"
        description: Tr.t("Toggle the Lucid application launcher")
        onPressed: root.toggleLauncher()
    }

    GlobalShortcut {
        name: "launcherEmoji"
        description: Tr.t("Open the Lucid launcher on the Emoji tab")
        onPressed: root.openEmoji()
    }

    // SUPER press/release arrive separately: arm on the press while the tap is
    // still ambiguous, disarm if the press turns out to be a chord.
    GlobalShortcut {
        name: "launcherArm"
        description: Tr.t("Lucid: hold the keyboard for a pending launcher tap")
        onPressed: root.armLauncher()
    }

    GlobalShortcut {
        name: "launcherDisarm"
        description: Tr.t("Lucid: release the keyboard after a launcher chord")
        onPressed: root.disarmLauncher()
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
