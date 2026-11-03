import QtMultimedia
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs

// One screen's depth-parallax surface. It is drawn on the Background layer
// below widgets, so widget glass blurs the moving wallpaper and every widget
// keeps its own input without a clipping overlay.
Item {
    id: surface

    required property var screen
    property bool foregroundOnly: false
    // Off for a widget cutout with no widgets on screen, so it does not build
    // a mesh nobody can see.
    property bool renderingEnabled: true
    readonly property real devicePixelRatio: screen ? Math.max(1, Number(screen.devicePixelRatio || 1)) : 1
    readonly property size textureSize: Qt.size(
        Math.max(1, Math.round(width * surface.devicePixelRatio)),
        Math.max(1, Math.round(height * surface.devicePixelRatio)))
    readonly property bool pointerHere: {
        if (!SpatialPointer.valid || !surface.screen)
            return false;
        return SpatialPointer.x >= surface.screen.x
            && SpatialPointer.x < surface.screen.x + surface.screen.width
            && SpatialPointer.y >= surface.screen.y
            && SpatialPointer.y < surface.screen.y + surface.screen.height;
    }
    // True while the pointer is over a mapped client window: the wallpaper
    // should not swing toward it there, only its own passive motion should
    // continue. Widgets are layer surfaces, not clients, so they keep the
    // parallax.
    function windowAt(px, py) {
        if (!surface.screen || !Hyprland.toplevels)
            return false;
        const monitor = Hyprland.monitorFor(surface.screen);
        const spaces = [];
        if (monitor && monitor.activeWorkspace)
            spaces.push(monitor.activeWorkspace);
        const special = monitor && monitor.lastIpcObject && monitor.lastIpcObject.specialWorkspace
            ? String(monitor.lastIpcObject.specialWorkspace.name || "") : "";
        if (special !== "") {
            for (const ws of Hyprland.workspaces.values) {
                if (ws.name === special)
                    spaces.push(ws);
            }
        }
        // hyprctl reports window geometry in the same logical layout space as
        // the cursor position and the screen rects
        for (const ws of spaces) {
            if (!ws || !ws.toplevels)
                continue;
            for (const toplevel of ws.toplevels.values) {
                const info = toplevel.lastIpcObject;
                if (!info || !info.at || !info.size || info.hidden || info.mapped === false)
                    continue;
                const x = info.at[0] - surface.screen.x;
                const y = info.at[1] - surface.screen.y;
                const w = info.size[0];
                const h = info.size[1];
                if (px >= x && px < x + w && py >= y && py < y + h)
                    return true;
            }
        }
        return false;
    }
    readonly property bool pointerOverWindow: {
        if (!surface.pointerHere)
            return false;
        return surface.windowAt(SpatialPointer.x - surface.screen.x,
            SpatialPointer.y - surface.screen.y);
    }
    // How much of the pointer's travel the camera follows. The idle circle is
    // added later, so this only scales the cursor's own influence.
    readonly property real pointerGain: 0.33
    readonly property real rawPointerX: {
        if (!surface.pointerHere || surface.pointerOverWindow)
            return 0;
        const center = (SpatialPointer.x - surface.screen.x) / Math.max(1, surface.screen.width);
        return surface.pointerGain * Math.max(-1, Math.min(1, center * 2 - 1));
    }
    readonly property real rawPointerY: {
        if (!surface.pointerHere || surface.pointerOverWindow)
            return 0;
        const center = (SpatialPointer.y - surface.screen.y) / Math.max(1, surface.screen.height);
        return surface.pointerGain * Math.max(-1, Math.min(1, center * 2 - 1));
    }
    // The renderer's own eased coordinate, not the cursor service's 30 Hz grid,
    // is what the shader sees. This keeps small movement smooth.
    // Cross-fade the whole 3D visual over the flat wallpaper. Applied to the
    // outputs rather than the surface itself: animating the layer window's
    // root opacity crashes Quickshell here.
    property real visualFade: SpatialWall.visualVisible ? 1 : 0
    property real pointerX: 0
    property real pointerY: 0
    Behavior on visualFade {
        // Fade in gently when the new mesh is committed, but take the old
        // wallpaper off screen fast when the selection moves: the iris opens
        // within ~400 ms of the apply, and a 450 ms fade-out was still showing
        // the previous picture over the new flat wallpaper.
        NumberAnimation {
            duration: SpatialWall.visualVisible ? 450 : 90
            easing.type: Easing.OutCubic
        }
    }
    Behavior on pointerX {
        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
    }
    Behavior on pointerY {
        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
    }
    onRawPointerXChanged: surface.pointerX = surface.rawPointerX
    onRawPointerYChanged: surface.pointerY = surface.rawPointerY
    Component.onCompleted: {
        surface.pointerX = surface.rawPointerX;
        surface.pointerY = surface.rawPointerY;
        surface.syncVideo();
        if (!surface.foregroundOnly && surface.screen)
            SpatialWall.reportSurface(surface.screen.name, surface.visualReady);
    }

    function syncVideo() {
        if (mesh3d.item)
            surface.syncMesh();
        if (SpatialWall.motionKind === "video" && SpatialWall.motionPath !== "" && SpatialWall.hasVisual) {
            if (player.source.toString() !== SpatialWall.motionUrl)
                player.source = SpatialWall.motionUrl;
            player.play();
        } else {
            player.pause();
            player.source = "";
        }
    }

    readonly property bool useStill: surface.foregroundOnly || SpatialWall.motionKind === "image"
    readonly property bool wantVideo: !surface.foregroundOnly && SpatialWall.motionKind === "video"
    readonly property bool wantGif: !surface.foregroundOnly && SpatialWall.motionKind === "gif"
    readonly property bool videoReady: !wantVideo || player.mediaStatus === MediaPlayer.BufferedMedia
        || player.mediaStatus === MediaPlayer.BufferingMedia
        || player.mediaStatus === MediaPlayer.LoadedMedia
    readonly property bool meshReady: mesh3d.item !== null && mesh3d.item.ready
    property bool meshFailed: false
    property int meshRetries: 0
    readonly property bool layeredImagesReady: SpatialWall.layeredVisual
        && backgroundMap.status === Image.Ready
        && matteMap.status === Image.Ready
        && influenceMap.status === Image.Ready
    readonly property bool visualReady: SpatialWall.hasVisual
        && ((mesh3d.active && !surface.meshFailed) ? surface.meshReady : surface.sourceReady)
    readonly property bool sourceReady: depthMap.status === Image.Ready
        && (surface.useStill ? still.status === Image.Ready
            : (wantGif ? animated.status === Image.Ready : videoReady))
        && (!SpatialWall.layeredVisual || (matteMap.status === Image.Ready
            && (surface.foregroundOnly || surface.layeredImagesReady)))

    Item {
        id: media

        anchors.fill: parent
        // ShaderEffectSource still needs the item rendered; hideSource keeps
        // the un-shaded copy from painting on top of the shader.
        visible: surface.renderingEnabled

        Image {
            id: still

            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            source: surface.useStill
                ? (surface.foregroundOnly ? SpatialWall.posterUrl : SpatialWall.motionUrl) : ""
            sourceSize: surface.textureSize
            asynchronous: true
            cache: true
            visible: surface.useStill
            onStatusChanged: {
                if (status === Image.Ready && motionTexture)
                    motionTexture.scheduleUpdate();
            }
        }

        AnimatedImage {
            id: animated

            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            source: SpatialWall.motionKind === "gif" ? SpatialWall.motionUrl : ""
            sourceSize: surface.textureSize
            asynchronous: true
            cache: false
            playing: SpatialWall.hasVisual && SpatialWall.motionKind === "gif"
            visible: SpatialWall.motionKind === "gif"
        }

        MediaPlayer {
            id: player

            loops: MediaPlayer.Infinite
            videoOutput: videoOut
            audioOutput: AudioOutput {
                muted: true
            }
            onErrorOccurred: (error, message) => console.warn("spatial-wall:", message)
        }

        VideoOutput {
            id: videoOut

            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectCrop
            visible: SpatialWall.motionKind === "video"
        }

    }

    ShaderEffectSource {
        id: motionTexture

        sourceItem: media
        hideSource: true
        // animated sources repaint continuously; a still is captured once
        live: surface.wantGif || surface.wantVideo
        smooth: true
        textureSize: surface.textureSize
        visible: false
    }

    Image {
        id: depthMap

        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        source: SpatialWall.depthUrl
        sourceSize: surface.textureSize
        asynchronous: true
        cache: true
        visible: false
    }

    Image {
        id: backgroundMap

        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        source: SpatialWall.backgroundUrl
        sourceSize: surface.textureSize
        asynchronous: true
        cache: true
        visible: false
    }

    Image {
        id: matteMap

        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        source: SpatialWall.matteUrl
        sourceSize: surface.textureSize
        asynchronous: true
        cache: true
        visible: false
    }

    Image {
        id: influenceMap

        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        source: SpatialWall.influenceUrl
        sourceSize: surface.textureSize
        asynchronous: true
        cache: true
        visible: false
    }

    // True depth mesh for stills. Videos and Workshop scenes keep the layered
    // shader because the mesh is built from one still depth map.
    Loader {
        id: mesh3d

        anchors.fill: parent
        active: surface.renderingEnabled && SpatialWall.layeredVisual
            && (!surface.foregroundOnly || SpatialWall.sourceKind !== "video")
        source: "DepthWallpaper3D.qml"
        onLoaded: {
            surface.meshFailed = false;
            surface.meshRetries = 0;
            surface.syncMesh();
        }
        onStatusChanged: {
            if (status === Loader.Error) {
                surface.meshFailed = true;
                console.warn("spatial-wall: 3D mesh unavailable; using layered shader");
                // A reload during a live edit can leave the component in an
                // error state; try twice before settling on the fallback.
                if (surface.meshRetries < 2) {
                    surface.meshRetries++;
                    meshRetry.restart();
                }
            }
        }
    }

    Timer {
        id: meshRetry

        interval: 800
        repeat: false
        onTriggered: {
            mesh3d.active = false;
            mesh3d.active = true;
        }
    }

    function syncMesh() {
        if (!mesh3d.item)
            return ;
        // Geometry rebuilds on depthPath/mattePath. Set the size hints before
        // them so the first build already has the final aspect and no second
        // build is spent correcting it.
        mesh3d.item.outputAspect = surface.width > 0 && surface.height > 0
            ? surface.width / surface.height : 16 / 9;
        mesh3d.item.knownSourceAspect = SpatialWall.sourceWidth > 0
            && SpatialWall.sourceHeight > 0
            ? SpatialWall.sourceWidth / SpatialWall.sourceHeight : 0;
        mesh3d.item.liveSource = surface.foregroundOnly
            ? null
            : (SpatialWall.motionKind === "video" ? videoOut
                : (SpatialWall.motionKind === "gif" ? animated : null));
        mesh3d.item.wallpaperPath = SpatialWall.motionUrl;
        mesh3d.item.backgroundPath = SpatialWall.backgroundUrl;
        mesh3d.item.foregroundOnly = surface.foregroundOnly;
        mesh3d.item.mattePath = SpatialWall.matteUrl;
        mesh3d.item.depthPath = SpatialWall.depthUrl;
        mesh3d.item.textureSize = surface.textureSize;
        mesh3d.item.pointerX = surface.pointerX;
        mesh3d.item.pointerY = surface.pointerY;
    }
    onVisualReadyChanged: {
        if (!surface.foregroundOnly && surface.screen)
            SpatialWall.reportSurface(surface.screen.name, surface.visualReady);
    }
    onMeshReadyChanged: {
        if (!surface.foregroundOnly && surface.screen)
            SpatialWall.reportSurface(surface.screen.name, surface.visualReady);
    }
    onSourceReadyChanged: {
        if (!surface.foregroundOnly && surface.screen)
            SpatialWall.reportSurface(surface.screen.name, surface.visualReady);
    }
    onWidthChanged: surface.syncMesh()
    onHeightChanged: surface.syncMesh()
    onVisualFadeChanged: surface.syncMesh()
    onPointerXChanged: surface.syncMesh()
    onPointerYChanged: surface.syncMesh()

    ShaderEffect {
        anchors.fill: parent
        visible: surface.renderingEnabled && SpatialWall.hasVisual && !SpatialWall.layeredVisual
            && surface.sourceReady && motionTexture.sourceItem !== null
        // The QML source and depth are already aspect-cropped to this surface,
        // so the shader's cropScale is 1; its small inset is the overscan that
        // keeps a parallax edge from ever revealing empty texture.
        property variant source: motionTexture
        property variant depthMap: depthMap
        property vector2d pointer: Qt.vector2d(
            Math.max(-1, Math.min(1, surface.pointerX + SpatialShake.lookX)),
            Math.max(-1, Math.min(1, surface.pointerY + SpatialShake.lookY)))
        property vector2d cropScale: Qt.vector2d(1, 1)
        property real fade: surface.visualFade
        fragmentShader: Qt.resolvedUrl("luciddocks/shaders/spatial_parallax.frag.qsb")
    }

    ShaderEffect {
        anchors.fill: parent
        visible: surface.renderingEnabled && SpatialWall.layeredVisual && !surface.meshReady
            && surface.sourceReady && motionTexture.sourceItem !== null
        property variant source: motionTexture
        property variant background: backgroundMap
        property variant matte: matteMap
        property variant influence: influenceMap
        property variant depthMap: depthMap
        property vector2d pointer: Qt.vector2d(
            Math.max(-1, Math.min(1, surface.pointerX + SpatialShake.lookX)),
            Math.max(-1, Math.min(1, surface.pointerY + SpatialShake.lookY)))
        property vector2d cropScale: Qt.vector2d(1, 1)
        property real foregroundOnly: surface.foregroundOnly ? 1 : 0
        property real fade: surface.visualFade
        fragmentShader: Qt.resolvedUrl("luciddocks/shaders/spatial_layered.frag.qsb")
    }

    Connections {
        target: SpatialWall

        function onMotionKindChanged() {
            surface.syncVideo();
            motionTexture.scheduleUpdate();
        }
        function onMotionPathChanged() {
            surface.syncVideo();
            motionTexture.scheduleUpdate();
        }
        function onReadyChanged() {
            surface.syncVideo();
            motionTexture.scheduleUpdate();
            surface.syncMesh();
            if (!surface.foregroundOnly && surface.screen)
                SpatialWall.reportSurface(surface.screen.name, surface.visualReady);
        }
        function onLayeredReadyChanged() { surface.syncMesh(); }
        function onDepthPathChanged() { surface.syncMesh(); }
        function onBackgroundPathChanged() { surface.syncMesh(); }
        function onMattePathChanged() { surface.syncMesh(); }
        function onInfluencePathChanged() { surface.syncMesh(); }
        function onSourceWidthChanged() { surface.syncMesh(); }
        function onSourceHeightChanged() { surface.syncMesh(); }
        function onRenderPathChanged() {
            if (!surface.foregroundOnly && surface.screen)
                SpatialWall.reportSurface(surface.screen.name, surface.visualReady);
        }
        // a commit that leaves renderPath unchanged still bumps the revision;
        // the surfaces re-assert readiness so a cleared map can never stick
        function onSurfaceRevisionChanged() {
            if (!surface.foregroundOnly && surface.screen)
                SpatialWall.reportSurface(surface.screen.name, surface.visualReady);
        }
    }

    IpcHandler {
        target: "spatial-wall-" + (surface.screen ? surface.screen.name : "unknown")
            + (surface.foregroundOnly ? "-fg" : "")

        // test/support hook: warm a wallpaper's spatial cache from the picker
        function prewarm(path: string): string {
            SpatialWall.prewarm(path);
            return JSON.stringify({
                "path": path,
                "busy": SpatialWall.prewarmBusy,
                "target": SpatialWall.prewarmPath
            });
        }

        function prewarmState(): string {
            return JSON.stringify({
                "busy": SpatialWall.prewarmBusy,
                "target": SpatialWall.prewarmPath,
                "next": SpatialWall.prewarmNext,
                "done": Object.keys(SpatialWall.prewarmDone).length
            });
        }

        // test hook: is this screen-local point over a client window?
        function covered(px: real, py: real): string {
            return JSON.stringify({
                "at": [px, py],
                "covered": surface.windowAt(px, py)
            });
        }

        function snapshot(): string {
            return JSON.stringify({
                visible: SpatialWall.hasVisual,
                kind: SpatialWall.motionKind,
                motion: SpatialWall.motionPath,
                poster: SpatialWall.posterPath,
                depth: SpatialWall.depthPath,
                layered: SpatialWall.layeredReady,
                mesh: surface.meshReady,
                meshStatus: mesh3d.status,
                sourcePath: SpatialWall.sourcePath,
                renderPath: SpatialWall.renderPath,
                readyFlag: SpatialWall.ready,
                revealReady: SpatialWall.revealReady,
                surfaces: SpatialWall.surfaceReady,
                surfaceReports: SpatialWall.surfaceReportCount,
                segmentation: SpatialWall.segmentation,
                background: SpatialWall.backgroundPath,
                matte: SpatialWall.mattePath,
                influence: SpatialWall.influencePath,
                status: SpatialWall.status,
                error: SpatialWall.error,
                pointerX: surface.pointerX,
                pointerY: surface.pointerY,
                overWindow: surface.pointerOverWindow,
                visualVisible: SpatialWall.visualVisible,
                renderPath: SpatialWall.renderPath,
                lookX: SpatialShake.lookX,
                lookY: SpatialShake.lookY,
                shake: [SpatialShake.x, SpatialShake.y, SpatialShake.z],
                pointerHere: surface.pointerHere,
                pointer: [SpatialPointer.x, SpatialPointer.y],
                monName: Hyprland.monitorFor(surface.screen) ? Hyprland.monitorFor(surface.screen).name : "",
                monWs: Hyprland.monitorFor(surface.screen) && Hyprland.monitorFor(surface.screen).activeWorkspace
                    ? Hyprland.monitorFor(surface.screen).activeWorkspace.id : -1,
                monIpcWs: Hyprland.monitorFor(surface.screen) && Hyprland.monitorFor(surface.screen).lastIpcObject
                    && Hyprland.monitorFor(surface.screen).lastIpcObject.activeWorkspace
                    ? Hyprland.monitorFor(surface.screen).lastIpcObject.activeWorkspace.id : -1,
                windowCount: Hyprland.monitorFor(surface.screen) && Hyprland.monitorFor(surface.screen).activeWorkspace
                    && Hyprland.monitorFor(surface.screen).activeWorkspace.toplevels
                    ? Hyprland.monitorFor(surface.screen).activeWorkspace.toplevels.values.length : -1,
                screenRect: surface.screen ? [surface.screen.x, surface.screen.y, surface.screen.width, surface.screen.height] : []
            });
        }
    }

    // hyprctl keeps toplevel geometry until something asks for a refresh; the
    // underlay and the active-window widget already do this, but the pointer
    // gate above must not lag behind a window being opened or moved.
    Connections {
        target: Hyprland
        enabled: !surface.foregroundOnly

        function onRawEvent(event) {
            switch (event.name) {
            case "openwindow":
            case "closewindow":
            case "movewindow":
            case "movewindowv2":
            case "workspace":
            case "workspacev2":
            case "activespecial":
            case "activespecialv2":
            case "fullscreen":
            case "changefloatingmode":
                windowRefresh.restart();
                break;
            }
        }
    }

    Timer {
        id: windowRefresh

        interval: 16
        repeat: false
        onTriggered: Hyprland.refreshToplevels()
    }
}
