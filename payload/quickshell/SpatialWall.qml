import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs
pragma Singleton

// Local depth parallax for every wallpaper Lucid can show. A small Python
// worker (depth-engine.py) owns the Depth Anything V2 ONNX session and the
// 16-bit cache; this singleton only decides which image to sample, starts one
// request at a time, and publishes the paths to the background renderer.
//
// Moving wallpapers use the same depth map as their poster frame. Video keeps
// playing in the renderer; Workshop scenes use Lucid's 10s background-only
// recording when it exists, otherwise the author's animated preview. Widgets
// stay above this Background-layer surface, so their glass blurs the parallax
// without any extra clipping path.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string assetsScript: home + "/.config/quickshell/luciddocks/spatial-assets.py"
    readonly property string depthScript: home + "/.config/quickshell/luciddocks/depth-engine.py"
    readonly property string prepScript: home + "/.config/quickshell/luciddocks/spatial-prep.py"
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
    readonly property string progressPath: runtimeDir + "/lucid-spatial-depth.json"
    readonly property string pauseMarker: runtimeDir + "/lucid-spatial-paused"
    readonly property string readyFile: runtimeDir + "/lucid-spatial-ready.json"
    readonly property string requestFile: runtimeDir + "/lucid-spatial-request.json"
    // Wallpaper Engine scenes stay on skwd's own live renderer. Their motion
    // needs per-frame depth to follow it, which cannot run at 60 fps here, and
    // a static depth over the recording was worse than the scene itself.
    readonly property bool isScene: root.sourcePath.indexOf("skwd:we:") === 0
        || root.sourcePath.indexOf("/431960/") !== -1
        || (root.entry && String(root.entry.kind || "") === "we")
    readonly property bool enabled: Prefs.spatialWallpapers && !root.isScene

    readonly property string currentPath: {
        if (SkwdWall.enabled)
            return SkwdWall.currentPath;
        return LiveWall.video !== "" ? LiveWall.video : LiveWall.picture;
    }
    property string requestedPath: ""
    property string requestedToken: ""
    property double requestedAt: 0
    // The last request file token already staged. FileView emits onLoaded for
    // its initial read and again for every watched change; processing the same
    // token twice would restart staging and clear the surface-ready map.
    property string stagedToken: ""
    readonly property string sourcePath: root.requestedPath !== "" ? root.requestedPath : root.currentPath
    readonly property var entry: SkwdWall.entryForPath(root.sourcePath)
    readonly property string currentKey: {
        if (root.sourcePath.indexOf("skwd:we:") === 0)
            return root.sourcePath.substring(5);
        if (root.entry && root.entry.key)
            return String(root.entry.key);
        return root.sourcePath;
    }
    readonly property var liveEntry: {
        const map = SkwdWall.livePreviews || {};
        return map[root.currentKey] || map[root.sourcePath] || ({});
    }

    property int generation: 0
    property int depthGeneration: 0
    property var assets: ({})
    property string motionPath: ""
    property string posterPath: ""
    property string motionKind: ""
    readonly property string sourceKind: String((root.assets && root.assets.kind) || "")
    property string depthPath: ""
    property string depthPoster: ""
    property string backgroundPath: ""
    property string mattePath: ""
    property string influencePath: ""
    property string segmentation: ""
    property int sourceWidth: 0
    property int sourceHeight: 0
    // Assets being prepared for the next wallpaper. The renderer keeps using
    // the committed fields above until these are complete, so switching does
    // not blank the old 3D wallpaper before the reveal covers it.
    property var nextAssets: ({})
    property string nextMotionPath: ""
    property string nextPosterPath: ""
    property string nextMotionKind: ""
    property string nextDepthPath: ""
    property string nextDepthPoster: ""
    property string nextBackgroundPath: ""
    property string nextMattePath: ""
    property string nextInfluencePath: ""
    property string nextSegmentation: ""
    property int nextSourceWidth: 0
    property int nextSourceHeight: 0
    property string renderPath: ""
    property string status: ""
    property string error: ""
    // A local mesh job is using the whole GPU. Drop the 3D wallpaper to the
    // flat one so the shell keeps its framebuffers while that job runs.
    property bool meshBusy: false
    property bool backendPaused: false
    property string lastPath: ""
    // Picker prewarm: the card under the pointer is the only wallpaper known
    // before it is applied, so its depth/matte are generated while the user is
    // still browsing. One path at a time; the newest request wins.
    property string prewarmPath: ""
    property string prewarmNext: ""
    property string prewarmPoster: ""
    property string prewarmDepth: ""
    property bool prewarmBusy: false
    property int prewarmGen: 0
    property var prewarmDone: ({})
    property int depthGateTicks: 0
    // screen name -> first usable frame is on screen; the reveal waits for
    // every output, not just the one the pointer happened to be on
    property var surfaceReady: ({})
    property int surfaceRevision: 0
    property int surfaceReportCount: 0

    readonly property bool hasVisual: root.motionPath !== "" && root.depthPath !== ""
    // The 3D layer only covers the wallpaper it was built for. While the next
    // one is staging it fades out, leaving skwd's flat wallpaper visible, and
    // fades back in when the new depth/matte/mesh are committed.
    readonly property bool visualVisible: root.enabled && root.hasVisual
        && root.renderPath === root.sourcePath && !root.meshBusy
    readonly property bool ready: root.enabled && root.renderPath === root.sourcePath
        && root.depthPath !== "" && root.motionPath !== ""
    readonly property bool layeredReady: root.ready && root.backgroundPath !== ""
        && root.mattePath !== "" && root.influencePath !== ""
    // committed renderer state: independent of whether the next wallpaper is
    // still being prepared
    readonly property bool layeredVisual: root.hasVisual && root.backgroundPath !== ""
        && root.mattePath !== "" && root.influencePath !== ""
    // animated sources are stopped in their normal backend while the spatial
    // surface owns the screen; stills do not need that handover
    readonly property bool playbackActive: root.hasVisual && root.motionKind !== "" && root.motionKind !== "image"
    readonly property bool allSurfacesReady: {
        root.surfaceRevision;
        const screens = Quickshell.screens;
        if (!screens || screens.length === 0)
            return false;
        for (let i = 0; i < screens.length; i++) {
            if (root.surfaceReady[screens[i].name] !== true)
                return false;
        }
        return true;
    }
    readonly property bool revealReady: root.enabled && root.sourcePath !== ""
        && root.renderPath === root.sourcePath && root.ready && root.allSurfacesReady
    readonly property string motionUrl: root.urlFor(root.motionPath)
    readonly property string posterUrl: root.urlFor(root.posterPath)
    readonly property string depthUrl: root.urlFor(root.depthPath)
    readonly property string backgroundUrl: root.urlFor(root.backgroundPath)
    readonly property string matteUrl: root.urlFor(root.mattePath)
    readonly property string influenceUrl: root.urlFor(root.influencePath)

    function urlFor(path) {
        if (path === "" || path === undefined || path === null)
            return "";
        const value = String(path);
        if (value.indexOf("http://") === 0 || value.indexOf("https://") === 0 || value.indexOf("file://") === 0)
            return value;
        return "file://" + value.split("/").map(encodeURIComponent).join("/");
    }

    function reportSurface(name, ready) {
        if (!name || root.renderPath !== root.sourcePath)
            return ;
        root.surfaceReportCount++;
        const was = root.surfaceReady[name] === true;
        if (was === (ready === true))
            return ;
        const next = {};
        for (const key in root.surfaceReady)
            next[key] = root.surfaceReady[key];
        next[name] = ready === true;
        root.surfaceReady = next;
        root.surfaceRevision++;
    }

    function acceptRequest(text) {
        var data = null;
        try {
            data = JSON.parse(text);
        } catch (e) {
            return ;
        }
        if (!data || !data.path || !data.token)
            return ;
        if (data.created && Date.now() - Number(data.created) > 15000)
            return ;
        const token = String(data.token);
        if (token === root.stagedToken)
            return ;
        root.stagedToken = token;
        root.requestedPath = String(data.path);
        root.requestedToken = token;
        root.requestedAt = Number(data.created || Date.now());
        requestExpiry.restart();
        root.lastPath = "";
        root.surfaceReady = ({});
        root.surfaceRevision++;
        root.reload(true);
        readyPublish.restart();
    }

    function publishReady() {
        const payload = JSON.stringify({
            "path": root.sourcePath,
            "token": root.requestedToken,
            "ready": true,
            "mesh": root.layeredReady && root.surfaceRevision > 0,
            "error": root.error,
            "seq": Date.now()
        });
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" > \"$2\"", "sh", payload, root.readyFile]);
    }

    function clear() {
        assetsProc.running = false;
        depthProc.running = false;
        root.abortPrewarm();
        root.assets = ({});
        root.motionPath = "";
        root.posterPath = "";
        root.motionKind = "";
        root.depthPath = "";
        root.depthPoster = "";
        root.backgroundPath = "";
        root.mattePath = "";
        root.influencePath = "";
        root.segmentation = "";
        root.nextAssets = ({});
        root.nextMotionPath = "";
        root.nextPosterPath = "";
        root.nextMotionKind = "";
        root.nextDepthPath = "";
        root.nextDepthPoster = "";
        root.nextBackgroundPath = "";
        root.nextMattePath = "";
        root.nextInfluencePath = "";
        root.nextSegmentation = "";
        root.nextSourceWidth = 0;
        root.nextSourceHeight = 0;
        root.renderPath = "";
        root.surfaceReady = ({});
        root.surfaceRevision++;
        root.sourceWidth = 0;
        root.sourceHeight = 0;
        root.status = "";
        root.error = "";
    }

    function reload(force) {
        if (!root.enabled || root.sourcePath === "") {
            root.clear();
            return ;
        }
        if (force !== true && root.sourcePath === root.lastPath && (root.assets && root.assets.ok))
            return ;
        // A real apply for another wallpaper owns the CPU; the warm run is
        // only speculation. A warm run for this very wallpaper is kept: the
        // depth stage waits for it instead of repeating the inference.
        if (root.prewarmBusy && root.prewarmPath !== root.sourcePath)
            root.abortPrewarm();
        if (root.sourcePath !== root.lastPath) {
            // Keep the committed visual alive; stage the next one separately.
            root.nextAssets = ({});
            root.nextMotionPath = "";
            root.nextPosterPath = "";
            root.nextMotionKind = "";
            root.nextDepthPath = "";
            root.nextDepthPoster = "";
            root.nextBackgroundPath = "";
            root.nextMattePath = "";
            root.nextInfluencePath = "";
            root.nextSegmentation = "";
            root.nextSourceWidth = 0;
            root.nextSourceHeight = 0;
            root.surfaceReady = ({});
            root.surfaceRevision++;
        }
        root.lastPath = root.sourcePath;
        root.generation++;
        assetsProc.running = false;
        assetsProc.path = root.sourcePath;
        assetsProc.gen = root.generation;
        assetsStart.restart();
        root.status = "Preparing spatial assets";
    }

    function startDepth() {
        if (!root.enabled || root.nextPosterPath === "")
            return ;
        root.depthGeneration++;
        root.depthGateTicks = 0;
        depthProc.running = false;
        prepProc.running = false;
        depthProc.image = root.nextPosterPath;
        depthProc.gen = root.depthGeneration;
        depthStart.restart();
        root.status = "Generating depth map";
        root.error = "";
    }

    function commitVisual() {
        if (root.nextMotionPath === "" || root.nextDepthPath === "")
            return ;
        // A forced re-stage of the wallpaper that is already committed (live
        // previews arriving after boot, or the same picture picked again) does
        // not change what the surfaces render. Clearing the ready map then would
        // leave it empty: renderPath does not change, so nothing re-reports.
        const sameVisual = root.renderPath === root.sourcePath;
        root.assets = root.nextAssets;
        root.motionPath = root.nextMotionPath;
        root.posterPath = root.nextPosterPath;
        root.motionKind = root.nextMotionKind;
        root.depthPath = root.nextDepthPath;
        root.depthPoster = root.nextDepthPoster;
        root.backgroundPath = root.nextBackgroundPath;
        root.mattePath = root.nextMattePath;
        root.influencePath = root.nextInfluencePath;
        root.segmentation = root.nextSegmentation;
        root.sourceWidth = root.nextSourceWidth;
        root.sourceHeight = root.nextSourceHeight;
        // Clear before changing renderPath: the renderPath change notification
        // makes each surface report, and clearing afterwards would erase it.
        if (!sameVisual) {
            root.surfaceReady = ({});
        }
        root.surfaceRevision++;
        root.renderPath = root.sourcePath;
        root.status = "";
        root.error = "";
    }

    function acceptAssets(text, path, gen) {
        if (gen !== root.generation || path !== root.sourcePath || !root.enabled)
            return ;
        var data = null;
        try {
            data = JSON.parse(text);
        } catch (e) {
            root.error = "spatial assets: invalid response";
            root.status = root.error;
            return ;
        }
        if (!data || !data.ok || !data.motion || !data.poster) {
            root.error = String((data && data.error) || "no spatial source");
            root.status = root.error;
            return ;
        }

        root.nextAssets = data;
        root.nextMotionPath = String(data.motion || "");
        root.nextMotionKind = String(data.motionKind || "image");
        root.nextPosterPath = String(data.poster || "");
        root.nextSourceWidth = Number(data.width || 0);
        root.nextSourceHeight = Number(data.height || 0);
        root.nextDepthPath = "";
        root.nextBackgroundPath = "";
        root.nextMattePath = "";
        root.nextInfluencePath = "";
        root.nextSegmentation = "";
        root.nextDepthPoster = root.nextPosterPath;
        root.startDepth();
    }

    function acceptDepth(text, gen) {
        if (gen !== root.depthGeneration)
            return ;
        var data = null;
        try {
            data = JSON.parse(text);
        } catch (e) {
            root.error = "depth engine: invalid response";
            root.status = root.error;
            return ;
        }
        if (!data || !data.ok || !data.depth) {
            root.error = String((data && data.error) || "depth generation failed");
            root.status = root.error;
            root.depthPath = "";
            return ;
        }
        root.nextDepthPath = String(data.depth || "");
        root.error = "";
        root.status = "Preparing foreground matte";
        prepStart.restart();
    }

    function acceptPrep(text, gen) {
        if (gen !== root.generation)
            return ;
        var data = null;
        try {
            data = JSON.parse(text);
        } catch (e) {
            root.error = "spatial prep: invalid response";
            root.status = root.error;
            return ;
        }
        if (!data || !data.ok || !data.background || !data.matte || !data.influence) {
            root.nextBackgroundPath = "";
            root.nextMattePath = "";
            root.nextInfluencePath = "";
            root.nextSegmentation = "";
            root.status = "";
            root.commitVisual();
            return ;
        }
        root.nextBackgroundPath = String(data.background || "");
        root.nextMattePath = String(data.matte || "");
        root.nextInfluencePath = String(data.influence || "");
        root.nextSegmentation = String(data.segmentation || "");
        root.commitVisual();
    }

    // ── picker prewarm ──────────────────────────────────────────────────────
    // The picker knows which wallpaper is about to be picked. Running the same
    // cached pipeline in the background turns the 8-9 s first-use depth + matte
    // inference into work that has already finished when the card is clicked.
    function prewarm(path) {
        if (!root.enabled || path === "")
            return ;
        const target = String(path);
        // "more:remote"/"status:remote" and web thumbs have no local source
        if (target.charAt(0) !== "/" && target.indexOf("skwd:we:") !== 0)
            return ;
        if (target === root.sourcePath)
            return ;
        if (root.prewarmDone[target] === true)
            return ;
        // never compete with a real apply that is still generating
        if (root.status !== "")
            return ;
        if (root.prewarmBusy) {
            root.prewarmNext = target;
            return ;
        }
        root.prewarmGen++;
        root.prewarmPath = target;
        root.prewarmPoster = "";
        root.prewarmDepth = "";
        root.prewarmBusy = true;
        prewarmAssets.path = target;
        prewarmAssets.gen = root.prewarmGen;
        prewarmAssets.running = false;
        prewarmAssets.running = true;
    }

    function finishPrewarm() {
        const done = {};
        for (const key in root.prewarmDone)
            done[key] = root.prewarmDone[key];
        if (root.prewarmPath !== "")
            done[root.prewarmPath] = true;
        root.prewarmDone = done;
        root.prewarmBusy = false;
        root.prewarmPath = "";
        root.prewarmPoster = "";
        root.prewarmDepth = "";
        const next = root.prewarmNext;
        root.prewarmNext = "";
        if (next !== "" && next !== root.sourcePath)
            root.prewarm(next);
    }

    function abortPrewarm() {
        root.prewarmGen++;
        prewarmAssets.running = false;
        prewarmDepth.running = false;
        prewarmPrep.running = false;
        root.prewarmBusy = false;
        root.prewarmPath = "";
        root.prewarmPoster = "";
        root.prewarmDepth = "";
        root.prewarmNext = "";
    }

    function acceptPrewarmAssets(text, gen) {
        if (gen !== root.prewarmGen || !root.prewarmBusy)
            return ;
        var data = null;
        try {
            data = JSON.parse(text);
        } catch (e) {
            root.abortPrewarm();
            return ;
        }
        if (!data || !data.ok || !data.poster) {
            root.abortPrewarm();
            return ;
        }
        root.prewarmPoster = String(data.poster || "");
        if (root.prewarmPoster === "") {
            root.abortPrewarm();
            return ;
        }
        prewarmDepth.image = root.prewarmPoster;
        prewarmDepth.gen = gen;
        prewarmDepth.running = true;
    }

    function acceptPrewarmDepth(text, gen) {
        if (gen !== root.prewarmGen || !root.prewarmBusy)
            return ;
        var data = null;
        try {
            data = JSON.parse(text);
        } catch (e) {
            root.abortPrewarm();
            return ;
        }
        if (!data || !data.ok || !data.depth) {
            root.abortPrewarm();
            return ;
        }
        root.prewarmDepth = String(data.depth || "");
        prewarmPrep.image = root.prewarmPoster;
        prewarmPrep.depth = root.prewarmDepth;
        prewarmPrep.gen = gen;
        prewarmPrep.running = true;
    }

    function acceptPrewarmPrep(text, gen) {
        if (gen !== root.prewarmGen || !root.prewarmBusy)
            return ;
        var data = null;
        try {
            data = JSON.parse(text);
        } catch (e) {
            root.abortPrewarm();
            return ;
        }
        if (!data || !data.ok)
            root.abortPrewarm();
        else
            root.finishPrewarm();
    }

    function syncBackend() {
        if (!SkwdWall.enabled)
            return ;
        const want = root.playbackActive;
        if (want === root.backendPaused)
            return ;
        root.backendPaused = want;
        backend.pause = want;
        backend.running = true;
        Quickshell.execDetached(["sh", "-c", want ? "touch \"$0\"" : "rm -f \"$0\"", root.pauseMarker]);
    }

    function releaseBackend() {
        if (!SkwdWall.enabled || !root.backendPaused)
            return ;
        root.backendPaused = false;
        backend.pause = false;
        backend.running = true;
        Quickshell.execDetached(["sh", "-c", "rm -f \"$0\"", root.pauseMarker]);
    }

    function ensureLayerOrder() {
        layerOrder.running = true;
    }

    onIsSceneChanged: readyPublish.restart()
    onEnabledChanged: {
        readyPublish.restart();
        if (root.enabled) {
            root.ensureLayerOrder();
            root.reload();
        } else {
            root.clear();
            root.releaseBackend();
        }
    }
    onCurrentPathChanged: {
        readyPublish.restart();
        if (root.requestedPath === "" && (SkwdWall.currentPath !== "" || !SkwdWall.enabled))
            root.reload();
    }
    onPlaybackActiveChanged: root.syncBackend()

    Component.onCompleted: {
        if (!root.enabled)
            return ;
        root.ensureLayerOrder();
        // a crash can leave skwd paused; the marker says the pause was ours
        Quickshell.execDetached(["sh", "-c", "[ -f \"$0\" ] && skwd-helm resume >/dev/null 2>&1; rm -f \"$0\"", root.pauseMarker]);
        root.reload();
    }

    Connections {
        target: SkwdWall

        function onCurrentPathChanged() {
            if (root.enabled)
                root.reload();
        }
        function onLivePreviewsChanged() {
            if (root.enabled)
                root.reload(true);
        }
        function onItemsChanged() {
            if (root.enabled)
                root.reload();
        }
    }

    Connections {
        target: Prefs

        // A different depth model has its own cache contract, so the wallpaper
        // on screen has to be staged again (its depth map is rebuilt once).
        function onSpatialDepthModelChanged() {
            if (!root.enabled)
                return ;
            root.lastPath = "";
            root.reload(true);
        }
    }

    Connections {
        target: LiveWall

        function onVideoChanged() {
            if (root.enabled)
                root.reload();
        }
        function onPictureChanged() {
            if (root.enabled)
                root.reload();
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name === "configreloaded" && root.enabled && !layerOrder.running)
                root.ensureLayerOrder();
        }
    }

    FileView {
        id: requestStore

        path: root.requestFile
        watchChanges: true
        printErrors: false
        // watchChanges does not re-read the file on its own here; the change
        // signal only queues a reload, which then emits onLoaded.
        onFileChanged: requestStore.reload()
        onLoaded: root.acceptRequest(text())
    }

    Timer {
        id: requestExpiry

        interval: 45000
        repeat: false
        running: root.requestedPath !== ""
        onTriggered: {
            if (root.currentPath !== "" && root.currentPath !== root.requestedPath) {
                root.requestedPath = "";
                root.requestedToken = "";
                root.requestedAt = 0;
                root.lastPath = "";
                root.reload(true);
            }
        }
    }

    Timer {
        id: readyPublish

        interval: 120
        repeat: false
        onTriggered: root.publishReady()
    }

    onRevealReadyChanged: readyPublish.restart()
    onSurfaceRevisionChanged: readyPublish.restart()

    Timer {
        id: assetsStart

        interval: 20
        repeat: false
        onTriggered: {
            if (root.enabled && assetsProc.path === root.sourcePath)
                assetsProc.running = true;
        }
    }

    Timer {
        id: depthStart

        interval: 20
        repeat: false
        onTriggered: {
            if (!root.enabled || depthProc.image !== root.nextPosterPath)
                return ;
            // If the picker already warmed this exact wallpaper, let it finish
            // rather than starting a second inference beside it: the cache it
            // fills turns this stage into a 0.1 s hit. Capped so a stuck warm
            // run can never hold the reveal closed.
            if (root.prewarmBusy && root.prewarmPath === root.sourcePath
                    && root.depthGateTicks < 750) {
                root.depthGateTicks++;
                depthStart.restart();
                return ;
            }
            root.depthGateTicks = 0;
            depthProc.running = true;
        }
    }

    Timer {
        id: prepStart

        interval: 20
        repeat: false
        onTriggered: {
            if (!root.enabled || root.nextDepthPath === "")
                return ;
            prepProc.depth = root.nextDepthPath;
            prepProc.image = root.nextPosterPath;
            prepProc.gen = root.generation;
            prepProc.running = true;
        }
    }

    Process {
        id: assetsProc

        property string path: ""
        property int gen: 0

        command: ["/usr/bin/python3", root.assetsScript, "--path", assetsProc.path]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.acceptAssets(text, assetsProc.path, assetsProc.gen)
        }
        onExited: (code) => {
            // 15/143 is our own cancellation when the wallpaper changes.
            if (code !== 0 && code !== 15 && code !== 143
                    && assetsProc.gen === root.generation) {
                root.error = "spatial assets exited " + code;
                root.status = root.error;
            }
        }
    }

    Process {
        id: depthProc

        property string image: ""
        property int gen: 0

        command: ["/usr/bin/nice", "-n", "19", "/usr/bin/python3", root.depthScript,
            "--image", depthProc.image, "--model", Prefs.spatialDepthModel,
            "--progress", root.progressPath]
        environment: ({
            "OMP_NUM_THREADS": "4"
        })
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.acceptDepth(text, depthProc.gen)
        }
        onExited: (code) => {
            if (code !== 0 && code !== 15 && code !== 143
                    && depthProc.gen === root.depthGeneration
                    && root.status === "Generating depth map")
                root.status = "Depth engine exited " + code;
        }
    }

    Process {
        id: prepProc

        property string image: ""
        property string depth: ""
        property int gen: 0

        command: ["/usr/bin/nice", "-n", "19", "/usr/bin/python3", root.prepScript,
            "--image", prepProc.image, "--depth", prepProc.depth]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.acceptPrep(text, prepProc.gen)
        }
        onExited: (code) => {
            if (code !== 0 && code !== 15 && code !== 143
                    && prepProc.gen === root.generation)
                root.status = "Spatial prep exited " + code;
        }
    }

    // The picker's background pipeline. Same scripts and cache as the live
    // one, never the same target twice, and abandoned the moment a real apply
    // needs the CPU for a different wallpaper.
    Process {
        id: prewarmAssets

        property string path: ""
        property int gen: 0

        command: ["/usr/bin/python3", root.assetsScript, "--path", prewarmAssets.path]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.acceptPrewarmAssets(text, prewarmAssets.gen)
        }
        onExited: (code) => {
            if (code !== 0 && code !== 15 && code !== 143
                    && prewarmAssets.gen === root.prewarmGen)
                root.abortPrewarm();
        }
    }

    Process {
        id: prewarmDepth

        property string image: ""
        property int gen: 0

        command: ["/usr/bin/nice", "-n", "19", "/usr/bin/python3", root.depthScript,
            "--image", prewarmDepth.image, "--model", Prefs.spatialDepthModel]
        environment: ({
            "OMP_NUM_THREADS": "4"
        })
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.acceptPrewarmDepth(text, prewarmDepth.gen)
        }
        onExited: (code) => {
            if (code !== 0 && code !== 15 && code !== 143
                    && prewarmDepth.gen === root.prewarmGen)
                root.abortPrewarm();
        }
    }

    Process {
        id: prewarmPrep

        property string image: ""
        property string depth: ""
        property int gen: 0

        command: ["/usr/bin/nice", "-n", "19", "/usr/bin/python3", root.prepScript,
            "--image", prewarmPrep.image, "--depth", prewarmPrep.depth]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.acceptPrewarmPrep(text, prewarmPrep.gen)
        }
        onExited: (code) => {
            if (code !== 0 && code !== 15 && code !== 143
                    && prewarmPrep.gen === root.prewarmGen)
                root.abortPrewarm();
        }
    }

    Process {
        id: backend

        property bool pause: false

        command: ["skwd-helm", backend.pause ? "pause" : "resume"]
        running: false
    }

    Process {
        id: layerOrder

        command: ["hyprctl", "eval",
            "if not LucidSpatialOrder then LucidSpatialOrder = true " +
            "hl.layer_rule({ match = { namespace = \"skwd-wall-vk\" }, order = 6 }) " +
            "hl.layer_rule({ match = { namespace = \"skwd-paper\" }, order = 6 }) " +
            "hl.layer_rule({ match = { namespace = \"awww-daemon\" }, order = 6 }) " +
            "hl.layer_rule({ match = { namespace = \"swww-daemon\" }, order = 6 }) " +
            "hl.layer_rule({ match = { namespace = \"lucid-underlay\" }, order = 6 }) " +
            "hl.layer_rule({ match = { namespace = \"lucid-live\" }, order = 5 }) " +
            "hl.layer_rule({ match = { namespace = \"lucid-spatial\" }, order = 4 }) " +
            "hl.layer_rule({ match = { namespace = \"lucid-desktop\" }, order = 2 }) " +
            "hl.layer_rule({ match = { namespace = \"lucid-spatial-foreground\" }, order = 0 }) " +
            "hl.layer_rule({ match = { namespace = \"lucid-widgets\" }, order = 1 }) end"]
        running: false
    }

    FileView {
        path: root.progressPath
        watchChanges: true
        printErrors: false
        onLoaded: {
            var data = null;
            try {
                data = JSON.parse(text());
            } catch (e) {
                return ;
            }
            if (!data)
                return ;
            if (data.stage === "downloading-model") {
                const total = Number(data.total || 0);
                const got = Number(data.received || 0);
                root.status = total > 0
                    ? "Downloading depth model " + Math.round(got / total * 100) + "%"
                    : "Downloading depth model";
            } else if (data.stage === "generating")
                root.status = "Generating depth map";
            else if (data.stage === "writing")
                root.status = "Writing depth map";
        }
    }
}
