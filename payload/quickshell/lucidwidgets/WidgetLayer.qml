import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs
import "../lucidbar" as LucidBar

Variants {
    id: variants

    model: Quickshell.screens

    Scope {
        id: unit

        required property var modelData

        PanelWindow {
            id: layer

            PaletteFade {
                active: layer.visible
            }

            readonly property bool suppressed: Prefs.widgetHideFullscreen && layer.fullscreenUp
            // virtual outputs used for the background-only live capture have no
            // widgets: otherwise the clock/calendar would be baked into it
            readonly property bool captureScreen: String(unit.modelData && unit.modelData.name || "").indexOf("HEADLESS") === 0
            readonly property bool fullscreenUp: {
                var t = Hyprland.activeToplevel;
                if (!t || !t.lastIpcObject)
                    return false;

                return (t.lastIpcObject.fullscreen || 0) > 0;
            }

            screen: unit.modelData
            visible: Prefs.loaded && Widgets.loaded && !layer.captureScreen && (deck.panelLive || (Prefs.widgetsEnabled && Widgets.count > 0 && !layer.suppressed))
            color: "transparent"
            // reserves nothing and refuses to be shrunk into the bar and dock's strips,
            // so a card can be dragged to a true screen edge and sit under the dock.
            // setting exclusiveZone at all would silently undo this
            exclusionMode: ExclusionMode.Ignore
            // the widget panel lifts the whole board over the windows until it has slid away
            WlrLayershell.layer: deck.panelLive ? WlrLayer.Overlay : (Prefs.widgetOnTop ? WlrLayer.Top : WlrLayer.Bottom)
            // the spatial wallpaper ranks this namespace in front of the
            // desktop icon board but behind the window layer
            WlrLayershell.namespace: "lucid-widgets"
            WlrLayershell.keyboardFocus: deck.panelUp ? WlrKeyboardFocus.Exclusive : (deck.wantsKeyboard ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None)

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            // lastIpcObject only moves when something asks it to, so nudge it on the
            // events that can change whether a window is fullscreen
            Connections {
                function onRawEvent(event) {
                    if (event.name === "fullscreen" || event.name === "activewindowv2" || event.name === "closewindow")
                        fullscreenPoll.restart();

                }

                enabled: Prefs.widgetHideFullscreen
                target: Hyprland
            }

            Timer {
                id: fullscreenPoll

                interval: 120
                onTriggered: Hyprland.refreshToplevels()
            }

            // Publish the cards to the compositor's liquid-glass plugin. The
            // publisher is an invisible item; the plugin reads the JSON it
            // writes and draws the glass behind this layer surface.
            LucidBar.GlassLayout {
                id: widgetsGlass
                name: "widgets"
                surfaceNamespace: "lucid-widgets"
                targetScreen: layer.screen
                surfaceW: layer.width
                surfaceH: layer.height
                pills: deck.glassPills
            }

            Item {
                id: deck

                // bumped whenever the repeater's children change, so frameAt() bindings re-run
                property int rev: 0
                property Item dragFrame: null
                property string spatialSig: ""
                property string spatialHoverSig: ""

                readonly property string screenName: layer.screen ? layer.screen.name : ""
                // where this board sits in the global layout, so a card in hand
                // can be placed across outputs
                readonly property real screenX: (layer.screen && layer.screen.x !== undefined) ? Number(layer.screen.x) : 0
                readonly property real screenY: (layer.screen && layer.screen.y !== undefined) ? Number(layer.screen.y) : 0
                readonly property bool isPrimary: layer.screen !== null && layer.screen === Monitors.mainScreen
                // the widget panel is open on this screen, and still on its way out
                readonly property bool panelUp: Widgets.panelScreen !== "" && Widgets.panelScreen === deck.screenName
                readonly property bool panelLive: deck.panelUp || panel.shown
                readonly property int frameCount: rep.count
                // Liquid glass (liquid-glass-hypr): the compositor draws the
                // glass behind each card, so publish the cards as pills on the
                // lucid-widgets namespace (added to the plugin's namespace
                // list in hyprland.lua). A bare card has no container to put
                // glass behind, and a closing/blanked one has nothing to show.
                //
                // f.x/f.y are the *rendered* geometry, not the store position:
                // while a card is in hand they read the live drag rect (and
                // the res box while resizing), so the glass travels with the
                // card instead of staying where it was picked up. Published
                // from the frames the board actually shows, so a card crossing
                // a seam is handled by each output's own publisher.
                readonly property var glassPills: {
                    var _ = deck.rev;
                    if (!Prefs.loaded || !Prefs.liquidGlassEnabled || !layer.visible)
                        return [];

                    var out = [];
                    for (var i = 0; i < rep.count; i++) {
                        var f = rep.itemAt(i);
                        // a card in hand paints its normal opaque background
                        // (see WidgetFrame.glassSuspended) instead of asking the
                        // plugin for a per-frame blur of a moving pill
                        if (!f || !f.visible || f.closing || f.blanked || f.bare || f.moving)
                            continue;

                        var s = f.scale > 0 ? f.scale : 1;
                        // Quantise the bridge payload to half a logical pixel.
                        // The compositor snaps the card to pixels anyway, so
                        // this is invisible, but it keeps the JSON short and
                        // lets sub-half-pixel frames compare equal (the bridge
                        // then skips the rewrite and the plugin skips the read).
                        var w = Math.round(f.width * s * 2) / 2;
                        var h = Math.round(f.height * s * 2) / 2;
                        var r = Math.round(f.radius * s * 2) / 2;
                        // map the card's own origin through its live transform:
                        // the glass must sit on the rendered card, not on the
                        // stored x/y or on a hand-rebuilt scale origin
                        var _ = f.x + f.y + f.width + f.height + f.scale + f.radius;
                        var at = f.mapToItem(deck, 0, 0);
                        out.push({
                            "x": Math.round(at.x * 2) / 2,
                            "y": Math.round(at.y * 2) / 2,
                            "w": w,
                            "h": h,
                            "r": [r, r, r, r],
                            "sq": Prefs.squircleF
                        });
                    }
                    return out;
                }
                readonly property bool editing: Widgets.editUid !== "" && deck.editFrame !== null
                // only ask for keys at all once something you can type into is placed;
                // on-demand hands focus back the moment a window is clicked, which
                // exclusive would not
                readonly property bool wantsKeyboard: {
                    for (var i = 0; i < Widgets.model.count; i++) {
                        var e = Widgets.model.get(i);
                        if (!e.closing && (e.wtype === "notes" || e.wtype === "todo" || e.wtype === "github" || e.wtype === "mesh" || e.wtype === "social"))
                            return true;

                    }
                    return false;
                }
                readonly property bool grabbing: Widgets.dragUid !== "" || Widgets.menuUid !== "" || deck.editing
                readonly property Item menuFrame: {
                    var _ = deck.rev;
                    for (var i = 0; i < rep.count; i++) {
                        var f = rep.itemAt(i);
                        if (f && f.uid === Widgets.menuUid && f.visible)
                            return f;

                    }
                    return null;
                }
                readonly property Item editFrame: {
                    var _ = deck.rev;
                    for (var i = 0; i < rep.count; i++) {
                        var f = rep.itemAt(i);
                        if (f && f.uid === Widgets.editUid && f.visible)
                            return f;

                    }
                    return null;
                }

                function frameAt(i) {
                    var _ = deck.rev;
                    return (i >= 0 && i < rep.count) ? rep.itemAt(i) : null;
                }

                function frameFor(uid) {
                    for (var i = 0; i < rep.count; i++) {
                        var f = rep.itemAt(i);
                        if (f && f.uid === uid)
                            return f;

                    }
                    return null;
                }

                // a board point over the open panel, where a dragged card is let go of
                function binHit(px, py) {
                    return deck.panelUp && panel.sheetHit(px, py);
                }

                // the topmost card under a board point, for the menu overlay: it
                // covers the screen while it is up, so the cards never see the press
                function frameUnder(px, py) {
                    var best = null;
                    for (var i = 0; i < rep.count; i++) {
                        var f = rep.itemAt(i);
                        if (!f || !f.visible || f.closing)
                            continue;

                        if (px < f.x || px > f.x + f.width || py < f.y || py > f.y + f.height)
                            continue;

                        if (best === null || f.z >= best.z)
                            best = f;

                    }
                    return best;
                }

                anchors.fill: parent
                focus: true
                Keys.onPressed: (event) => {
                    if (event.key !== Qt.Key_PageUp && event.key !== Qt.Key_PageDown && event.key !== Qt.Key_Home && event.key !== Qt.Key_End)
                        return ;

                    for (var i = 0; i < rep.count; i++) {
                        var f = rep.itemAt(i);
                        if (!f || !f.visible || f.closing || f.hovered !== true)
                            continue;

                        if (f.handleScrollKey(event)) {
                            event.accepted = true;
                            return ;
                        }
                    }
                }
                Keys.onEscapePressed: {
                    var busy = Widgets.editUid !== "" || Widgets.menuUid !== "" || Object.keys(Widgets.selection).length > 0;
                    Widgets.editUid = "";
                    Widgets.menuUid = "";
                    Widgets.clearSelection();
                    if (!busy && deck.panelUp)
                        Widgets.closePanel();

                }
                onWidthChanged: deck.report()
                onHeightChanged: deck.report()
                Component.onCompleted: deck.report()

                function report() {
                    if (deck.isPrimary && deck.width > 0) {
                        Widgets.canvasW = deck.width;
                        Widgets.canvasH = deck.height;
                    }
                }

                // the dim behind the cards while the widget panel is open, and the way out of it
                Rectangle {
                    anchors.fill: parent
                    color: Theme.alpha(Theme.cScrim, Theme.blurAmount > 0 ? 0.3 : 0.5)
                    opacity: panel.reveal
                    visible: opacity > 0.01

                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        enabled: deck.panelUp
                        onWheel: (event) => {
                            return event.accepted = true;
                        }
                    }

                }

                // click-through everywhere except the cards, so this only fires for the
                // open menu, a note being typed in, or the widget panel
                MouseArea {
                    anchors.fill: parent
                    enabled: deck.grabbing || deck.panelUp
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onPressed: {
                        var busy = Widgets.menuUid !== "" || Widgets.editUid !== "";
                        Widgets.menuUid = "";
                        Widgets.editUid = "";
                        if (!busy && deck.panelUp) {
                            Widgets.clearSelection();
                            Widgets.closePanel();
                        }

                    }
                }

                // the cards stack among themselves, under the guides and the panel
                Item {
                    anchors.fill: parent

                    Repeater {
                        id: rep

                        model: Widgets.model
                        onItemAdded: deck.rev++
                        onItemRemoved: deck.rev++

                        WidgetFrame {
                            board: deck
                        }

                    }

                }

                Rectangle {
                    width: 1
                    height: deck.height
                    x: deck.dragFrame ? deck.dragFrame.guideX : -1
                    color: Theme.accent
                    opacity: (deck.dragFrame && deck.dragFrame.guideX >= 0) ? 0.65 : 0
                    visible: opacity > 0.01
                    z: 900

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.durQuick
                        }

                    }

                }

                Rectangle {
                    height: 1
                    width: deck.width
                    y: deck.dragFrame ? deck.dragFrame.guideY : -1
                    color: Theme.accent
                    opacity: (deck.dragFrame && deck.dragFrame.guideY >= 0) ? 0.65 : 0
                    visible: opacity > 0.01
                    z: 900

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.durQuick
                        }

                    }

                }

                WidgetPanel {
                    id: panel

                    anchors.fill: parent
                    z: 1000
                    board: deck
                }

                // Publish the cards the spatial foreground may need to draw
                // over. Polling is deliberate: x/y/hover change continuously
                // during a drag and a per-property binding on every card would
                // be more code and more churn than one 30 Hz read.
                Timer {
                    id: spatialCards

                    interval: 33
                    repeat: true
                    running: SpatialWall.enabled && SpatialWall.displaysAwake
                        && layer.visible && !layer.captureScreen
                    onRunningChanged: {
                        if (!spatialCards.running) {
                            deck.spatialSig = "";
                            SpatialWidgets.clear(deck.screenName);
                        }
                    }
                    onTriggered: {
                        var out = [];
                        var hovered = {};
                        // Integer rects and a hand-built signature: the cutout
                        // is a soft subject overlay, so 1px is invisible, and a
                        // concatenation costs a fraction of JSON.stringify on
                        // V4 (this timer runs 30x/s for the whole board).
                        var sig = "";
                        var hoverSig = "";
                        for (var i = 0; i < deck.frameCount; i++) {
                            var frame = deck.frameAt(i);
                            if (!frame || !frame.visible || frame.closing || frame.blanked)
                                continue;
                            // The cutout must sit on the *rendered* card: hover
                            // lifts it to 1.0125 and a drag carries it at 1.025,
                            // so the unscaled x/y/w/h would leave the subject
                            // overlap on the card's outer few pixels. Same
                            // mapped+scaled rect as the glass pills, rounded
                            // outward so the covered area can never be smaller
                            // than the glass it hides.
                            var s = frame.scale > 0 ? frame.scale : 1;
                            var at = frame.mapToItem(deck, 0, 0);
                            var fx = Math.floor(at.x) - 1;
                            var fy = Math.floor(at.y) - 1;
                            var fw = Math.ceil(at.x + frame.width * s) + 1 - fx;
                            var fh = Math.ceil(at.y + frame.height * s) + 1 - fy;
                            out.push({
                                "uid": frame.uid,
                                "x": fx,
                                "y": fy,
                                "w": fw,
                                "h": fh
                            });
                            var hov = frame.hovered === true;
                            hovered[frame.uid] = hov;
                            sig += frame.uid + ":" + fx + "," + fy + "," + fw + "," + fh + ";";
                            hoverSig += frame.uid + (hov ? "1" : "0") + ";";
                        }
                        if (sig !== deck.spatialSig) {
                            deck.spatialSig = sig;
                            SpatialWidgets.update(deck.screenName, out);
                        }
                        if (hoverSig !== deck.spatialHoverSig) {
                            deck.spatialHoverSig = hoverSig;
                            SpatialWidgets.updateHovered(hovered);
                        }
                    }
                }

            }

            mask: Region {
                x: 0
                y: 0
                // a desktop selection box owns the pointer while it is out:
                // keep the widget layer click-through so the box's layer below
                // keeps receiving the drag instead of being cancelled
                width: ((deck.grabbing || deck.panelUp) && Widgets.marquee === null) ? layer.width : 0
                height: ((deck.grabbing || deck.panelUp) && Widgets.marquee === null) ? layer.height : 0

            WidgetRegion {
                frame: deck.frameAt(0)
            }

            WidgetRegion {
                frame: deck.frameAt(1)
            }

            WidgetRegion {
                frame: deck.frameAt(2)
            }

            WidgetRegion {
                frame: deck.frameAt(3)
            }

            WidgetRegion {
                frame: deck.frameAt(4)
            }

            WidgetRegion {
                frame: deck.frameAt(5)
            }

            WidgetRegion {
                frame: deck.frameAt(6)
            }

            WidgetRegion {
                frame: deck.frameAt(7)
            }

            WidgetRegion {
                frame: deck.frameAt(8)
            }

            WidgetRegion {
                frame: deck.frameAt(9)
            }

            WidgetRegion {
                frame: deck.frameAt(10)
            }

            WidgetRegion {
                frame: deck.frameAt(11)
            }

            WidgetRegion {
                frame: deck.frameAt(12)
            }

            WidgetRegion {
                frame: deck.frameAt(13)
            }

            WidgetRegion {
                frame: deck.frameAt(14)
            }

            WidgetRegion {
                frame: deck.frameAt(15)
            }

            WidgetRegion {
                frame: deck.frameAt(16)
            }

            WidgetRegion {
                frame: deck.frameAt(17)
            }

            WidgetRegion {
                frame: deck.frameAt(18)
            }

            WidgetRegion {
                frame: deck.frameAt(19)
            }

            }

            // the open panel frosts the whole screen behind its dim, cards and
            // sheet alike. With liquid glass on, the plugin frosts each card
            // itself, so the card blur region steps aside (the panel keeps its
            // own whole-screen frost).
            BackgroundEffect.blurRegion: Theme.blurAmount > 0 ? (deck.panelUp ? wholeBlur : (Prefs.liquidGlassEnabled ? null : widgetBlur)) : null

            Region {
                id: wholeBlur

                width: layer.width
                height: layer.height
            }

            Region {
                id: widgetBlur

            WidgetRegion {
                blur: true
                frame: deck.frameAt(0)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(1)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(2)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(3)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(4)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(5)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(6)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(7)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(8)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(9)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(10)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(11)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(12)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(13)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(14)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(15)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(16)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(17)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(18)
            }

            WidgetRegion {
                blur: true
                frame: deck.frameAt(19)
            }

            }

        }

        // an options panel on the widget layer would sit under every window, so it
        // gets an overlay of its own that only exists while the panel is up
        PanelWindow {
            id: menuLayer

            // the frame the panel belongs to, held past the close so the fade-out
            // keeps its geometry and its contents
            property Item held: null

            readonly property Item target: deck.menuFrame

            screen: unit.modelData
            // up the moment the menu opens, so the fade-in plays inside a mapped
            // surface, and stays up until the fade-out finishes
            visible: menuLayer.target !== null || menu.visible
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: menuLayer.target !== null ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
            onTargetChanged: if (menuLayer.target)
                menuLayer.held = menuLayer.target
            onVisibleChanged: if (!menuLayer.visible)
                menuLayer.held = null

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            Item {
                anchors.fill: parent
                focus: true
                Keys.onEscapePressed: Widgets.menuUid = ""

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onPressed: (mouse) => {
                        var f = mouse.button === Qt.RightButton ? deck.frameUnder(mouse.x, mouse.y) : null;
                        var was = Widgets.menuUid;
                        Widgets.menuUid = "";
                        // a right press on another card carries the panel over to it,
                        // the way it did when the panel still sat on the widget layer
                        if (f && f.uid !== was)
                            f.toggleMenu(mouse.x - f.x, mouse.y - f.y);

                    }
                }

                WidgetMenu {
                    id: menu

                    frame: menuLayer.held
                    fieldW: menuLayer.width
                    fieldH: menuLayer.height
                }

            }

            // no input once the panel starts closing, so the fade-out is never a
            // dead region over the screen
            mask: Region {
                width: menuLayer.target ? menuLayer.width : 0
                height: menuLayer.target ? menuLayer.height : 0
            }

            BackgroundEffect.blurRegion: Theme.blurAmount > 0 ? menuBlur : null

            Region {
                id: menuBlur

                WidgetRegion {
                    blur: true
                    part: "menu"
                    panel: menu
                }

            }

        }

    }

}
