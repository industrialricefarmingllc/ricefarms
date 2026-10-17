import "./lucidbar"
import "./lucidcorners"
import "./luciddocks"
import "./lucidlock"
import "./lucidmoji"
import "./lucidosd"
import "./lucidprefs"
import "./lucidshot"
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    Component.onCompleted: {
    }



    PanelWindow {
        id: bar
        objectName: "bar"
        // Primary only - center 1440p DP-1 at 1600,0 never secondaries
        screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
        readonly property real screenOffsetY: Prefs.effectiveBarTopMargin
        readonly property real liveGlassOffsetY: 57 * (bar.screen ? bar.screen.devicePixelRatio : 1.6)

        visible: Prefs.loaded && Prefs.barEnabled && !bar.fullScreenOpen

        property bool laidOut: false
        readonly property bool anyModuleShown: bar.leftGroupWidth + clockMod.width + bar.rightGroupWidth > 0.5
        // Hyprland composites Top-layer surfaces above fullscreen windows,
        // so hide the bar while any toplevel on this screen is fullscreen.
        // Otherwise the pills/glass keep drawing over fullscreen content.
        // NOTE: in Hyprland lua mode Hyprland.toplevels holds HyprlandToplevel
        // items (no .fullscreen/.screens); the reactive Wayland handle is
        // .wayland, and the screen match goes via .monitor.id. Maximized
        // windows report wayland.fullscreen === false, so they keep the bar.
        readonly property bool fullScreenOpen: {
            var mon = bar.screen ? Hyprland.monitorFor(bar.screen) : null;
            if (!bar.screen || !mon)
                return false;
            var tls = Hyprland.toplevels ? Hyprland.toplevels.values : [];
            for (var i = 0; i < tls.length; i++) {
                var t = tls[i];
                if (!t || !t.wayland || t.wayland.fullscreen !== true)
                    continue;
                if (t.monitor && t.monitor.id === mon.id)
                    return true;
            }
            return false;
        }
        // Pill rects for the liquid-glass-hypr plugin, mirroring each
        // module's own background geometry (BarPill surface rects, including
        // the popupMode second pill when a panel is open).
        // Geometry is quantized to 0.5px: sub-half-pixel float noise from
        // per-frame width/x interpolation otherwise changes the JSON
        // signature (and triggers a file write + plugin re-render) for
        // zero visible difference at 1.6-2.4x scale.
        function glassQ(v) {
            return Math.round(v * 2) / 2;
        }
        function glassPillFor(m) {
            if (!m || m.visible === false || m.width <= 0.5)
                return null;
            var isBarPill = m.surfaceX !== undefined;
            var bx = bar.glassQ(isBarPill ? m.x + m.surfaceX : m.x);
            var by = bar.glassQ(isBarPill ? m.y + m.surfaceY : m.y);
            var bw = bar.glassQ(isBarPill ? m.surfaceWidth : m.width);
            var bh = bar.glassQ(isBarPill ? m.surfaceHeight : m.height);
            var top = m.topRadius !== undefined ? m.topRadius : Prefs.barPillRadius;
            var cor = m.cornerRadius !== undefined ? m.cornerRadius : (Prefs.barNotch ? Prefs.barNotchRadius : Prefs.barPillRadius);
            var out = [];
            if (m.popupMode === true) {
                var pillTop = m.pillTopRadius !== undefined ? m.pillTopRadius : top;
                out.push({
                    x: bx,
                    y: by,
                    w: bw,
                    h: bh,
                    r: [pillTop, pillTop, Prefs.barNotch ? Prefs.barNotchRadius : Prefs.barPillRadius, Prefs.barNotch ? Prefs.barNotchRadius : Prefs.barPillRadius]
                });
                if (m.anyOpen === true)
                    out.push({
                        x: bar.glassQ(m.x + m.popupX),
                        y: bar.glassQ(m.y + m.compactHeight + Prefs.barPopupGap),
                        w: bar.glassQ(m.popupWidth),
                        h: bar.glassQ(m.popupHeight),
                        r: [top, top, cor, cor]
                    });
            } else {
                out.push({
                    x: bx,
                    y: by,
                    w: bw,
                    h: bh,
                    r: [top, top, cor, cor]
                });
            }
            return out;
        }
        readonly property var leftMods: [workspacesMod, mprisMod, sysTrayMod]
        readonly property var rightMods: [notifMod, systemMod]
        function sameNotchGroup(a, b) {
            if (!Prefs.barNotch)
                return false;
            var la = bar.leftMods.indexOf(a) >= 0;
            var lb = bar.leftMods.indexOf(b) >= 0;
            if (la && lb)
                return true;
            var ra = bar.rightMods.indexOf(a) >= 0;
            var rb = bar.rightMods.indexOf(b) >= 0;
            return ra && rb;
        }
        // Notch flare size for one module edge (bar scope twin of the
        // BarFlare delegate math, so glass wedges match the QML flares they
        // replace under external glass).
        function notchFlare(m, toTheLeft) {
            if (!m || m.visible === false || m.width <= 0.5)
                return 0;
            var edge = toTheLeft ? m.x : m.x + m.width;
            var toEdge = toTheLeft ? edge : bar.width - edge;
            var toNeighbour = 100000;
            var mods = bar.modules;
            for (var i = 0; i < mods.length; i++) {
                var o = mods[i];
                if (!o || o === m || o.width <= 0.5 || !o.visible)
                    continue;
                if (bar.sameNotchGroup(m, o))
                    continue;
                var d = toTheLeft ? edge - (o.x + o.width) : o.x - edge;
                if (d >= 0)
                    toNeighbour = Math.min(toNeighbour, d);
            }
            return Math.max(0, Math.min(Prefs.barNotchFlare, Math.floor(toNeighbour / 2), Math.floor(toEdge)));
        }
        // Notch mode: one continuous background per side group, hugging the
        // screen edge. Union of the members' live surface rects, so morphs
        // blend per frame; bottom radius follows expansion. popupMode keeps
        // floating panels individual (only the compact row is grouped).
        // The flare curve itself is drawn natively by the plugin (per-pill
        // "fl" shoulder sizes): same capture and quad as the tab, so the
        // background stays perfectly uniform with a true inverted curve.
        // Outer-bottom corners stay square (tabs grow out of the screen
        // edge): side "left" squares bl, "right" squares br.
        function glassGroupFor(mods, side) {
            var out = [];
            var x0 = 1000000, x1 = -1000000, hMax = 0, any = false, anyOpen = false;
            var first = null, last = null;
            var cor = Prefs.barNotch ? Prefs.barNotchRadius : Prefs.barPillRadius;
            for (var i = 0; i < mods.length; i++) {
                var m = mods[i];
                if (!m || m.visible === false || m.width <= 0.5)
                    continue;
                var isBarPill = m.surfaceX !== undefined;
                var bx = isBarPill ? m.x + m.surfaceX : m.x;
                var bw = isBarPill ? m.surfaceWidth : m.width;
                var bh = isBarPill ? m.surfaceHeight : m.height;
                if (bx < x0)
                    x0 = bx;
                if (bx + bw > x1)
                    x1 = bx + bw;
                if (bh > hMax)
                    hMax = bh;
                any = true;
                if (!first)
                    first = m;
                last = m;
                if (m.anyOpen === true)
                    anyOpen = true;
                var c = m.cornerRadius !== undefined ? m.cornerRadius : Prefs.barPillRadius;
                if (c < cor)
                    cor = c;
            }
            if (!any)
                return out;
            if (anyOpen)
                cor = Math.max(cor, Theme.radiusLg);
            var fl = first ? bar.notchFlare(first, true) : 0;
            var fr = last ? bar.notchFlare(last, false) : 0;
            out.push({
                x: bar.glassQ(x0),
                y: 0,
                w: Math.max(1, bar.glassQ(x1 - x0)),
                h: bar.glassQ(hMax),
                r: side === "left" ? [0, 0, cor, 0] : (side === "right" ? [0, 0, 0, cor] : [0, 0, cor, cor]),
                fl: [fl, fr]
            });
            if (Prefs.barPopupMode) {
                for (var k = 0; k < mods.length; k++) {
                    var p = bar.glassPillFor(mods[k]);
                    if (p)
                        for (var j = 1; j < p.length; j++) out.push(p[j]);
                }
            }
            return out;
        }
        // Notch solo: when exactly one member of a multi-member group is open,
        // that member stretches across the full previous group span so its
        // content uses all available horizontal space; siblings collapse via
        // BarPill.soloCollapse (pure width slide, no shown/visible loop:
        // inputs are only expanded flags, shown flags and compact widths).
        // Single-member groups (clock) and popupMode never solo.
        function notchSoloMod(mods) {
            if (!Prefs.barNotch || Prefs.barPopupMode)
                return null;
            var present = [];
            for (var i = 0; i < mods.length; i++) {
                var m = mods[i];
                if (m && m.shown === true)
                    present.push(m);
            }
            if (present.length < 2)
                return null;
            var open = null, n = 0;
            for (var k = 0; k < present.length; k++) {
                if (present[k].expanded === true) {
                    open = present[k];
                    n++;
                }
            }
            return n === 1 ? open : null;
        }
        function soloCollapseFor(m, mods) {
            var s = bar.notchSoloMod(mods);
            return s !== null && s !== m;
        }
        // Stable group span from compact widths (live while collapsed).
        // Used to freeze the solo target: while a member is open its
        // siblings' compact widths can still jitter live (volume, battery,
        // track title, tray count...), and feeding that live span into the
        // open panelWidth retargets the width animation mid-flight - the
        // "jumping back to a smaller width" seen on side notches.
        function spanFor(mods) {
            var span = 0, n = 0;
            for (var i = 0; i < mods.length; i++) {
                var o = mods[i];
                if (o && o.shown === true) {
                    span += (o.compactWidth || 0);
                    n++;
                }
            }
            if (n > 1)
                span += Prefs.barSpacing * (n - 1);
            return Math.round(span);
        }
        readonly property var leftSolo: bar.notchSoloMod(bar.leftMods)
        readonly property var rightSolo: bar.notchSoloMod(bar.rightMods)
        readonly property int leftCurrentSpan: bar.spanFor(bar.leftMods)
        readonly property int rightCurrentSpan: bar.spanFor(bar.rightMods)
        property int leftFrozenSpan: 0
        property int rightFrozenSpan: 0
        onLeftCurrentSpanChanged: {
            if (!bar.leftSolo)
                bar.leftFrozenSpan = bar.leftCurrentSpan;
        }
        onRightCurrentSpanChanged: {
            if (!bar.rightSolo)
                bar.rightFrozenSpan = bar.rightCurrentSpan;
        }
        onLeftSoloChanged: {
            if (!bar.leftSolo)
                bar.leftFrozenSpan = bar.leftCurrentSpan;
        }
        onRightSoloChanged: {
            if (!bar.rightSolo)
                bar.rightFrozenSpan = bar.rightCurrentSpan;
        }
        // Full previous group span, frozen at expansion time so live
        // compact jitter while open can't retarget the width animation.
        // Never shrinks below the module default: narrow groups keep it.
        function notchSoloPanel(m, mods, defWidth) {
            var s = bar.notchSoloMod(mods);
            if (s !== m)
                return defWidth;
            var frozen = 0;
            if (mods === bar.leftMods || bar.leftMods.indexOf(m) >= 0)
                frozen = bar.leftFrozenSpan;
            else if (mods === bar.rightMods || bar.rightMods.indexOf(m) >= 0)
                frozen = bar.rightFrozenSpan;
            if (frozen <= 0)
                frozen = bar.spanFor(mods);
            return Math.max(defWidth, frozen);
        }
        // Solo notch tab (clock): compact rect with native flare shoulders.
        function glassNotchSolo(m) {
            var out = [];
            var p = bar.glassPillFor(m);
            if (!p)
                return out;
            var cm = p[0];
            cm.fl = [bar.notchFlare(m, true), bar.notchFlare(m, false)];
            out.push(cm);
            for (var j = 1; j < p.length; j++) out.push(p[j]);
            return out;
        }
        readonly property var glassPills: {
            if (Prefs.barNotch) {
                var outN = [];
                var gl = bar.glassGroupFor(bar.leftMods, "left");
                for (var a = 0; a < gl.length; a++) outN.push(gl[a]);
                var gr = bar.glassGroupFor(bar.rightMods, "right");
                for (var b = 0; b < gr.length; b++) outN.push(gr[b]);
                var gc = bar.glassNotchSolo(clockMod);
                for (var d = 0; d < gc.length; d++) outN.push(gc[d]);
                return outN;
            }
            var outI = [];
            var mods = [workspacesMod, mprisMod, sysTrayMod, clockMod, notifMod, systemMod];
            for (var i = 0; i < mods.length; i++) {
                var p = bar.glassPillFor(mods[i]);
                if (p)
                    for (var j = 0; j < p.length; j++) outI.push(p[j]);
            }
            return outI;
        }
        function placeGroup(widths, originX) {
            const gap = Prefs.barSpacing;
            const out = [];
            let x = originX;
            let any = false;
            for (let i = 0; i < widths.length; i++) {
                out.push(x);
                const w = widths[i];
                if (w > 0.5) {
                    x += w + (gap > 0 ? gap * Math.min(1, w / gap) : 0);
                    any = true;
                }
            }
            out.push(any ? Math.max(originX, x - Prefs.barSpacing) : originX);
            return out;
        }

        property real wsCollapse: (workspacesMod.expanded && !Prefs.barPopupMode) ? 0 : 1
        readonly property var leftWidths: [workspacesMod.width * bar.wsCollapse, mprisMod.width, sysTrayMod.width]
        readonly property var rightWidths: [notifMod.width, systemMod.width]
        readonly property var modules: [workspacesMod, mprisMod, sysTrayMod, clockMod, notifMod, systemMod]
        readonly property real leftGroupWidth: bar.placeGroup(bar.leftWidths, 0)[bar.leftWidths.length]
        readonly property real rightGroupWidth: bar.placeGroup(bar.rightWidths, 0)[bar.rightWidths.length]
        readonly property real leftOriginX: Prefs.barNotch ? -2 : bar.sideMargin
        readonly property real rightOriginX: bar.width - bar.rightGroupWidth - (Prefs.barNotch ? -2 : bar.sideMargin)
        readonly property var leftPlaces: bar.placeGroup(bar.leftWidths, bar.leftOriginX)
        readonly property var rightPlaces: bar.placeGroup(bar.rightWidths, bar.rightOriginX)

        Behavior on wsCollapse {
            NumberAnimation {
                duration: Theme.barMs(380)
                easing.type: Easing.OutCubic
            }

        }
        readonly property real sideMargin: Prefs.barSideMargin

        Component.onCompleted: {
            laidOutTimer.start();
            bar.leftFrozenSpan = bar.spanFor(bar.leftMods);
            bar.rightFrozenSpan = bar.spanFor(bar.rightMods);
        }

        Timer {
            id: laidOutTimer

            interval: 120
            onTriggered: bar.laidOut = true
        }

        color: "transparent"
        implicitHeight: bar.screen ? bar.screen.height - Prefs.effectiveBarTopMargin : 800
        exclusiveZone: (!bar.fullScreenOpen && Prefs.barEnabled && bar.anyModuleShown) ? Prefs.barHeight : 0

        anchors {
            top: true
            bottom: false
            left: true
            right: true
        }

        margins {
            top: Prefs.effectiveBarTopMargin
        }


        Mpris {
            id: mprisMod

            popupAlign: "left"
            externalGlass: Prefs.liquidGlassEnabled
            hostWindow: bar
            soloCollapse: bar.soloCollapseFor(mprisMod, bar.leftMods)
            panelWidth: bar.notchSoloPanel(mprisMod, bar.leftMods, Math.min(400, mprisMod.screenW - 34))
            x: bar.leftPlaces[1]
            anchors.top: parent.top

        }

        SysTray {
            id: sysTrayMod

            popupAlign: "left"
            externalGlass: Prefs.liquidGlassEnabled
            hostWindow: bar
            soloCollapse: bar.soloCollapseFor(sysTrayMod, bar.leftMods)
            panelWidth: bar.notchSoloPanel(sysTrayMod, bar.leftMods, Math.min(300, sysTrayMod.screenW - 34))
            x: bar.leftPlaces[2]
            anchors.top: parent.top

        }

        Clock {
            id: clockMod

            popupAlign: "center"
            externalGlass: Prefs.liquidGlassEnabled
            readonly property int sideGap: 28

            hostWindow: bar
            soloCollapse: bar.soloCollapseFor(clockMod, [clockMod])
            panelWidth: bar.notchSoloPanel(clockMod, [clockMod], Math.min(620, clockMod.screenW - 34))
            anchors.top: parent.top
            x: Math.min(Math.max((parent.width - width) / 2, (Prefs.barNotch ? 0 : bar.sideMargin) + bar.leftGroupWidth + sideGap), bar.width - bar.rightGroupWidth - (Prefs.barNotch ? 0 : bar.sideMargin) - width - sideGap)

        }

        Notifications {
            id: notifMod

            popupAlign: "right"
            externalGlass: Prefs.liquidGlassEnabled
            hostWindow: bar
            soloCollapse: bar.soloCollapseFor(notifMod, bar.rightMods)
            panelWidth: bar.notchSoloPanel(notifMod, bar.rightMods, Math.min(320, notifMod.screenW - 34))
            x: bar.rightPlaces[0]
            anchors.top: parent.top

        }

        System {
            id: systemMod

            popupAlign: "right"
            externalGlass: Prefs.liquidGlassEnabled
            hostWindow: bar
            notifMod: notifMod
            mprisMod: mprisMod
            soloCollapse: bar.soloCollapseFor(systemMod, bar.rightMods)
            panelWidth: bar.notchSoloPanel(systemMod, bar.rightMods, Math.min(400, systemMod.screenW - 34))
            x: bar.rightPlaces[1]
            anchors.top: parent.top

        }

        // Pill geometry for the liquid-glass-hypr plugin (see
        // ~/src/liquid-glass-hypr). One writer for the whole bar; the plugin
        // routes by surface size, so no per-module files or registries.
        GlassLayout {
            name: "bar"
            targetScreen: bar.screen
            surfaceW: bar.width
            surfaceH: bar.height
            pills: (Prefs.liquidGlassEnabled && bar.visible) ? bar.glassPills : []
        }

        Repeater {
            model: Prefs.barNotch ? bar.modules : []

            Item {
                id: flares

                required property var modelData

                readonly property bool present: flares.modelData && flares.modelData.width > 0.5 && flares.modelData.visible
                readonly property bool modHovered: flares.modelData ? (flares.modelData.compactHovered === true && flares.modelData !== workspacesMod) : false

                function flareFor(toTheLeft) {
                    if (!flares.present)
                        return 0;

                    var mods = bar.modules;
                    var edge = toTheLeft ? flares.modelData.x : flares.modelData.x + flares.modelData.width;
                    var toEdge = toTheLeft ? edge : bar.width - edge;
                    var toNeighbour = 100000;
                    for (var i = 0; i < mods.length; i++) {
                        var o = mods[i];
                        if (!o || o === flares.modelData || o.width <= 0.5 || !o.visible)
                            continue;
                        // Notch groups share one background: no flares between
                        // members of the same side group (clock stays solo).
                        if (bar.sameNotchGroup(flares.modelData, o))
                            continue;

                        var d = toTheLeft ? edge - (o.x + o.width) : o.x - edge;
                        if (d >= 0)
                            toNeighbour = Math.min(toNeighbour, d);

                    }
                    return Math.max(0, Math.min(Prefs.barNotchFlare, Math.floor(toNeighbour / 2), Math.floor(toEdge)));
                }

                anchors.fill: parent
                z: -1
                // Flat wedges are the non-external fallback: under external
                // glass the plugin draws the flare silhouette (wedge rects).
                visible: Prefs.barNotch && flares.present && flares.modelData.externalGlass !== true

                readonly property real bite: 0.5

                BarFlare {
                    hovered: flares.modHovered
                    size: flares.flareFor(true)
                    x: flares.modelData ? flares.modelData.x - width + flares.bite : 0
                    y: 0
                }

                BarFlare {
                    hovered: flares.modHovered
                    mirrored: true
                    size: flares.flareFor(false)
                    x: flares.modelData ? flares.modelData.x + flares.modelData.width - flares.bite : 0
                    y: 0
                }

            }

        }

        Dock {
            id: dock

            lockScreen: lockMod
        }

        Screenshot {
            id: screenshotMod

            onCaptured: snapMod.open = false
        }

        SnapOverlay {
            id: snapMod

            onFullscreenRequested: screenshotMod.captureFull(false, snapMod.freezePath)
            onRegionRequested: (x, y, w, h) => {
                return screenshotMod.captureRegion(x, y, w, h, false, snapMod.freezePath, snapMod.freezeScale);
            }
        }
        Workspaces {
            id: workspacesMod

            externalGlass: Prefs.liquidGlassEnabled
            hostWindow: bar
            soloCollapse: bar.soloCollapseFor(workspacesMod, bar.leftMods)
            restX: bar.leftPlaces[0]
            restY: 0

        }

        mask: Region {

            ModuleRegion {
                mod: workspacesMod
            }

            ModuleRegion {
                mod: mprisMod
            }

            ModuleRegion {
                mod: sysTrayMod
            }

            ModuleRegion {
                mod: clockMod
            }

            ModuleRegion {
                mod: notifMod
            }

            ModuleRegion {
                mod: systemMod
            }

        }

        // Real background blur now via live ScreencopyView + MultiEffect (modifiable via glass blur setting), not Hyprland
        BackgroundEffect.blurRegion: null

        Region {
            id: barBlurRegion

            ModuleRegion {
                blur: false
                mod: workspacesMod
            }

            ModuleRegion {
                blur: false
                mod: mprisMod
            }

            ModuleRegion {
                blur: false
                mod: sysTrayMod
            }

            ModuleRegion {
                blur: false
                mod: clockMod
            }

            ModuleRegion {
                blur: false
                mod: notifMod
            }

            ModuleRegion {
                blur: false
                mod: systemMod
            }

        }

    }


    Osd {
        id: osdMod
    }

    // Fake rounded screen corners on every monitor (black inverted corners,
    // Overlay layer so they mask windows like a physical rounded bezel).
    ScreenCorners {
        id: cornersMod
    }

    Lock {
        id: lockMod

        notifMod: notifMod
    }

    Moji {
        id: mojiMod
    }

    Settings {
        id: settingsMod
    }

    PanelWindow {
        id: clickCatcher

        visible: dock.menuOpen
        color: "transparent"
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Top

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        MouseArea {
            anchors.fill: parent
            onClicked: dock.menuOpen = false
        }

    }

    Connections {
        function onExpandedChanged() {
            if (workspacesMod.expanded)
                dock.menuOpen = false;

        }

        target: workspacesMod
    }

    Connections {
        function onMenuOpenChanged() {
            if (dock.menuOpen)
                workspacesMod.expanded = false;

        }

        target: dock
    }

}
