import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "root:/config"
import "root:/services"

// The launch-morph stages: one fullscreen, fully input-transparent window
// per monitor (see services/Morph.qml for the model/matching). Separate
// windows on purpose: the launcher closes the instant the app spawns and
// releases exclusive focus, so typing, Super-taps and further launches all
// work mid-flight - each new launch just appends another morph row.
//
// A morph renders on the stage of its CURRENT monitor: the launcher's while
// waiting (source tile coords), the window's once mapped. Namespace
// deliberately outside the liquid-glass-hypr plugin's "quickshell" substring
// gate (and the quickshell xray layerrule): these surfaces draw their own
// opaque containers and want neither.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: stage
        required property var modelData
        screen: modelData

        // Snapshot late, never at load (see refreshMon).
        property int myId: -1
        property real orgX: 0
        property real orgY: 0
        function refreshMon(): void {
            // Primary: compositor truth cached at startup (see
            // Morph.monGeos). Fallback: live query with the stub guard -
            // only ever hit in the daemon's first ~100ms.
            const g = Morph.monGeo(stage.screen ? stage.screen.name : "");
            if (g) {
                stage.myId = g.id;
                stage.orgX = g.x;
                stage.orgY = g.y;
                return;
            }
            const m = Hyprland.monitorFor(stage.screen);
            // Stubs (load-time: id -1) keep the previous snapshot; the real
            // values are in place long before any user can launch.
            if (!m || m.id === undefined || m.id === null || m.id < 0)
                return;
            stage.myId = m.id;
            if (Number.isFinite(m.x) && Number.isFinite(m.y)) {
                stage.orgX = m.x;
                stage.orgY = m.y;
            }
        }

        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        // Tight box, not fullscreen: a fullscreen transparent stage makes
        // the compositor composite (and blur-sample) the whole output for
        // every flight frame. The box is the union of this stage's morphs'
        // travel (from+to) plus pad for the flights' sculpt overflow (their
        // union items overhang the bare travel by up to ~88px), recomputed
        // when the set changes - mid-flight it only ever grows/shifts if a
        // concurrent morph lands here, never on animation ticks, so flights
        // don't chase it. Delegates paint in box-independent coords (see
        // uniOX below), so box moves need no compensation anywhere.
        property real boxX: 0
        property real boxY: 0
        property real boxW: 1
        property real boxH: 1
        function recomputeBox(): void {
            stage.refreshMon();
            // While a flight is running the box may only EXPAND (never move
            // its origin): every origin shift retargets the live `to:`
            // bindings mid-flight and the container chases forever, landing
            // short (up-left) of the window. Cover growth still fits, and
            // full recomputes resume once all rows are past morph.
            let frozen = false;
            for (let i = 0; i < Morph.morphs.count; i++) {
                const ph = Morph.morphs.get(i).phase;
                if (ph === "morph" || ph === "fade") {
                    frozen = true;
                    break;
                }
            }
            let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9, n = 0;
            for (let i = 0; i < Morph.morphs.count; i++) {
                const m = Morph.morphs.get(i);
                if (m.monId !== stage.myId)
                    continue;
                n++;
                // Union margin alone is NOT enough: the spring overshoots
                // past full size (~6% with the current curve), and the
                // ghost can glide on settle - both beyond the bare travel.
                // So the union margin pads the travel generously; delegates
                // not yet laid out contribute their model travel instead.
                // Coordinate spaces (this bit us before - read carefully):
                // model roles (m.*GX) are GLOBAL, flight uni* are
                // ORG-RELATIVE (minus stage.orgX/orgY, box-independent), and
                // the box math below is STAGE-LOCAL - so model values are
                // converted with - stage.orgX/orgY and union values USED AS
                // IS (no org subtraction - that double-subtract shrank the
                // box to nothing and hid every flight).
                const fm = (f && f.unionMargin > 0) ? f.unionMargin : 88;
                const ux0 = (f && f.uniOW > 1) ? f.uniOX : m.fromGX - stage.orgX - fm;
                const uy0 = (f && f.uniOH > 1) ? f.uniOY : m.fromGY - stage.orgY - fm;
                const ux1 = (f && f.uniOW > 1) ? f.uniOX + f.uniOW : m.fromGX + m.fromGW - stage.orgX + fm;
                const uy1 = (f && f.uniOH > 1) ? f.uniOY + f.uniOH : m.fromGY + m.fromGH - stage.orgY + fm;
                x0 = Math.min(x0, ux0, m.toGX - fm - stage.orgX);
                y0 = Math.min(y0, uy0, m.toGY - fm - stage.orgY);
                x1 = Math.max(x1, ux1, m.toGX + m.toGW + fm - stage.orgX);
                y1 = Math.max(y1, uy1, m.toGY + m.toGH + fm - stage.orgY);
            }
            if (!n) {
                stage.boxX = 0; stage.boxY = 0; stage.boxW = 1; stage.boxH = 1;
                return;
            }
            // Global -> stage-local, padded, clamped to the output.
            // Frozen (a flight is running): grow right/bottom only, so no
            // `to:` binding retargets and no compensation runs.
            // The flight margin above already covers sculpt overflow; this
            // pad is only rounding slack.
            const pad = 8;
            const sw = stage.screen ? stage.screen.width : 1600;
            const sh = stage.screen ? stage.screen.height : 900;
            if (frozen) {
                x1 = Math.min(sw, x1 - stage.orgX + pad);
                y1 = Math.min(sh, y1 - stage.orgY + pad);
                stage.boxW = Math.max(1, x1 - stage.boxX);
                stage.boxH = Math.max(1, y1 - stage.boxY);
                return;
            }
            x0 = Math.max(0, x0 - stage.orgX - pad);
            y0 = Math.max(0, y0 - stage.orgY - pad);
            x1 = Math.min(sw, x1 - stage.orgX + pad);
            y1 = Math.min(sh, y1 - stage.orgY + pad);
            // Keep rendered positions continuous: delegates store their
            // union in box-independent coords (see uniOX) and rebase via
            // boxX/boxY bindings, so a box move carries them along with
            // no compensation loop at all.
            stage.boxX = x0; stage.boxY = y0;
            stage.boxW = Math.max(1, x1 - x0); stage.boxH = Math.max(1, y1 - y0);
        }
        Connections {
            target: Morph.morphs
            function onCountChanged(): void { stage.recomputeBox(); }
        }
        Connections {
            target: Morph
            // Monitor cache landing (or moving) re-roots every box: until
            // then orgX/orgY may still be load-time stubs.
            function onMonGeosChanged(): void { stage.recomputeBox(); }
            // Every model write (see Morph.touch): ListModel.dataChanged
            // proved unreliable, so routing runs off this stamp instead.
            function onRevChanged(): void { stage.recomputeBox(); }
        }
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        // Tight box, not fullscreen (see recomputeBox): margins inset the
        // fullscreen-anchored stage down to the flights' union.
        margins {
            top: stage.boxY
            bottom: Math.max(0, (stage.screen ? stage.screen.height : 900) - stage.boxY - stage.boxH)
            left: stage.boxX
            right: Math.max(0, (stage.screen ? stage.screen.width : 1600) - stage.boxX - stage.boxW)
        }
        // Overlay while a flight is active so the morph renders above
        // fullscreen windows (Top sits below them), Top while idle to
        // avoid an always-mapped Overlay surface (see LauncherWindow).
        WlrLayershell.layer: Morph.morphs.count > 0 ? WlrLayer.Overlay : WlrLayer.Top
        WlrLayershell.namespace: "pibble-morph"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // Empty region: every click falls through to whatever is underneath.
    // (A 1px rect, not literally empty: an empty mask risks the compositor
    // culling the surface before it ever paints.)
    mask: Region {
        Region {
            x: 0
            y: 0
            width: 1
            height: 1
        }
    }
    // Always mapped (from daemon start): a cold-mapping stage loses the
    // race against fast apps - by the time it paints, the window is
    // already opening and the waiter never shows. The tight box above
    // keeps the idle surface at 1x1 with an empty input mask, so a mapped
    // idle stage costs the compositor essentially nothing.
        visible: true

        Repeater {
            id: flights
            model: Morph.morphs

            Item {
                id: flight
                required property int mid
                required property string icon
                required property bool isSteam
                required property real fromGX
                required property real fromGY
                required property real fromGW
                required property real fromGH
                required property real toGX
                required property real toGY
                required property real toGW
                required property real toGH
                required property real covGX
                required property real covGY
                required property real covGW
                required property real covGH
                required property bool covOn
                required property bool wsOk
                required property int monId
                required property string phase
                required property string addr
                required property int ws

                // This row belongs on this stage's monitor right now, and
                // on the workspace it launched on: layer surfaces show on
                // every desktop, so a mid-flight desktop switch hides the
                // flight instead of drawing it over the wrong one.
                readonly property bool mine: flight.monId === stage.myId
                visible: flight.mine && (flight.ws < 0 || flight.ws === Morph.activeWs)

                // Smoothstep helper for the icon ride below.
                function s01(u: real): real { const v = Math.min(1, Math.max(0, u)); return v * v * (3 - 2 * v); }

                // Ooze surface (see shaders/morph-ooze.frag): the whole
                // transition is ONE progress value on a soft spring - dot,
                // cord and window share a single goo field, and the window
                // end glides live with settle. All coords item-local via
                // the union origin (uniOX/uniOY), so nothing here can chase
                // or teleport when the model or the stage box moves.
                ShaderEffect {
                    id: flightBlob
                    anchors.fill: parent
                    property color oozeColor: Theme.surface
                    property size oozeRes: Qt.size(flightBlob.width, flightBlob.height)
                    property real oozeProg: flight.prog
                    property vector2d oozeFrom: Qt.vector2d(flight.fromCX - flight.uniOX, flight.fromCY - flight.uniOY)
                    property real oozeFromR: Math.min(flight.fromGW, flight.fromGH) * 0.5
                    property vector2d oozeTo: Qt.vector2d(flight.toCX - flight.uniOX, flight.toCY - flight.uniOY)
                    property vector2d oozeToHalf: Qt.vector2d(flight.toLW * 0.5, flight.toLH * 0.5)
                    property real oozeToR: 14
                    fragmentShader: "shaders/morph-ooze.frag.qsb"
                }

                // App icon rides the traveling dot all the way into the
                // window center (same center curve as the shader) and fades
                // only with the reveal - never stranded at the tile while
                // the goo lands without it.
                Image {
                    x: flight.fromCX + (flight.toCX - flight.fromCX) * flight.s01(flight.prog / 0.75) - flight.uniOX - 22
                    y: flight.fromCY + (flight.toCY - flight.fromCY) * flight.s01(flight.prog / 0.75) - flight.uniOY - 22
                    width: 44
                    height: 44
                    sourceSize: Qt.size(88, 88)
                    asynchronous: true
                    // Same rule as the grid tile: Steam art is cover
                    // stills, cropped square; desktop icons keep fit.
                    fillMode: flight.isSteam ? Image.PreserveAspectCrop : Image.PreserveAspectFit
                    source: Icons.url(flight.icon)
                    visible: status === Image.Ready
                    opacity: flight.popa
                }

                // The transition is ONE spring-driven progress value (see
                // progSpring): the shader interpolates every endpoint.
                property real prog: 0
                property real popa: 0
                // Union box, org-relative (box-independent): x/y rebase via
                // boxX/boxY bindings, and every shader coord derives from
                // uniOX/uniOY the same way, so stage-box moves need no
                // compensation and endpoint glides stay seamless.
                property real uniOX: 0
                property real uniOY: 0
                property real uniOW: 1
                property real uniOH: 1
                // Claim steers glide the union too (not just the window
                // end): a refit that jumped would teleport the goo.
                Behavior on uniOX { enabled: flight.flying; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                Behavior on uniOY { enabled: flight.flying; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                Behavior on uniOW { enabled: flight.flying; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                Behavior on uniOH { enabled: flight.flying; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                x: uniOX - stage.boxX
                y: uniOY - stage.boxY
                width: uniOW
                height: uniOH
                opacity: popa
                transformOrigin: Item.Center

                // Fade in only (no scale: this item is the whole travel
                // union, so scaling it would displace the flight).
                SequentialAnimation {
                    id: appearAnim
                    NumberAnimation { target: flight; property: "popa"; from: 0; to: 1; duration: 80; easing.type: Easing.OutCubic }
                }
                // Soft spring into the window: eased launch, a breath past
                // full (the shader spends the overshoot as a size pop, then
                // holds), calm landing. Fixed curve, nothing shape-wise.
                SpringAnimation {
                    id: progSpring
                    target: flight
                    property: "prog"
                    to: 1
                    // ~1.5s flight (was ~750ms at 2.0/0.25): halve both to
                    // keep the same overshoot character at double duration.
                    spring: 0.5
                    damping: 0.125
                    epsilon: 0.01
                    onFinished: {
                        // Unclaimed rows hold the settled goo at the
                        // predicted target instead of bowing out: the claim
                        // steers them onto the real window (see retarget +
                        // fadeGrace). Claimed rows reveal.
                        if (flight.addr)
                            Morph.beginFade(flight.mid);
                    }
                }
                NumberAnimation {
                    id: fadeAnim
                    target: flight
                    property: "popa"
                    to: 0
                    duration: 120
                    easing.type: Easing.OutCubic
                    onFinished: Morph.remove(flight.mid)
                }

                // Local endpoints, org-relative (box-independent). toLX/...
                // glide on Behaviors while flying so settle commits slide
                // the window end instead of teleporting it; snapped instant
                // while not flying (waiter setup, morph start).
                property real fromLX: 0
                property real fromLY: 0
                property real toLX: 0
                property real toLY: 0
                property real toLW: 0
                property real toLH: 0
                Behavior on toLX { enabled: flight.flying; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                Behavior on toLY { enabled: flight.flying; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                Behavior on toLW { enabled: flight.flying; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                Behavior on toLH { enabled: flight.flying; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                readonly property real fromCX: flight.fromLX + flight.fromGW * 0.5
                readonly property real fromCY: flight.fromLY + flight.fromGH * 0.5
                readonly property real toCX: flight.toLX + flight.toLW * 0.5
                readonly property real toCY: flight.toLY + flight.toLH * 0.5
                // True between startMorph and landing/fade: gates retarget().
                property bool flying: false

                function snapToEndpoints(): void {
                    flight.fromLX = flight.fromGX - stage.orgX;
                    flight.fromLY = flight.fromGY - stage.orgY;
                    flight.toLX = flight.toGX - stage.orgX;
                    flight.toLY = flight.toGY - stage.orgY;
                    flight.toLW = flight.toGW;
                    flight.toLH = flight.toGH;
                }

                // Union of tile+window (+sculpt margin), org-relative: every
                // shader coord derives from it, so refits are seamless. The
                // margin is read back by the stage box (see recomputeBox),
                // so the two can never disagree about what fits.
                readonly property real unionMargin: 88
                function fitUnion(): void {
                    const m = flight.unionMargin;
                    const x0 = Math.min(flight.fromLX, flight.toLX) - m;
                    const y0 = Math.min(flight.fromLY, flight.toLY) - m;
                    const x1 = Math.max(flight.fromLX + flight.fromGW, flight.toLX + flight.toLW) + m;
                    const y1 = Math.max(flight.fromLY + flight.fromGH, flight.toLY + flight.toLH) + m;
                    flight.uniOX = x0; flight.uniOY = y0;
                    flight.uniOW = Math.max(1, x1 - x0); flight.uniOH = Math.max(1, y1 - y0);
                }

                function startMorph(): void {
                    appearAnim.stop();
                    flight.scale = 1;
                    flight.snapToEndpoints();
                    flight.fitUnion();
                    flight.prog = 0;
                    // Full opacity up front: on fast settles the spring can
                    // start while appearAnim is still fading in, which left
                    // the whole flight stranded at half opacity.
                    flight.popa = 1;
                    flight.flying = true;
                    progSpring.restart();
                }

                function startFade(): void {
                    flight.flying = false;
                    appearAnim.stop();
                    progSpring.stop();
                    fadeAnim.restart();
                }

                // Settle/claim steering from the service: the window end
                // glides on its Behaviors and the union refits on its own -
                // a smooth course correction, not a teleport. A claim that
                // lands after the spring already settled (held goo) gets a
                // beat of glide, then the reveal. Ignored unless mid-flight.
                function retarget(): void {
                    if (!flight.flying || !flight.mine || flight.phase !== "morph")
                        return;
                    flight.snapToEndpoints();
                    flight.fitUnion();
                    if (flight.prog > 0.9 && flight.addr)
                        fadeGrace.restart();
                }

                // Grace glide for held goo before the reveal (see retarget).
                Timer {
                    id: fadeGrace
                    interval: 200
                    repeat: false
                    onTriggered: {
                        if (flight.flying && flight.mine && flight.phase === "morph" && flight.addr)
                            Morph.beginFade(flight.mid);
                    }
                }

                onToGXChanged: flight.retarget()

                onMineChanged: {
                    if (!flight.mine) {
                        // Migrated to another stage: freeze here so a stale
                        // loop can't finish later and drive the row's state
                        // out from under the stage that owns it now.
                        appearAnim.stop();
                        progSpring.stop();
                        fadeAnim.stop();
                        return;
                    }
                    if (flight.phase === "morph")
                        flight.startMorph();
                    else if (flight.phase === "fade")
                        flight.startFade();
                }

                onPhaseChanged: {
                    if (!flight.mine)
                        return;
                    // Deferred a tick: ListModel.set() notifies all changed
                    // roles at once, and the endpoint bindings must have
                    // settled before the flight reads them.
                    if (flight.phase === "morph")
                        Qt.callLater(() => flight.startMorph());
                    else if (flight.phase === "fade")
                        Qt.callLater(() => flight.startFade());
                }

                Component.onCompleted: {
                    if (!flight.mine)
                        return;
                    if (flight.phase === "morph")
                        flight.startMorph();
                    else if (flight.phase === "fade")
                        flight.startFade();
                }
            }
        }
    }
}
