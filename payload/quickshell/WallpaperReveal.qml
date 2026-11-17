import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs

// A wallpaper-only iris used to hide a coordinated theme commit.
//
// The shell writes ~/.cache/quickshell/wallpaper-reveal.json:
//   {"id": "...", "path": "/path/to/wall.jpg", "phase": "in"}
//   {"id": "...", "phase": "out"}
//
// The reveal is skwd-wall's drawing transition, started as soon as the new
// picture decodes: the old wallpaper becomes paper, an ink sketch of the new
// one draws itself in, then a liquid pour lands on the photo. It stays up
// while the palette and wallpaper commit underneath and fades back to the
// desktop when the apply finishes. The old iris grow remains only as the
// fallback for a picture that never decoded. The window is click-through and
// sits on the overlay layer, above the bar, dock and all normal windows.
//
// Cost model (what this file is shaped around):
//   * idle: nothing. The layer surface is unmapped, so the compositor does not
//     blend a fullscreen transparent layer over the desktop on every repaint.
//   * one decode per switch, not one per output: all screens ask the pixmap
//     cache for the same bounded size, and the decode happens off the GUI
//     thread. Before this, three synchronous native-size decodes (6666x3527 is
//     ~105 ms and ~90 MB each) ran inside beginReveal on the GUI thread.
//   * one fullscreen shader pass per animated frame, not two: the wallpaper is
//     rendered into the ShaderEffectSource once, after the decode, instead of
//     live:true re-rendering the image into an FBO on every frame.
//   * only visible frames are animated: the grow completes as soon as the
//     circle covers the screen, and the shrink starts where the circle first
//     touches a corner. Both skipped segments draw exactly the same pixels as
//     the frame before, so nothing visible changes; they were ~310 ms + ~380 ms
//     of frames that could not be seen.
PanelWindow {
    id: root

    required property var modelData

    screen: root.modelData
    color: "transparent"
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "lucid-wallpaper-reveal"
    mask: Region {
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    // An unmapped layer surface costs nothing. A mapped one is a fullscreen
    // alpha buffer the compositor blends into every desktop frame, even when
    // the iris is idle and fully transparent.
    visible: root.active

    Component.onCompleted: {
        // The shell script writes this before every palette swap; on a fresh
        // boot create it so Theme's FileView does not warn about a missing file.
        Quickshell.execDetached(["sh", "-c", "d=$HOME/.cache/quickshell; mkdir -p $d; [ -e $d/reveal-active ] || printf 0 > $d/reveal-active"]);
    }

    property string wallpaper: ""
    property string revealSource: ""
    property string lastId: ""
    property bool active: false
    readonly property real sw: screen ? screen.width : 1368
    readonly property real sh: screen ? screen.height : 912
    readonly property real coverRadius: (Math.hypot(sw / 2, sh / 2) + 2) * 1.25 * 1.25
    property bool pendingIn: false
    property bool concealRequested: false
    property bool completing: false
    readonly property string readyPath: Quickshell.env("HOME") + "/.cache/quickshell/reveal-ready"
    readonly property string coveredPath: Quickshell.env("HOME") + "/.cache/quickshell/reveal-covered"
    // The applying script rewrites this every half second while depth, matte,
    // mesh and the wallpaper decode are still running.
    readonly property string heartbeatPath: Quickshell.env("HOME") + "/.cache/quickshell/reveal-heartbeat"
    // the script's own 1/0 flag: 0 means it has sent the close (or given up)
    readonly property string activeFlagPath: Quickshell.env("HOME") + "/.cache/quickshell/reveal-active"
    property double heartbeatAt: 0
    // when this reveal began, for the hard deadline below
    property double begunAt: 0
    // Nothing may hold the screen under the iris forever. A wedged or killed
    // apply script, a heartbeat left writing by an older run, or a lost
    // "conceal" IPC used to leave the circle up with no way back. 90 s is
    // longer than the slowest cold apply (depth + matte + two meshes on a 4K
    // still, while the machine is busy); after that the iris closes whatever
    // the script is doing.
    readonly property int maxRevealMs: 90000

    // The circle travels from beyond the bottom-right corner to the centre.
    readonly property real startX: root.sw * 1.35
    readonly property real startY: root.sh * 1.35
    readonly property real endX: root.sw / 2
    readonly property real endY: root.sh / 2
    readonly property real outX: -root.sw * 0.45
    readonly property real outY: -root.sh * 0.45

    // Grow progress, already in eased space (0 = off-screen, 1 = covered).
    property real cover: 0
    // Fallback shrink time, 0..1; the InCubic easing is applied in `progress`.
    property real outT: 0
    // Drawing transition progress, 0..1, in skwd's own curve.
    property real drawT: 0
    property bool drawing: false
    // The picture on screen when the apply started (the previous target), so
    // the drawing opens on it instead of cutting to the new wallpaper.
    property string lastWallpaper: ""
    property string fromRevealSource: ""
    property bool useFrom: false
    // Only the output the user is looking at runs the animated shader. The
    // others hold a still cover; that is what keeps three 4K layers from
    // stalling the machine while the apply is working.
    property bool animateHere: true
    // Set when the apply has finished under the drawing; the pour is then
    // allowed to finish before the overlay fades out.
    property bool closeRequested: false
    property real closeFade: 0
    property bool leaving: false

    // One animator instead of three: the same single progress drives centre and
    // radius, so a frame writes one property and one uniform set.
    readonly property real progress: root.leaving ? root.outT * root.outT * root.outT : root.cover
    readonly property real cx: root.leaving ? root.endX + (root.outX - root.endX) * root.progress : root.startX + (root.endX - root.startX) * root.progress
    readonly property real cy: root.leaving ? root.endY + (root.outY - root.endY) * root.progress : root.startY + (root.endY - root.startY) * root.progress
    readonly property real radius: root.coverRadius * (root.leaving ? 1 - root.progress : root.progress)

    // The point in the shrink where the circle first stops covering a corner.
    // Everything before it is invisible, so the out animation starts here. The
    // solve is monotonic: the radius falls while the centre moves away from the
    // far corner.
    readonly property real tLeave: {
        var lo = 0;
        var hi = 1;
        for (var i = 0; i < 24; i++) {
            var s = (lo + hi) / 2;
            var x = root.endX + (root.outX - root.endX) * s;
            var y = root.endY + (root.outY - root.endY) * s;
            var r = root.coverRadius * (1 - s);
            var d = Math.max(Math.hypot(x, y), Math.hypot(root.sw - x, y), Math.hypot(x, root.sh - y), Math.hypot(root.sw - x, root.sh - y));
            if (r >= d + 2)
                lo = s;
            else
                hi = s;
        }
        return Math.pow(lo, 1 / 3);
    }

    // One decode size for every output. The pixmap cache is keyed by source and
    // sourceSize, so a shared size means one decode for three windows instead
    // of three decodes, and it bounds the texture at the physical screen size
    // instead of the wallpaper's native 6666x3527.
    readonly property size decodeSize: {
        var w = 0;
        var h = 0;
        for (var i = 0; i < Quickshell.screens.length; i++) {
            var s = Quickshell.screens[i];
            w = Math.max(w, Math.round(s.width * s.devicePixelRatio));
            h = Math.max(h, Math.round(s.height * s.devicePixelRatio));
        }
        // The iris is a transient cover; decoding a 4K wallpaper at full
        // physical size costs over a second before the circle can even start.
        // Cap the long side and let the GPU scale it during the animation.
        const cap = 2560;
        if (w > cap) {
            h = Math.round(h * cap / Math.max(1, w));
            w = cap;
        }
        return Qt.size(w || 1920, h || 1080);
    }

    function covered() {
        var d = Math.max(Math.hypot(root.cx, root.cy), Math.hypot(root.sw - root.cx, root.cy), Math.hypot(root.cx, root.sh - root.cy), Math.hypot(root.sw - root.cx, root.sh - root.cy));
        return root.radius >= d + 2;
    }

    function beginReveal(id, path) {
        // A duplicate IPC delivery for the same selection must not reset the
        // animation halfway through.
        if (root.active && root.lastId === id)
            return;
        // Stop the previous run's animators before reusing them.
        inAnim.stop();
        outAnim.stop();
        drawTicker.stop();
        closeTicker.stop();
        prepareTimer.stop();
        startDelayTimer.stop();
        coveredTimer.stop();
        holdTimer.stop();

        // The picture on screen right now becomes the drawing's paper source.
        // That is the target of the previous reveal; a fresh shell has none,
        // and then the drawing starts from the new picture itself.
        const previous = root.lastWallpaper;
        const wasDrawing = root.drawing && root.active;
        root.lastWallpaper = path || "";
        // The shell maps a single reveal surface (see shell.qml: three
        // fullscreen Vulkan layers crashed the NVIDIA driver), so it is
        // always the one running the drawing. The old per-focus check meant
        // that applying from another monitor ran no animation at all and
        // never announced ready/covered.
        root.animateHere = true;

        root.lastId = id;
        Theme.revealActive = true;
        root.wallpaper = path || "";
        root.active = true;
        root.pendingIn = true;
        root.concealRequested = false;
        root.closeRequested = false;
        root.closeFade = 0;
        root.heartbeatAt = Date.now();
        root.begunAt = Date.now();
        root.leaving = false;
        root.cover = 0;
        root.outT = 0;
        // A new pick during a drawing must not make the overlay transparent
        // while the new picture decodes. Hold the finished frame; it is the
        // previous target, which is also the new drawing's first frame.
        root.drawing = wasDrawing && root.animateHere;
        root.drawT = wasDrawing && root.animateHere ? 1 : 0;
        root.drawStartAt = 0;
        root.useFrom = false;
        root.fromRevealSource = "";
        if (previous && previous !== path)
            root.fromRevealSource = "file://" + encodeURI(previous);

        Quickshell.execDetached(["sh", "-c", "rm -f \"$0\" \"$1\"", root.readyPath, root.coveredPath]);
        // Force the Image through Null/Loading so a Ready status from the
        // previous wallpaper cannot start the new animation early. The decode
        // is asynchronous; startDraw runs from the status handler once the
        // texture exists.
        root.revealSource = "";
        root.revealSource = "file://" + encodeURI(root.wallpaper);
        if (image.status === Image.Ready)
            Qt.callLater(root.imageReady);
    }

    function imageReady() {
        if (image.status !== Image.Ready)
            return;
        // Render the wallpaper into its FBO once; it is static for the whole
        // reveal, so there is no reason to re-render it every frame.
        // Only the animated output samples this texture; the still covers on
        // the other outputs would otherwise pay for a full-screen grab each.
        if (root.animateHere)
            wallpaperSource.scheduleUpdate();
        if (!root.pendingIn)
            return;
        if (!root.animateHere) {
            root.pendingIn = false;
            root.drawing = false;
            root.drawT = 0;
            return ;
        }
        prepareTimer.restart();
    }

    // Start the drawing as soon as the new picture exists. It is the cover
    // now, not a closing flourish: the overlay is opaque from its first frame
    // and the commit happens underneath it.
    function startDraw() {
        if (!root.pendingIn || !root.active)
            return;
        root.pendingIn = false;
        root.drawing = true;
        root.drawT = 0;
        // A conceal that arrived before the decode (a failed apply closing
        // early) must still let the drawing play out, then close.
        if (root.concealRequested)
            root.closeRequested = true;
        root.drawStartAt = Date.now();
        root.drawT = 0;
        drawTicker.start();
    }

    // Fallback when the picture never decoded: the old iris grow, which can
    // still cover the commit and then shrink away.
    function startGrow() {
        if (!root.pendingIn)
            return;
        root.pendingIn = false;
        if (!root.animateHere)
            return ;
        root.drawing = false;
        root.cover = 0;
        Quickshell.execDetached(["sh", "-c", "touch \"$0\"", root.readyPath]);
        inAnim.restart();
    }

    function startOut() {
        if (root.leaving)
            return;
        if (!root.animateHere) {
            root.startClose();
            return;
        }
        if (root.drawing) {
            // A commit that already arrived lets the drawing finish; only a
            // silent apply is closed on top of whatever frame it is showing.
            if (drawTicker.running && root.closeRequested)
                return ;
            root.startClose();
            return;
        }
        root.leaving = true;
        root.outT = root.tLeave;
        outAnim.restart();
    }

    // Crossfade the finished drawing back to the live desktop. For a still
    // that is the same picture; for a scene it blends the preview frame into
    // the running scene instead of cutting.
    function startClose() {
        if (root.leaving)
            return;
        root.leaving = true;
        root.closeStartAt = Date.now();
        root.closeFade = 0;
        closeTicker.start();
    }

    // The last word: drop the overlay without waiting for any animation. Used
    // by the deadline when the normal close never arrived, so a broken
    // animation cannot keep the screen covered either.
    function forceClose() {
        inAnim.stop();
        outAnim.stop();
        drawTicker.stop();
        closeTicker.stop();
        prepareTimer.stop();
        startDelayTimer.stop();
        coveredTimer.stop();
        holdTimer.stop();
        root.pendingIn = false;
        root.concealRequested = false;
        root.closeRequested = false;
        root.completing = false;
        root.leaving = false;
        root.drawing = false;
        root.drawT = 0;
        root.closeFade = 0;
        root.cover = 0;
        root.outT = 0;
        root.wallpaper = "";
        root.fromRevealSource = "";
        root.useFrom = false;
        root.revealSource = "";
        Theme.revealActive = false;
        root.active = false;
    }

    function endReveal(id) {
        if (id !== root.lastId || !root.active)
            return;
        if (!root.animateHere) {
            root.closeRequested = true;
            root.startClose();
            return;
        }
        // The drawing is the cover now. If the commit lands while it is still
        // playing, let the pour finish before fading out; if it is still
        // decoding, defer as before.
        if (root.drawing) {
            root.closeRequested = true;
            if (!drawTicker.running)
                root.startClose();
            return;
        }
        if (root.pendingIn || inAnim.running) {
            root.concealRequested = true;
            return;
        }
        root.startOut();
    }

    NumberAnimation {
        id: inAnim

        target: root
        property: "cover"
        from: 0
        to: 1
        duration: 700
        easing.type: Easing.OutCubic

        // The moment the last corner is covered the remaining easing only moves
        // the edge further off-screen. Jump to the end so the covered marker is
        // touched (and the palette commit can start) without drawing frames
        // that cannot change a pixel.
        onFinished: {
            Quickshell.execDetached(["sh", "-c", "touch \"$0\"", root.coveredPath]);
            if (root.concealRequested) {
                root.concealRequested = false;
                holdTimer.start();
            }
        }
    }

    onCoverChanged: {
        if (!root.leaving && !root.completing && inAnim.running && root.covered()) {
            root.completing = true;
            inAnim.complete();
            root.completing = false;
        }
    }

    // The overlay is up as soon as the drawing paints. "covered" is held back
    // until the drawing has finished: it gates the palette and depth work,
    // and that work blocks the shell's event loop for over a second. Under
    // the finished frame that stall is invisible; during the animation it is
    // a visible freeze.
    Timer {
        id: coveredTimer

        interval: 60
        repeat: false
        onTriggered: Quickshell.execDetached(["sh", "-c", "touch \"$0\"", root.readyPath])
    }

    Timer {
        id: holdTimer

        interval: 50
        repeat: false
        onTriggered: {
            if (root.active && !outAnim.running)
                root.startOut();
        }
    }

    NumberAnimation {
        id: outAnim

        target: root
        property: "outT"
        from: root.tLeave
        to: 1
        // The tail of the original 700 ms InCubic, so the edge moves at exactly
        // the same speed; the invisible lead-in is simply not animated.
        duration: Math.max(1, (1 - root.tLeave) * 700)
        easing.type: Easing.Linear
        onFinished: root.forceClose()
    }

    // skwd-wall's drawing transition, driven at 30 Hz: the reveal is a
    // full-screen shader on every output, and this now runs while the apply
    // is using the machine. A pencil drawing does not need 60 fps, and
    // halving the frames is what keeps it smooth under that load. Progress is
    // read from the clock, so a late tick never stretches the animation.
    readonly property int drawMs: 3000
    property double drawStartAt: 0

    Timer {
        id: drawTicker

        interval: 33
        repeat: true
        running: false
        onTriggered: {
            var now = Date.now();
            var p = Math.min(1, (now - root.drawStartAt) / root.drawMs);
            root.drawT = p;
            if (p < 1)
                return ;
            drawTicker.stop();
            // The apply's mode detection, palette, depth and wallpaper work
            // all start here, on the finished frame. None of it can stall the
            // drawing because the drawing is over.
            Quickshell.execDetached(["sh", "-c", "touch \"$0\" \"$1\"", root.readyPath, root.coveredPath]);
            // Hold the finished photo until the apply commits; when it has
            // already finished, close now.
            if (root.closeRequested)
                root.startClose();
        }
    }

    // Give the wallpaper its FBO frame, then bake the sketch and the stroke
    // order before the animated pass needs them (the first 8 % only shows the
    // old picture fading to paper).
    Timer {
        id: prepareTimer

        interval: 80
        repeat: false
        onTriggered: {
            if (!root.pendingIn)
                return ;
            sketchSource.scheduleUpdate();
            root.useFrom = root.fromRevealSource !== "" && fromImage.status === Image.Ready;
            if (root.useFrom)
                fromSource.scheduleUpdate();
            startDelayTimer.restart();
        }
    }

    // The sketch grab, and on the first apply of a shell session the shader
    // pipelines and FBOs, are created here. Holding the drawing back for a
    // few frames keeps that cost out of the first visible frames.
    Timer {
        id: startDelayTimer

        interval: 120
        repeat: false
        onTriggered: root.startDraw()
    }

    // The only way the drawing leaves the screen: a short crossfade, never a
    // cut, because the last frame is the new wallpaper. Driven at 30 Hz like
    // the drawing: a 180 ms fade is six frames, not thirty at 165 Hz.
    readonly property int closeMs: 180
    property double closeStartAt: 0

    Timer {
        id: closeTicker

        interval: 33
        repeat: true
        running: false
        onTriggered: {
            var p = Math.min(1, (Date.now() - root.closeStartAt) / root.closeMs);
            root.closeFade = p;
            if (p < 1)
                return ;
            closeTicker.stop();
            root.forceClose();
        }
    }

    // A watchdog so a lost "out" event cannot leave the screen covered. It
    // only fires once the applying script has gone quiet: a cold wallpaper
    // spends several seconds in depth/matte/mesh and decode, and closing the
    // iris on a fixed timeout made the picture land after the circle had gone.
    Timer {
        interval: 1000
        repeat: true
        running: root.active && !root.leaving
        onTriggered: {
            if (!root.active || root.leaving)
                return ;
            if (root.heartbeatAt > 0 && Date.now() - root.heartbeatAt < 2500)
                return ;
            // The apply has already reported completion; the drawing is
            // finishing on its own. Only a silent apply is force-closed.
            if (root.closeRequested)
                return ;
            console.log("REVEAL watchdog: no heartbeat, closing");
            root.startOut();
        }
    }

    FileView {
        path: root.heartbeatPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.heartbeatAt = Date.now()
    }

    // The script sets its flag to 0 as it sends "out". If that IPC was lost or
    // overtaken, this is the same news: close now, instead of waiting for the
    // watchdog. Only once its heartbeat has stopped, so an older apply
    // finishing under a newer reveal cannot close the newer circle.
    FileView {
        path: root.activeFlagPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            if (root.active && !root.leaving && !root.closeRequested
                    && text().trim() === "0" && Date.now() - root.heartbeatAt > 1500)
                root.startOut();
        }
    }

    // Hard deadline: see maxRevealMs. Independent of the heartbeat, so a
    // writer that never stops cannot hold the screen under the iris forever.
    Timer {
        interval: 1000
        repeat: true
        running: root.active
        onTriggered: {
            if (!root.active || Date.now() - root.begunAt < root.maxRevealMs)
                return ;
            console.warn("REVEAL deadline: closing after " + root.maxRevealMs + " ms");
            root.forceClose();
        }
    }

    Image {
        id: image

        x: 0
        y: 0
        width: root.sw
        height: root.sh
        source: root.revealSource
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize: root.decodeSize
        visible: false
        onStatusChanged: {
            if (status === Image.Ready)
                root.imageReady();
            else if (status === Image.Error && root.pendingIn)
                root.startGrow();
        }
    }

    ShaderEffectSource {
        id: wallpaperSource

        sourceItem: image
        hideSource: true
        live: false
        recursive: false
    }

    // The previous picture, kept as the drawing's paper source. A second Image
    // is needed: the main one is reused for the new picture, and the
    // ShaderEffectSource only refreshes when told to.
    Image {
        id: fromImage

        x: 0
        y: 0
        width: root.sw
        height: root.sh
        source: root.fromRevealSource !== "" ? root.fromRevealSource : root.revealSource
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize: root.decodeSize
        // On the animated output this is hidden and sampled as a texture; on
        // the others it is the still cover that holds the old picture.
        visible: root.active && !root.animateHere
        opacity: 1 - root.closeFade
        onStatusChanged: {
            if (status === Image.Ready)
                fromSource.scheduleUpdate();
        }
    }

    ShaderEffectSource {
        id: fromSource

        sourceItem: fromImage
        hideSource: root.animateHere
        live: false
        recursive: false
    }

    // The sketch is baked once per apply: the animated pass then only samples
    // it instead of re-running the line extraction and e-ink paper work on
    // every frame. It is baked 1:1 with the screen: the XDoG lines are already
    // soft-edged, and a smaller bake only made the drawing look lower
    // resolution than the wallpaper it sits on.
    ShaderEffect {
        id: inkSketch

        x: 0
        y: 0
        width: root.sw
        height: root.sh
        visible: true
        property variant wallpaperTex: wallpaperSource
        property vector2d itemSize: Qt.vector2d(width, height)
        property vector2d screenSize: Qt.vector2d(root.sw, root.sh)
        fragmentShader: Qt.resolvedUrl("wallpaper_sketch.frag.qsb")
    }

    ShaderEffectSource {
        id: sketchSource

        sourceItem: inkSketch
        hideSource: true
        live: false
        recursive: false
    }

    ShaderEffect {
        x: 0
        y: 0
        width: root.sw
        height: root.sh
        visible: root.active && !root.drawing
        property variant wallpaperTex: wallpaperSource
        property vector2d itemSize: Qt.vector2d(root.sw, root.sh)
        property vector2d center: Qt.vector2d(root.cx, root.cy)
        property real radius: root.radius
        fragmentShader: Qt.resolvedUrl("wallpaper_circle.frag.qsb")
    }

    // The reveal itself. It opens on the picture that was on screen, turns it
    // into paper, draws the ink sketch of the new one, then pours the photo.
    ShaderEffect {
        x: 0
        y: 0
        width: root.sw
        height: root.sh
        visible: root.active && root.drawing
        opacity: root.drawing ? 1 - root.closeFade : 1
        property variant wallpaperTex: wallpaperSource
        property variant fromTex: root.useFrom ? fromSource : wallpaperSource
        property variant sketchTex: sketchSource
        property vector2d itemSize: Qt.vector2d(root.sw, root.sh)
        property vector2d drawFocus: Qt.vector2d(0.5, 0.5)
        property real stage: root.drawT
        // The e-ink palette from reading_mode.glsl.
        property vector4d paper: Qt.vector4d(0.743922, 0.723922, 0.663922, 1.0)
        property vector4d ink: Qt.vector4d(0.10, 0.10, 0.12, 1.0)
        fragmentShader: Qt.resolvedUrl("wallpaper_drawing.frag.qsb")
    }

}
