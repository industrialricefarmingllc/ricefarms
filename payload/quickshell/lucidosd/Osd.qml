import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Wayland
import qs
import qs.lucidui
import "../lucidbar" as LucidBar
import "../squircle"

PanelWindow {
    id: osdWindow

    property bool ready: false
    property bool cardVisible: false
    property string oscType: ""
    property real levelValue: 0
    property bool levelMuted: false
    property bool toggleState: false
    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    readonly property int volumePercent: (sink && sink.audio) ? Math.round(sink.audio.volume * 100) : 0
    readonly property bool volMuted: (sink && sink.audio) ? sink.audio.muted : false
    readonly property bool micMuted: (source && source.audio) ? source.audio.muted : false
    property string backlightDevice: ""
    property int maxBrightness: 0
    readonly property int brightnessPercent: osdWindow.maxBrightness > 0 ? Math.round((parseInt(brightnessFile.text()) / osdWindow.maxBrightness) * 100) : 0
    property bool capsLock: false
    property bool numLock: false
    // keyboard layout: hyprland names each one in full ("Russian (Phonetic)"),
    // and the first in the list is the state the card flips away from
    property string kbLayout: ""
    property string kbLayoutBase: ""
    property bool kbLayoutAlt: false
    property bool kbInitialized: false
    property int pendingBrightness: -1

    // m3 shape, spacing and slider metrics, shared with lucidbar/System.qml
    readonly property int cardPadX: Theme.dp(12)
    readonly property int badgeSize: Theme.dp(36)
    readonly property int cardGap: Theme.dp(10)
    readonly property int glyphSize: Theme.dp(18)
    // the level card's own, tighter slider metrics
    readonly property int levelTrackH: Theme.dp(30)
    readonly property int levelHandleH: Theme.dp(38)

    readonly property string levelIcon: {
        if (osdWindow.oscType === "brightness")
            return osdWindow.levelValue < 34 ? "brightness_low" : (osdWindow.levelValue < 67 ? "brightness_medium" : "brightness_high");

        if (osdWindow.levelMuted || osdWindow.levelValue <= 0)
            return "volume_off";

        return osdWindow.levelValue < 34 ? "volume_mute" : (osdWindow.levelValue < 67 ? "volume_down" : "volume_up");
    }
    readonly property bool isLevelType: osdWindow.oscType === "volume" || osdWindow.oscType === "brightness"
    readonly property bool badgeActive: osdWindow.toggleState
    readonly property string toggleIcon: {
        switch (osdWindow.oscType) {
        case "mic":
            return osdWindow.toggleState ? "mic" : "mic_off";
        case "capslock":
            return "keyboard_capslock";
        case "numlock":
            return "dialpad";
        case "kblayout":
            return "keyboard";
        default:
            return "";
        }
    }
    readonly property string currentLabel: {
        switch (osdWindow.oscType) {
        case "volume":
            return "Volume";
        case "brightness":
            return "Brightness";
        case "mic":
            return "Microphone";
        case "capslock":
            return "Caps Lock";
        case "numlock":
            return "Num Lock";
        case "kblayout":
            return "Keyboard";
        default:
            return "";
        }
    }
    // the lock keys show the letters the next keystroke makes rather than a word
    readonly property string toggleOnText: {
        switch (osdWindow.oscType) {
        case "mic":
            return "Unmuted";
        case "capslock":
            return "ABC";
        case "numlock":
            return "123";
        case "kblayout":
            return osdWindow.kbLayout !== "" ? osdWindow.kbLayout : osdWindow.kbLayoutBase;
        default:
            return "";
        }
    }
    readonly property string toggleOffText: {
        switch (osdWindow.oscType) {
        case "mic":
            return "Muted";
        case "capslock":
            return "abc";
        case "numlock":
            return "Arrows";
        case "kblayout":
            return osdWindow.kbLayoutBase !== "" ? osdWindow.kbLayoutBase : osdWindow.kbLayout;
        default:
            return "";
        }
    }
    readonly property color toggleOffColor: osdWindow.oscType === "mic" ? Theme.error : Theme.subtextDim

    // the params have to be set before the flag flips: a Behavior reads the
    // previous value of anything its animation binds to
    function setCardVisible(v) {
        cardFade.duration = v ? Theme.durEnter : Theme.durExit;
        cardFade.easing.bezierCurve = v ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel;
        cardRise.duration = v ? Theme.durEnter : Theme.durExit;
        cardRise.easing.bezierCurve = v ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel;
        cardPop.duration = v ? Theme.durEnter : Theme.durExit;
        if (v) {
            cardPop.easing.type = Easing.OutBack;
            cardPop.easing.overshoot = Theme.emphasizedOvershoot;
        } else {
            cardPop.easing.bezierCurve = Theme.easeEmphasizedAccel;
            cardPop.easing.type = Easing.Bezier;
        }
        osdWindow.cardVisible = v;
    }

    // the OSD's own display: the primary DP-1, the one the bar and dock sit on,
    // so a notification never comes up on a secondary. Settings > Displays
    // still sends it elsewhere for the whole shell (Monitors.shellPlacement,
    // bound in shell.qml), so this only decides where it rests by default.
    readonly property var primaryScreen: {
        for (var i = 0; i < Quickshell.screens.length; i++) {
            var s = Quickshell.screens[i];
            var m = Hyprland.monitorFor(s);
            if (m && m.name === "DP-1")
                return s;
        }
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }
    // dropped once a display is picked: a surface sent to a dead display is
    // never drawn
    readonly property var placement: Prefs.monitorShellScreen === "" ? osdWindow.primaryScreen : null

    function trigger() {
        osdWindow.setCardVisible(true);
        hideTimer.restart();
        if (osdWindow.isLevelType) {
            if (!levelTrack.dragging)
                levelPulseAnim.restart();

        } else if (osdWindow.oscType === "mic") {
            pulseAnim.restart();
        } else {
            nudgeAnim.restart();
        }
    }

    function setBrightness(percent) {
        osdWindow.pendingBrightness = Math.max(0, Math.min(100, Math.round(percent)));
        brightnessDebounce.restart();
    }

    function applyLevel(v) {
        hideTimer.restart();
        osdWindow.levelValue = v;
        if (osdWindow.oscType === "brightness") {
            osdWindow.setBrightness(v);
            return ;
        }
        if (!osdWindow.sink || !osdWindow.sink.audio)
            return ;

        if (osdWindow.sink.audio.muted)
            osdWindow.sink.audio.muted = false;

        osdWindow.levelMuted = false;
        osdWindow.sink.audio.volume = Math.max(0, Math.min(1, v / 100));
    }

    function showVolume() {
        osdWindow.oscType = "volume";
        osdWindow.levelValue = osdWindow.volumePercent;
        osdWindow.levelMuted = osdWindow.volMuted;
        osdWindow.trigger();
    }

    function showBrightness() {
        osdWindow.oscType = "brightness";
        osdWindow.levelValue = osdWindow.brightnessPercent;
        osdWindow.levelMuted = false;
        osdWindow.trigger();
    }

    function showMic() {
        osdWindow.oscType = "mic";
        osdWindow.toggleState = !osdWindow.micMuted;
        osdWindow.trigger();
    }

    function showCaps(state) {
        osdWindow.oscType = "capslock";
        osdWindow.toggleState = state;
        osdWindow.trigger();
    }

    function showNum(state) {
        osdWindow.oscType = "numlock";
        osdWindow.toggleState = state;
        osdWindow.trigger();
    }

    function showLayout() {
        // upstream answers a layout switch with its own toast (Prefs → Toasts
        // → Keyboard layout), which carries the same name and glyph at the top
        // of the screen. The card is what answers when that toast is off, so a
        // switch never gets two answers; with it on this is simply never called.
        if (Prefs.toastOnLayout)
            return ;

        osdWindow.oscType = "kblayout";
        osdWindow.toggleState = osdWindow.kbLayoutAlt;
        osdWindow.trigger();
    }

    color: "transparent"
    exclusiveZone: 0
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // remapped with the rest of the shell when displays change
    visible: Monitors.surfacesUp
    // shadow headroom. the card's QML shadow reaches roughly hyprShadowBlurMax
    // * hyprShadowBlur (~44px) plus its 10px downward offset, and the layer
    // surface crops whatever leaves it. pad the surface symmetrically and pull
    // margins.bottom up by the same amount, so the card keeps its place.
    readonly property int shadowPad: 16
    implicitWidth: Theme.dp(480) + 2 * osdWindow.shadowPad
    implicitHeight: Theme.dp(140) + 2 * osdWindow.shadowPad
    margins.bottom: Theme.dp(96) - osdWindow.shadowPad
    Component.onCompleted: {
        findDeviceProc.running = true;
        // the layout card needs the state before its first switch; with the
        // toast answering switches instead, it is never read at all
        if (!Prefs.toastOnLayout)
            layoutProc.running = true;

    }
    onBacklightDeviceChanged: {
        if (backlightDevice !== "")
            readMaxProc.running = true;

    }
    // muting is its own answer; the tick is heard at the level just set
    onVolumePercentChanged: {
        if (!osdWindow.ready)
            return ;

        osdWindow.showVolume();
        if (!osdWindow.volMuted)
            osdWindow.levelTick("volume");

    }
    onVolMutedChanged: {
        if (!osdWindow.ready)
            return ;

        osdWindow.showVolume();
        if (!osdWindow.volMuted)
            osdWindow.levelTick("volume");

    }
    // idle dimming and the ambient-light script move the backlight on their
    // own: neither is a keypress, so neither gets a card or a tick. The delay
    // also folds a burst of steps into the one card at the end of it.
    onBrightnessPercentChanged: {
        if (!osdWindow.ready)
            return ;

        brightnessOsdDelay.restart();
    }
    onMicMutedChanged: {
        if (!osdWindow.ready)
            return ;

        osdWindow.showMic();
        Sounds.feedback(osdWindow.micMuted ? "mic-off" : "mic-on", Prefs.soundOnMic);
    }
    // shrunk rather than dropped: hyprland keeps a dropped region on screen.
    // compositor blur yields to the plugin glass too: a circular blur region
    // under a squircle card leaves an unblurred lune at every corner
    BackgroundEffect.blurRegion: (Theme.blurAmount > 0 && !Prefs.liquidGlassEnabled) ? osdBlurRegion : null

    anchors {
        bottom: true
    }

    PwObjectTracker {
        objects: [osdWindow.sink, osdWindow.source]
    }

    Timer {
        interval: 800
        running: true
        onTriggered: osdWindow.ready = true
    }

    // a level ticks at its first change, then once more where a drag or a held
    // key comes to rest, rather than at every step on the way
    property string tickPending: ""
    property real activeSince: 0

    function levelTick(key) {
        if (tickSettle.running)
            osdWindow.tickPending = key;
        else
            osdWindow.tick(key);
        tickSettle.restart();
    }

    function tick(key) {
        Sounds.feedback(key, key === "volume" ? Prefs.soundOnVolume : Prefs.soundOnBrightness);
    }

    Timer {
        id: tickSettle

        interval: 220
        onTriggered: {
            if (osdWindow.tickPending !== "")
                osdWindow.tick(osdWindow.tickPending);

            osdWindow.tickPending = "";
        }
    }

    // idle a little short of the dim, so the dim and its undo both find it idle
    IdleMonitor {
        id: idleWatch

        timeout: Prefs.idleEnabled && Prefs.idleDim ? Math.max(5, Prefs.idleDimAfter - 3) : 60
        respectInhibitors: false
        onIsIdleChanged: {
            if (!idleWatch.isIdle)
                osdWindow.activeSince = Date.now();

        }
    }

    Timer {
        id: hideTimer

        interval: 1600
        onTriggered: {
            if (levelTrack.dragging || levelTrack.hovered) {
                hideTimer.restart();
                return ;
            }
            osdWindow.setCardVisible(false);
        }
    }

    // the ambient-light script stamps when it last drove the backlight, so a
    // step that came from it is not answered with a card of its own
    function autoBrightnessAdjustedRecently() {
        const ts = parseInt(autoBrightnessFlag.text().trim());
        return !isNaN(ts) && (Date.now() / 1000 - ts) < 2.5;
    }

    Timer {
        id: brightnessOsdDelay

        interval: 150
        onTriggered: {
            if (osdWindow.autoBrightnessAdjustedRecently())
                return ;

            osdWindow.showBrightness();
            // idle dimming moves the backlight too: nothing ticks while you are
            // away, or as it comes back up when you return
            if (!idleWatch.isIdle && Date.now() - osdWindow.activeSince > 1500)
                osdWindow.levelTick("brightness");

        }
    }

    Process {
        id: findDeviceProc

        command: ["bash", "-c", "ls /sys/class/backlight | head -1"]

        stdout: StdioCollector {
            onStreamFinished: osdWindow.backlightDevice = this.text.trim().replace(/[@/*=|]$/, "")
        }

    }

    Timer {
        id: brightnessDebounce

        interval: 60
        onTriggered: {
            if (osdWindow.pendingBrightness >= 0)
                setBrightnessProc.running = true;

        }
    }

    Process {
        id: setBrightnessProc

        command: osdWindow.pendingBrightness >= 0 ? ["brightnessctl", "set", osdWindow.pendingBrightness + "%"] : []
    }

    Process {
        id: readMaxProc

        command: osdWindow.backlightDevice ? ["cat", "/sys/class/backlight/" + osdWindow.backlightDevice + "/max_brightness"] : []

        stdout: StdioCollector {
            onStreamFinished: osdWindow.maxBrightness = parseInt(this.text.trim())
        }

    }

    FileView {
        id: brightnessFile

        path: osdWindow.backlightDevice ? "/sys/class/backlight/" + osdWindow.backlightDevice + "/brightness" : ""
        watchChanges: true
        onFileChanged: reload()
    }

    FileView {
        id: autoBrightnessFlag

        path: Quickshell.env("HOME") + "/.cache/lucid/auto-brightness-last-write"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }

    // lock keys have no hyprland event, but the kernel's keyboard leds carry the
    // same state and reading them never touches hyprland. polling its request
    // socket instead deadlocked it against a resizing window for 5 s at a time
    function readLocks() {
        var caps = false;
        var num = false;
        var files = ledFiles.instances;
        for (var i = 0; i < files.length; i++) {
            files[i].reload();
            var on = parseInt(files[i].text()) > 0;
            if (files[i].isCaps)
                caps = caps || on;
            else
                num = num || on;
        }
        // the state is followed either way, so switching a card back on never
        // shows a change from while it was off
        if (osdWindow.kbInitialized && osdWindow.ready) {
            if (caps !== osdWindow.capsLock) {
                osdWindow.capsLock = caps;
                if (Prefs.osdCapsLock)
                    osdWindow.showCaps(caps);

                Sounds.feedback(caps ? "caps-on" : "caps-off", Prefs.soundOnCaps);
            }
            if (num !== osdWindow.numLock) {
                osdWindow.numLock = num;
                if (Prefs.osdNumLock)
                    osdWindow.showNum(num);

            }
        } else {
            osdWindow.capsLock = caps;
            osdWindow.numLock = num;
        }
        osdWindow.kbInitialized = true;
    }

    // every keyboard that has the leds, so a lock on any of them counts
    Process {
        id: ledScan

        running: true
        command: ["sh", "-c", "ls -d /sys/class/leds/*::capslock /sys/class/leds/*::numlock 2>/dev/null"]

        stdout: StdioCollector {
            onStreamFinished: ledFiles.model = this.text.split("\n").filter((p) => {
                return p !== "";
            })
        }

    }

    Variants {
        id: ledFiles

        model: []

        FileView {
            required property string modelData
            readonly property bool isCaps: modelData.endsWith("::capslock")

            path: modelData + "/brightness"
            blockLoading: true
            printErrors: false
        }

    }

    Timer {
        interval: 400
        running: osdWindow.ready && ledFiles.instances.length > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: osdWindow.readLocks()
    }

    // keyboard layout: hyprland has no state to watch, only an event carrying
    // the long name, so the main keyboard is read once a switch settles. The
    // same keyboard the bar's indicator shows: a switch reports every keyboard,
    // the virtual ones too, and they need not agree
    Timer {
        id: layoutSettle

        interval: 150
        onTriggered: {
            // the toast is answering layout switches: nothing to read
            if (Prefs.toastOnLayout)
                return ;

            if (layoutProc.running)
                layoutSettle.restart();
            else
                layoutProc.running = true;
        }
    }

    Process {
        id: layoutProc

        command: ["hyprctl", "devices", "-j"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const kbs = JSON.parse(this.text).keyboards || [];
                    const kb = kbs.find((k) => {
                        return k.main;
                    }) || kbs[0];
                    if (!kb)
                        return ;

                    const codes = String(kb.layout || "").split(",");
                    const variants = String(kb.variant || "").split(",");
                    const code = (codes[0] || "").trim();
                    // the first layout is what the card rolls away from
                    const base = Xkb.loaded ? Xkb.nameOf(code, (variants[0] || "").trim()) : code.toUpperCase();
                    const idx = kb.active_layout_index || 0;
                    const name = kb.active_keymap || (codes[idx] || code || "").trim();
                    const alt = idx > 0;
                    if (osdWindow.kbInitialized && osdWindow.ready) {
                        if (alt !== osdWindow.kbLayoutAlt || name !== osdWindow.kbLayout) {
                            osdWindow.kbLayout = name;
                            osdWindow.kbLayoutBase = base;
                            osdWindow.kbLayoutAlt = alt;
                            osdWindow.showLayout();
                        }
                    } else {
                        osdWindow.kbLayout = name;
                        osdWindow.kbLayoutBase = base;
                        osdWindow.kbLayoutAlt = alt;
                    }
                } catch (e) {
                }
            }
        }

    }

    Connections {
        function onRawEvent(event) {
            if (event.name === "activelayout")
                layoutSettle.restart();

        }

        target: Hyprland
    }

    Region {
        id: osdBlurRegion

        readonly property real paintedX: card.x + card.width * (1 - card.scale) / 2
        readonly property real paintedY: card.y + card.height * (1 - card.scale) / 2
        readonly property real paintedWidth: card.width * card.scale
        readonly property real paintedHeight: card.height * card.scale

        x: Math.ceil(osdBlurRegion.paintedX - 0.002)
        y: Math.ceil(osdBlurRegion.paintedY - 0.002)
        width: card.visible ? Math.max(0, Math.floor(osdBlurRegion.paintedX + osdBlurRegion.paintedWidth + 0.002) - Math.ceil(osdBlurRegion.paintedX - 0.002)) : 0
        height: card.visible ? Math.max(0, Math.floor(osdBlurRegion.paintedY + osdBlurRegion.paintedHeight + 0.002) - Math.ceil(osdBlurRegion.paintedY - 0.002)) : 0
        radius: Math.round(card.radius * card.scale)
    }

    // Liquid glass background (see liquid-glass-hypr): publishes the card's
    // rect and lets the compositor plugin draw glass behind it. Falls back to
    // the solid card + QML shadow when glass is off.
    LucidBar.GlassLayout {
        name: "osd"
        surfaceNamespace: "quickshell"
        targetScreen: osdWindow.screen
        surfaceW: osdWindow.width
        surfaceH: osdWindow.height
        pills: (Prefs.liquidGlassEnabled && card.visible) ? [{
            x: osdBlurRegion.paintedX,
            y: osdBlurRegion.paintedY,
            w: osdBlurRegion.paintedWidth,
            h: osdBlurRegion.paintedHeight,
            r: [card.radius * card.scale, card.radius * card.scale, card.radius * card.scale, card.radius * card.scale],
            // matches the card below: a true stadium pill, not a squircle
            sq: 0
        }] : []
    }

    SquircleRect {
        id: card

        readonly property int levelWidth: Theme.dp(260)
        readonly property int toggleWidth: osdWindow.cardPadX * 2 + osdWindow.badgeSize + osdWindow.cardGap + Math.ceil(Math.max(labelMetrics.advanceWidth, stateFlip.width)) + Theme.dp(6)

        anchors.centerIn: parent
        anchors.verticalCenterOffset: osdWindow.cardVisible ? 0 : Theme.dp(16)
        height: osdWindow.isLevelType ? Theme.dp(50) : Theme.dp(56)
        width: osdWindow.isLevelType ? card.levelWidth : card.toggleWidth
        radius: height / 2
        fillColor: Prefs.liquidGlassEnabled ? "transparent" : Theme.bg
        // deliberately circular, not squircle: radius == height / 2 must draw a
        // true stadium pill. smoothing would flatten the ends into a blob.
        smoothing: 0

        LucidBar.WallpaperBlur {
            anchors.fill: parent
            visible: !Prefs.liquidGlassEnabled
            hostWindow: osdWindow
            offsetX: ((osdWindow.screen ? osdWindow.screen.width : 1368) - osdWindow.width) / 2 + card.x
            offsetY: (osdWindow.screen ? osdWindow.screen.height : 912) - osdWindow.height - osdWindow.margins.bottom + card.y
        }

        opacity: osdWindow.cardVisible ? 1 : 0
        scale: osdWindow.cardVisible ? 1 : 0.9
        visible: opacity > 0.15
        // the offscreen layer and its shadow only exist for the solid card:
        // around glyphs on a glass card they blob. single source of truth.
        layer.enabled: !Prefs.liquidGlassEnabled
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowBlur: Theme.hyprShadowBlur
            blurMax: Theme.hyprShadowBlurMax
            shadowColor: Theme.cardShadow
            shadowHorizontalOffset: Theme.hyprShadowOffsetX
            shadowVerticalOffset: Theme.hyprShadowOffsetY
            shadowScale: Theme.hyprShadowScale
            autoPaddingEnabled: true
        }

        TextMetrics {
            id: labelMetrics

            text: osdWindow.currentLabel
            font.family: Theme.fontFamily
            font.pixelSize: Theme.typeSize("labelSmall")
            font.variableAxes: Theme.axes(Theme.typeSize("labelSmall"), 560, 0)
        }

        Slider {
            id: levelTrack

            visible: osdWindow.isLevelType
            anchors.left: parent.left
            anchors.leftMargin: Theme.dp(10)
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(10)
            anchors.verticalCenter: parent.verticalCenter
            size: "m"
            trackH: osdWindow.levelTrackH
            handleH: osdWindow.levelHandleH
            // a full stadium cap, as round as the card behind it
            outerR: osdWindow.levelTrackH / 2
            iconSize: Theme.dp(18)
            from: 0
            to: 100
            value: osdWindow.levelMuted ? 0 : osdWindow.levelValue
            icon: osdWindow.levelIcon
            showValue: false
            inlineValue: true
            valueText: (v) => {
                return osdWindow.levelMuted ? "Off" : Math.round(v) + "%";
            }
            activeColor: osdWindow.levelMuted ? Theme.outlineStrong : Theme.primary
            inactiveColor: Theme.withBlur(Theme.surfaceHighest)
            easeValue: card.visible
            onMoved: (v) => {
                return osdWindow.applyLevel(v);
            }
            onReleased: hideTimer.restart()
            onHoveredChanged: {
                if (!levelTrack.hovered)
                    hideTimer.restart();

            }

        }

        Item {
            id: iconBadge

            visible: !osdWindow.isLevelType
            anchors.left: parent.left
            anchors.leftMargin: osdWindow.cardPadX
            anchors.verticalCenter: parent.verticalCenter
            width: osdWindow.badgeSize
            height: osdWindow.badgeSize

            readonly property color fillColor: osdWindow.badgeActive ? Theme.accent : Theme.withBlur(Theme.surfaceHighest)

            MaterialShape {
                id: badgeShape

                anchors.fill: parent
                shape: "cookie9"
                color: iconBadge.fillColor
                rotation: osdWindow.badgeActive ? 20 : 0

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.durShort
                    }

                }

                Behavior on rotation {
                    NumberAnimation {
                        duration: Theme.durSlowSpatial
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveDefaultSpatial
                    }

                }

            }

            Icon {
                id: toggleGlyph

                anchors.centerIn: parent
                name: osdWindow.toggleIcon
                size: osdWindow.glyphSize + Theme.dp(2)
                fill: osdWindow.badgeActive ? 1 : 0
                color: osdWindow.badgeActive ? Theme.fgAccent : Theme.text
            }

        }

        Column {
            visible: !osdWindow.isLevelType
            anchors.left: iconBadge.right
            anchors.leftMargin: osdWindow.cardGap
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(2)

            LText {
                role: "labelSmall"
                color: Theme.subtext
                text: osdWindow.currentLabel
            }

            // off sits above on, so flipping rolls the column up one line
            Item {
                id: stateFlip

                readonly property int lineHeight: Math.ceil(offMetrics.height)

                width: Math.ceil(Math.max(onMetrics.advanceWidth, offMetrics.advanceWidth))
                height: stateFlip.lineHeight
                clip: true

                TextMetrics {
                    id: onMetrics

                    text: osdWindow.toggleOnText
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.typeSize("titleMedium")
                    font.variableAxes: Theme.axes(Theme.typeSize("titleMedium"), 640, 60)
                }

                TextMetrics {
                    id: offMetrics

                    text: osdWindow.toggleOffText
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.typeSize("titleMedium")
                    font.variableAxes: Theme.axes(Theme.typeSize("titleMedium"), 640, 60)
                }

                Column {
                    width: parent.width
                    y: osdWindow.toggleState ? -stateFlip.lineHeight : 0

                    LText {
                        width: parent.width
                        height: stateFlip.lineHeight
                        role: "titleMedium"
                        weight: 640
                        rounded: 60
                        text: osdWindow.toggleOffText
                        color: osdWindow.toggleOffColor
                    }

                    LText {
                        width: parent.width
                        height: stateFlip.lineHeight
                        role: "titleMedium"
                        weight: 640
                        rounded: 60
                        text: osdWindow.toggleOnText
                        color: Theme.accent
                    }

                    Behavior on y {
                        enabled: card.visible

                        NumberAnimation {
                            duration: Theme.durMedium
                            easing.type: Easing.Bezier
                            easing.bezierCurve: Theme.easeEmphasizedDecel
                        }

                    }

                }

            }

        }

        NumberAnimation {
            id: nudgeAnim

            target: toggleGlyph
            property: "anchors.verticalCenterOffset"
            from: osdWindow.toggleState ? 6 : -6
            to: 0
            duration: Theme.durLong
            easing.type: Easing.OutBack
            easing.overshoot: 2.4
        }

        SequentialAnimation {
            id: pulseAnim

            NumberAnimation {
                target: iconBadge
                property: "scale"
                to: 1.12
                duration: Theme.durQuick
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.easeEmphasizedDecel
            }

            NumberAnimation {
                target: iconBadge
                property: "scale"
                to: 1
                duration: Theme.durShort
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.easeEmphasizedDecel
            }

        }

        // the reading answers the keypress
        SequentialAnimation {
            id: levelPulseAnim

            NumberAnimation {
                target: levelTrack.valueItem
                property: "scale"
                to: 1.12
                duration: Theme.durQuick
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.easeEmphasizedDecel
            }

            NumberAnimation {
                target: levelTrack.valueItem
                property: "scale"
                to: 1
                duration: Theme.durMedium
                easing.type: Easing.OutBack
                easing.overshoot: Theme.emphasizedOvershoot
            }

        }

        Behavior on width {
            enabled: card.visible

            NumberAnimation {
                duration: Theme.durMedium
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.easeEmphasizedDecel
            }

        }

        Behavior on height {
            enabled: card.visible

            NumberAnimation {
                duration: Theme.durMedium
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.easeEmphasizedDecel
            }

        }

        Behavior on opacity {
            NumberAnimation {
                id: cardFade

                duration: Theme.durEnter
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.easeEmphasizedDecel
            }

        }

        Behavior on scale {
            NumberAnimation {
                id: cardPop

                duration: Theme.durEnter
                easing.type: Easing.OutBack
                easing.overshoot: Theme.emphasizedOvershoot
            }

        }

        Behavior on anchors.verticalCenterOffset {
            NumberAnimation {
                id: cardRise

                duration: Theme.durEnter
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.easeEmphasizedDecel
            }

        }

    }

    mask: Region {
        // only the level card takes the pointer; the toggle toasts stay click-through
        readonly property bool grabs: card.visible && osdWindow.isLevelType

        x: grabs ? Math.round(osdBlurRegion.paintedX) : 0
        y: grabs ? Math.round(osdBlurRegion.paintedY) : 0
        width: grabs ? Math.round(osdBlurRegion.paintedWidth) : 0
        height: grabs ? Math.round(osdBlurRegion.paintedHeight) : 0
        radius: Math.round(card.radius * card.scale)
    }

}
