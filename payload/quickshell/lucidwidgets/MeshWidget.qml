import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs
import qs.lucidui
import "../squircle"

// scene → meshes. drop a photo in; every object you name is lifted to a mesh,
// the room's floor and walls are recovered from depth, and the pieces are put
// back together where they sat in the frame.
WidgetBody {
    id: w

    readonly property string home: Quickshell.env("HOME")
    readonly property string svcPy: w.home + "/src/image-to-3d/sam-3d/.venv/bin/python"
    readonly property string svcJs: w.home + "/src/image-to-3d/pipeline/lucid/mesh_service.py"

    // idle | running | done | failed
    property string phase: "idle"
    property string statusText: ""
    property string source: ""
    property string sourceImage: ""
    readonly property bool hasImage: w.source !== ""
    // the field starts empty; the placeholder is only a hint, not a value
    property string prompts: ""
    // anything stored from before the remote engine was removed runs locally
    property string engine: w.opt("engine") === "mock" ? "mock" : "local"
    property string viewMode: w.opt("view") || "single"
    property string sceneGlb: ""
    property string scenePreview: ""
    property bool dragging: false
    property var external: []
    property string externalSig: ""

    // the piece shown in the single view
    property int curId: -1
    property string curLabel: ""
    property string curCrop: ""
    property string curGlb: ""
    property string curPreview: ""
    property real curProgress: 0
    property string curState: "queued"

    // The preview shape breathes between two m3 expressive shapes while a
    // build is in flight, then settles back to the base mask.
    property real maskMorph: 0

    SequentialAnimation {
        running: w.phase === "running"
        loops: Animation.Infinite

        onRunningChanged: {
            if (!running)
                w.maskMorph = 0;
        }

        NumberAnimation {
            target: w
            property: "maskMorph"
            from: 0
            to: 1
            duration: 2600
            easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: w
            property: "maskMorph"
            from: 1
            to: 0
            duration: 2600
            easing.type: Easing.InOutSine
        }
    }

    property int adoptedPid: 0
    property bool watching: false
    property bool showViewer: false
    property string viewGlb: ""
    property string viewLabel: ""
    property string viewPreview: ""
    property string viewCrop: ""

    ListModel {
        id: objects
    }

    // ---------------------------------------------------------------- backend
    // Jobs run in their own session (mesh-job.sh) and report through
    // ~/.cache/lucid-mesh/active-<pid>.json. The widget only watches files, so
    // a Quickshell reload cannot kill a run and a later launch can adopt or
    // resume it.
    property string jobId: ""
    property int jobPid: 0
    property string jobDir: ""
    property string ignoredJob: ""
    property int ignoredPid: 0
    property bool tracking: false
    property bool resumeChecked: false
    property bool finishChecking: false
    property double jobStartedAt: 0
    // Only the copy of the card that is actually on its screen runs the file
    // poller; the same widget is instantiated per output otherwise.
    readonly property bool scannerEnabled: !w.preview
        && (w.host ? w.host.onThisScreen === true : true)
    readonly property string jobTool: w.home + "/.config/quickshell/luciddocks/mesh-job.sh"
    readonly property string scanTool: w.home + "/.config/quickshell/luciddocks/mesh-scan.sh"

    function newJobId() {
        return String(Date.now()) + "-" + Math.floor(Math.random() * 1000000);
    }

    function cleanStatus(text) {
        var value = String(text || "");
        if (/^\d+\s+objects?$/i.test(value))
            return "building meshes";
        if (value === "finding objects")
            return "preparing objects";
        if (/^\d+\s+surface\(s\)/i.test(value))
            return "finding surfaces";
        if (/^\d+\s+meshes?\b/i.test(value))
            return "meshes placed";
        return value;
    }

    // Choosing or dropping an image only stages it: the user can see the
    // picture and edit the prompts, and the start button is what launches the
    // pipeline.
    function selectImage(path) {
        const file = String(path).replace("file://", "");
        if (file === "")
            return ;
        if (w.phase === "running" || w.watching)
            w.cancelAll();
        if (w.jobId !== "") {
            w.ignoredJob = w.jobId;
            w.ignoredPid = w.jobPid;
        }
        w.jobId = "";
        w.jobPid = 0;
        w.tracking = false;
        objects.clear();
        w.source = file;
        w.sourceImage = file;
        w.scenePreview = "";
        w.sceneGlb = "";
        w.phase = "idle";
        w.statusText = "";
        w.curId = -1;
        w.curLabel = "";
        w.curCrop = "";
        w.curGlb = "";
        w.curPreview = "";
        w.curProgress = 0;
        w.curState = "ready";
        w.showViewer = false;
        // A staged image has no object rows yet; staying in list view left
        // both panels hidden and the card looking blank.
        w.setView("single");
        w.setOpts({
            "last": file,
            "prompts": w.prompts,
            "view": w.viewMode
        });
    }

    function startJob(path) {
        const file = String(path).replace("file://", "");
        if (file === "")
            return ;
        objects.clear();
        w.source = file;
        w.sourceImage = file;
        w.scenePreview = "";
        w.sceneGlb = "";
        w.phase = "running";
        w.statusText = "reading the frame…";
        w.curId = -1;
        w.curLabel = "";
        w.curCrop = "";
        w.curGlb = "";
        w.curPreview = "";
        w.curProgress = 0;
        w.curState = "queued";
        w.jobId = w.newJobId();
        w.jobPid = 0;
        w.jobDir = "";
        w.ignoredJob = "";
        w.tracking = true;
        w.jobStartedAt = Date.now();
        w.setOpts({
            "last": w.source,
            "prompts": w.prompts,
            "view": w.viewMode
        });
        var list = w.prompts.split(",").map(s => s.trim()).filter(s => s.length > 0);
        Quickshell.execDetached([w.jobTool, "run", w.source, JSON.stringify(list), w.engine, w.jobId]);
    }

    function setObject(id, patch) {
        for (var i = 0; i < objects.count; i++) {
            if (objects.get(i).oid !== id)
                continue;

            for (var k in patch) objects.setProperty(i, k, patch[k]);
            w.pickCurrent();
            return ;
        }
        objects.append({
            "oid": id,
            "label": patch.label || "object " + id,
            "crop": patch.crop || "",
            "kind": patch.kind || "object",
            "state": patch.state || "queued",
            "progress": patch.progress || 0,
            "preview": patch.preview || "",
            "glb": patch.glb || "",
            "note": patch.note || ""
        });
        w.pickCurrent();
    }

    // the single view follows the work: whoever is running, else the next in
    // line, else the last thing finished
    function pickCurrent() {
        var running = -1, queued = -1, done = -1;
        for (var i = 0; i < objects.count; i++) {
            var e = objects.get(i);
            if (e.state === "running" && running < 0)
                running = i;
            else if (e.state === "queued" && queued < 0)
                queued = i;
            else if (e.state === "done")
                done = i;
        }
        var pick = running >= 0 ? running : (queued >= 0 ? queued : done);
        if (pick < 0)
            return ;

        var o = objects.get(pick);
        w.curId = o.oid;
        w.curLabel = o.label;
        w.curCrop = o.crop;
        w.curGlb = o.glb;
        w.curPreview = o.preview || "";
        w.curProgress = o.progress;
        w.curState = o.state;
    }

    function recount() {
        var done = 0;
        for (var i = 0; i < objects.count; i++) {
            var s = objects.get(i).state;
            if (s === "done" || s === "failed" || s === "cancelled")
                done++;
        }
        return done;
    }

    function ingest(line) {
        if (!line || line.charAt(0) !== "{")
            return ;

        var e;
        try {
            e = JSON.parse(line);
        } catch (err) {
            return ;
        }
        if (e.t === "source") {
            w.sourceImage = e.image;
        } else if (e.t === "state") {
            // the service's state text can carry an object count ("1 objects");
            // the card shows names, not a tally
            var text = String(e.text || e.state || "");
            if (/^\d+\s+objects?$/i.test(text))
                text = "building meshes";
            else if (text === "finding objects")
                text = "preparing objects";
            else if (/^\d+\s+surface\(s\)/i.test(text))
                text = "finding surfaces";
            else if (/^\d+\s+meshes?\b/i.test(text))
                text = "meshes placed";
            w.statusText = text;
            if (e.state === "done") {
                w.phase = "done";
            }
        } else if (e.t === "object") {
            var patch = {};
            ["label", "crop", "kind", "state", "progress", "preview", "note", "glb"].forEach(function (k) {
                if (e[k] !== undefined && e[k] !== "")
                    patch[k] = e[k];
            });
            w.setObject(e.id, patch);
        } else if (e.t === "scene") {
            w.sceneGlb = e.glb || "";
            w.scenePreview = e.preview || "";
            w.phase = "done";
            w.statusText = "meshes placed";
        } else if (e.t === "error") {
            w.phase = "failed";
            w.statusText = String(e.text || "pipeline failed").split("\n")[0];
        }
    }

    function cancelOne(id) {
        w.setObject(id, {
            "state": "cancelled",
            "progress": 0
        });
        if (w.jobPid > 0)
            canceller.cancel(w.jobPid, id);
        w.pickCurrent();
    }

    function cancelAll() {
        for (var i = 0; i < objects.count; i++) {
            var s2 = objects.get(i).state;
            if (s2 === "running" || s2 === "queued")
                objects.setProperty(i, "state", "cancelled");
        }
        if (w.jobPid > 0)
            canceller.cancel(w.jobPid, null);
        for (var j = 0; j < w.external.length; j++) canceller.cancel(w.external[j].pid, null);
        w.ignoredJob = w.jobId;
        w.ignoredPid = w.jobPid;
        w.jobId = "";
        w.jobPid = 0;
        w.tracking = false;
        w.phase = "idle";
        w.statusText = "cancelled";
        w.pickCurrent();
    }

    function reveal(path) {
        if (!path || path === "")
            return ;

        var dir = path.substring(0, path.lastIndexOf("/"));
        if (!Quickshell.execDetached(["nautilus", "--select", path]))
            Quickshell.execDetached(["xdg-open", dir]);
    }

    function reset() {
        if (w.jobId !== "") {
            w.ignoredJob = w.jobId;
            w.ignoredPid = w.jobPid;
        }
        w.jobId = "";
        w.jobPid = 0;
        w.tracking = false;
        objects.clear();
        w.phase = "idle";
        w.scenePreview = "";
        w.curId = -1;
        w.curLabel = "";
        w.curCrop = "";
        w.curGlb = "";
        w.curPreview = "";
        w.curProgress = 0;
        w.curState = "queued";
        // back to the drop surface, not a preview of the image that just ran
        w.source = "";
        w.sourceImage = "";
        w.statusText = "";
    }

    function setView(mode) {
        w.viewMode = mode;
        w.setOpts({
            "view": mode
        });
    }

    // follow a run started elsewhere, through the registry it keeps writing
    function adoptExternal(entry) {
        w.jobId = entry.job_id || w.newJobId();
        w.adoptedPid = entry.pid;
        w.jobPid = entry.pid;
        w.jobDir = entry.job_dir || "";
        w.tracking = true;
        w.watching = true;
        w.phase = "running";
        if (entry.image)
            w.source = entry.image;
        if (entry.crop_source || entry.image)
            w.sourceImage = entry.crop_source || entry.image;
        w.mirror(entry);
    }

    function resumeJob(entry) {
        if (!entry || !entry.file)
            return ;
        w.jobId = w.newJobId();
        w.jobPid = 0;
        w.jobDir = entry.job_dir || "";
        w.ignoredJob = "";
        w.tracking = true;
        w.watching = false;
        w.jobStartedAt = Date.now();
        w.phase = "running";
        w.statusText = "resuming…";
        if (entry.image)
            w.source = entry.image;
        if (entry.crop_source || entry.image)
            w.sourceImage = entry.crop_source || entry.image;
        Quickshell.execDetached([w.jobTool, "resume", entry.file, w.jobId]);
    }

    function mirror(entry) {
        if (!entry)
            return ;

        var priorJob = w.jobId;
        if (entry.job_id && (w.jobId === "" || w.jobId === entry.job_id))
            w.jobId = entry.job_id;
        if (entry.pid)
            w.jobPid = entry.pid;
        if (entry.job_dir)
            w.jobDir = entry.job_dir;
        if (entry.image && w.source === "")
            w.source = entry.image;
        if ((entry.crop_source || entry.image) && w.sourceImage === "")
            w.sourceImage = entry.crop_source || entry.image;

        var list = entry.objects || [];
        if (list.length > 0) {
            // Reconcile in place. Clearing and re-appending the model on every
            // 500 ms scan recreated every row (and reloaded its thumbnail),
            // which showed up as flicker in the list.
            var seen = {};
            for (var i = 0; i < list.length; i++) {
                var o = list[i];
                var oid = o.id !== undefined ? o.id : i;
                seen[oid] = true;
                var row = {
                    "oid": oid,
                    "label": o.label || ("object " + i),
                    "crop": o.crop || "",
                    "kind": o.kind || "object",
                    "state": o.state || "queued",
                    "progress": o.progress || 0,
                    "preview": o.preview || "",
                    "glb": o.glb || "",
                    "note": o.note || ""
                };
                var at = -1;
                for (var k = 0; k < objects.count; k++) {
                    if (objects.get(k).oid === oid) {
                        at = k;
                        break;
                    }
                }
                if (at < 0) {
                    objects.append(row);
                } else {
                    var cur = objects.get(at);
                    for (var key in row) {
                        if (cur[key] !== row[key])
                            objects.setProperty(at, key, row[key]);
                    }
                }
            }
            for (var r = objects.count - 1; r >= 0; r--) {
                if (!seen[objects.get(r).oid])
                    objects.remove(r, 1);
            }
        } else if (priorJob !== w.jobId) {
            objects.clear();
        }
        w.statusText = w.cleanStatus(entry.text || entry.phase || "");
        if (entry.scene && entry.scene.glb) {
            w.sceneGlb = entry.scene.glb;
            w.scenePreview = entry.scene.preview || "";
        }
        if (entry.phase === "done") {
            w.phase = "done";
            w.scenePreview = entry.scene ? (entry.scene.preview || "") : w.scenePreview;
        } else if (entry.phase === "failed") {
            w.phase = "failed";
        } else if (entry.phase === "cancelled") {
            w.phase = "idle";
        } else if (w.phase !== "done") {
            w.phase = "running";
        }
        w.pickCurrent();
    }

    function settleDone(entry) {
        if (!entry)
            return ;
        w.ignoredJob = entry.job_id || "";
        w.ignoredPid = entry.pid || 0;
        w.jobId = "";
        w.jobPid = 0;
        w.tracking = false;
    }

    function scanExternal() {
        if (!w.scannerEnabled)
            return ;
        scanner.running = true;
    }

    function pickImage() {
        picker.running = true;
    }

    // ------------------------------------------------------------------ layout
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: w.pad
        spacing: Theme.dp(12)

        // ---- header
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            // single object / list toggle, at the start of the title row
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: Theme.dp(36)
                Layout.preferredHeight: Theme.dp(36)
                radius: Theme.pill(height)
                color: Theme.alpha(Theme.bg, 0.78)
                visible: (w.phase !== "idle" || w.external.length > 0) && !w.showViewer

                IconButton {
                    anchors.centerIn: parent
                    // one control: the icon is the view you are in, and a
                    // click flips to the other one.
                    icon: w.viewMode === "single" ? "deployed_code" : "layers"
                    size: "xs"
                    onClicked: w.setView(w.viewMode === "single" ? "list" : "single")
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(1)

                LText {
                    role: "titleMedium"
                    text: w.phase === "idle" ? "Image to 3D" : (w.phase === "done" ? "Done" : (w.curLabel !== "" ? w.curLabel : "Working…"))
                    color: w.ink
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                LText {
                    role: "labelSmall"
                    text: w.statusText
                    color: w.inkDim
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    visible: w.statusText !== ""
                }
            }

            Chip {
                kind: "assist"
                text: "watching"
                icon: "visibility"
                visible: w.watching && w.width > 420
            }

            IconButton {
                icon: "stop_circle"
                variant: "filled"
                visible: w.phase === "running"
                onClicked: {
                    if (w.watching && w.adoptedPid > 0) {
                        var stopped = w.jobPid > 0 ? w.jobPid : w.adoptedPid;
                        w.ignoredJob = w.jobId;
                        w.ignoredPid = stopped;
                        canceller.cancel(stopped, null);
                        w.jobId = "";
                        w.jobPid = 0;
                        w.tracking = false;
                        w.watching = false;
                        w.phase = "idle";
                        w.statusText = "cancelled";
                    } else {
                        w.cancelAll();
                    }
                }
            }

            IconButton {
                // Choose the next image instead of rerunning the old one.
                icon: "folder_open"
                visible: w.phase !== "running"
                onClicked: w.pickImage()
            }
        }

        // ---- body
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // idle: the drop surface
            Item {
                anchors.fill: parent
                visible: (w.phase === "idle" && !w.hasImage) || w.phase === "failed"

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.rad(32)
                    color: w.dragging ? Theme.primaryContainer : Theme.alpha(w.ink, 0.04)
                    border.width: Theme.dp(1.5)
                    border.color: w.dragging ? Theme.primary : Theme.alpha(w.ink, 0.22)
                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.ms(160)
                        }
                    }
                }

                ColumnLayout {
                    anchors.centerIn: parent
                    width: Math.max(0, Math.min(parent.width - Theme.dp(40), Theme.dp(420)))
                    spacing: Theme.dp(10)

                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: Theme.dp(2)
                        Layout.preferredWidth: Math.min(parent.width, Theme.dp(320))
                        implicitHeight: Theme.dp(44)
                        visible: w.external.length > 0
                        radius: Theme.rad(16)
                        color: extHover.hovered ? Theme.alpha(Theme.tertiary, 0.28) : Theme.alpha(Theme.tertiary, 0.16)
                        scale: extHover.hovered ? 1.02 : 1

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.ms(150)
                            }
                        }
                        Behavior on scale {
                            NumberAnimation {
                                duration: Theme.ms(150)
                                easing.type: Easing.OutCubic
                            }
                        }

                        HoverHandler {
                            id: extHover
                            cursorShape: Qt.PointingHandCursor
                        }

                        StateLayer {
                            anchors.fill: parent
                            radius: parent.radius
                            onClicked: w.adoptExternal(w.external[0])
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: Theme.dp(8)
                            spacing: Theme.dp(8)
                            z: 1

                            Icon {
                                name: "bolt"
                                size: Theme.dp(16)
                                color: w.ink
                            }
                            LText {
                                Layout.fillWidth: true
                                role: "labelMedium"
                                color: w.ink
                                elide: Text.ElideMiddle
                                text: {
                                    if (!w.external || w.external.length === 0)
                                        return "";

                                    var e = w.external[0];
                                    var name = String(e.image || "").split("/").pop();
                                    var extra = w.external.length > 1 ? " +" + (w.external.length - 1) : "";
                                    return "already running: " + name + extra;
                                }
                            }
                            IconButton {
                                icon: "close"
                                size: "xs"
                                onClicked: {
                                    for (var j = 0; j < w.external.length; j++) canceller.cancel(w.external[j].pid);
                                    w.external = [];
                                }
                            }
                        }
                    }

                    LText {
                        Layout.alignment: Qt.AlignHCenter
                        role: "titleMedium"
                        text: w.phase === "failed" ? "That run did not finish" : "Drop a photo, or"
                        color: w.ink
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: Theme.dp(4)
                        spacing: Theme.dp(8)

                        Button {
                            text: w.width > 300 ? "Choose file" : ""
                            icon: "photo_library"
                            variant: "tonal"
                            onClicked: w.pickImage()
                        }
                    }
                }
            }

            // ---- one piece at a time: the crop behind, the mesh over it
            Item {
                anchors.fill: parent
                visible: (w.phase === "running" || w.phase === "done" || w.watching || (w.phase === "idle" && w.hasImage)) && w.viewMode === "single"

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Theme.dp(8)

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        // The preview is square: the crop and the expressive
                        // mask are both designed for a square. The image is 10%
                        // larger than that square and is not clipped, so it
                        // bleeds past the container's edges.
                        Item {
                            anchors.centerIn: parent
                            width: Math.min(parent.width, parent.height)
                            height: width

                            ShapedImage {
                                anchors.centerIn: parent
                                width: parent.width * 1.10
                                height: parent.height * 1.10
                                shape: "cookie12"
                                to: w.phase === "running" ? "cookie9" : ""
                                morph: w.maskMorph
                                fillMode: Image.PreserveAspectCrop
                                source: {
                                    if (w.curState === "done" && w.curPreview !== "")
                                        return "file://" + w.curPreview;
                                    return w.curCrop !== "" ? "file://" + w.curCrop : (w.sourceImage !== "" ? "file://" + w.sourceImage : "");
                                }
                                fallbackColor: Theme.surfaceHighest
                                fallbackVisible: true
                                // Hovering a finished piece pulls the picture
                                // inside the shape; the mask itself stays put.
                                contentScale: (w.curState === "done" && previewHit.containsMouse) ? 0.85 : 1.0
                            }

                            // before any row exists, say what is happening on top of the photo
                            Rectangle {
                                anchors.fill: parent
                                radius: Theme.rad(28)
                                color: Theme.alpha(Theme.bg, 0.55)
                                visible: w.curId < 0 && w.phase !== "idle"
                            }
                        }

                        MouseArea {
                            id: previewHit

                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: w.curState === "done" && w.curGlb !== ""
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: w.reveal(w.curGlb)
                        }
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: Theme.dp(8)

                        LText {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.maximumWidth: Math.max(Theme.dp(60), w.width - Theme.dp(190))
                            role: "titleSmall"
                            text: w.curLabel !== "" ? w.curLabel : (w.phase === "idle" && w.hasImage ? w.source.split("/").pop() : "preparing…")
                            color: w.ink
                            elide: Text.ElideRight
                        }

                        LText {
                            Layout.alignment: Qt.AlignVCenter
                            role: "labelSmall"
                            text: w.curState === "done" ? "ready — click to open" : (w.curState === "failed" ? "failed" : (w.curState === "cancelled" ? "cancelled" : (w.curState === "ready" ? "ready" : (w.curState === "running" ? "building mesh · " + Math.round(w.curProgress * 100) + "%" : "queued"))))
                            color: w.curState === "failed" ? Theme.error : w.inkFaint
                            elide: Text.ElideRight
                        }
                    }

                    LinearProgress {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Theme.dp(6)
                        visible: w.curState !== "ready"
                        value: w.curState === "done" ? 1 : w.curProgress
                        wavy: w.curState === "running"
                        animated: w.curState === "running"
                        color: w.curState === "failed" ? Theme.error : Theme.primary
                        trackColor: Theme.alpha(w.ink, 0.10)
                    }

                    // The only start controls: the prompt and the button. They
                    // vanish while a build is running and come back when it is
                    // done, ready for another pass.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(8)
                        visible: w.phase !== "running" && !w.watching

                        Item {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredHeight: Theme.dp(44)

                            TextField {
                                id: prompt

                                anchors.fill: parent
                                variant: "search"
                                icon: "category"
                                placeholder: "Bed, Person.."
                                text: w.prompts
                                onTextEdited: w.prompts = text
                                onAccepted: w.startJob(w.source !== "" ? w.source : (w.opt("last") || ""))

                                input.onActiveFocusChanged: {
                                    if (input.activeFocus)
                                        w.beginEdit();
                                }
                                input.Keys.onEscapePressed: {
                                    w.endEdit();
                                    input.focus = false;
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: !prompt.input.activeFocus
                                cursorShape: Qt.IBeamCursor
                                onClicked: {
                                    w.beginEdit();
                                    prompt.input.forceActiveFocus();
                                }
                            }
                        }

                        Button {
                            text: w.width > 300 ? "Start" : ""
                            icon: "auto_awesome"
                            variant: "filled"
                            size: "m"
                            Layout.alignment: Qt.AlignVCenter
                            enabled: w.source !== "" || (w.opt("last") || "") !== ""
                            onClicked: w.startJob(w.source !== "" ? w.source : (w.opt("last") || ""))
                        }
                    }
                }
            }

            // ---- list: every piece at once
            Item {
                anchors.fill: parent
                visible: (w.phase === "running" || w.phase === "done" || w.watching
                    || (w.phase === "idle" && w.external.length > 0)) && w.viewMode === "list"

                RowLayout {
                    anchors.fill: parent
                    spacing: Theme.dp(12)

                    Flickable {
                        id: flick

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: width
                        contentHeight: list.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        Column {
                            id: list

                            width: flick.width
                            spacing: Theme.dp(8)

                            LText {
                                width: list.width
                                visible: w.external.length > 0
                                role: "labelSmall"
                                text: "Running jobs"
                                color: w.inkDim
                            }

                            Repeater {
                                model: w.external

                                delegate: Rectangle {
                                    required property var modelData

                                    width: list.width
                                    height: Theme.dp(64)
                                    radius: Theme.rad(20)
                                    color: jobHover.hovered ? Theme.alpha(w.ink, 0.10) : Theme.alpha(w.ink, 0.045)

                                    HoverHandler {
                                        id: jobHover
                                        cursorShape: Qt.PointingHandCursor
                                    }

                                    StateLayer {
                                        anchors.fill: parent
                                        radius: parent.radius
                                        onClicked: {
                                            w.adoptExternal(modelData);
                                            w.setView("single");
                                        }
                                    }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.margins: Theme.dp(8)
                                        spacing: Theme.dp(10)

                                        ShapedImage {
                                            Layout.preferredWidth: Theme.dp(48)
                                            Layout.preferredHeight: Theme.dp(48)
                                            shape: "cookie6"
                                            source: {
                                                var p = modelData.crop_source || modelData.image || "";
                                                return p !== "" ? "file://" + p : "";
                                            }
                                            fallbackColor: Theme.alpha(w.ink, 0.08)
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.dp(2)

                                            LText {
                                                Layout.fillWidth: true
                                                role: "titleSmall"
                                                text: String(modelData.image || "").split("/").pop()
                                                color: w.ink
                                                elide: Text.ElideRight
                                            }

                                            LText {
                                                Layout.fillWidth: true
                                                role: "labelSmall"
                                                text: w.cleanStatus(modelData.text || modelData.phase || "running")
                                                color: w.inkFaint
                                                elide: Text.ElideRight
                                            }
                                        }

                                        IconButton {
                                            icon: "visibility"
                                            size: "xs"
                                            onClicked: {
                                                w.adoptExternal(modelData);
                                                w.setView("single");
                                            }
                                        }
                                    }
                                }
                            }

                            Repeater {
                                model: objects

                                delegate: Rectangle {
                                    id: row

                                    required property int index
                                    required property int oid
                                    required property string label
                                    required property string crop
                                    required property string kind
                                    required property string state
                                    required property real progress
                                    required property string preview
                                    required property string glb
                                    required property string note

                                    width: list.width
                                    height: Theme.dp(72)
                                    radius: Theme.rad(20)
                                    color: row.state === "running" ? Theme.alpha(Theme.primary, 0.10) : (rowHover.hovered && row.state === "done" ? Theme.alpha(w.ink, 0.10) : Theme.alpha(w.ink, 0.045))
                                    border.width: row.state === "running" ? Theme.dp(1) : 0
                                    border.color: Theme.alpha(Theme.primary, 0.35)
                                    scale: rowHover.hovered ? 1.015 : 1

                                    Behavior on color {
                                        ColorAnimation {
                                            duration: Theme.ms(160)
                                        }
                                    }
                                    Behavior on scale {
                                        NumberAnimation {
                                            duration: Theme.ms(150)
                                            easing.type: Easing.OutCubic
                                        }
                                    }

                                    HoverHandler {
                                        id: rowHover
                                        cursorShape: row.state === "done" ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    }

                                    StateLayer {
                                        anchors.fill: parent
                                        radius: row.radius
                                        enabled: row.state === "done"
                                        onClicked: w.reveal(row.glb)
                                    }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.margins: Theme.dp(8)
                                        spacing: Theme.dp(10)

                                        ShapedImage {
                                            Layout.preferredWidth: Theme.dp(54)
                                            Layout.preferredHeight: Theme.dp(54)
                                            shape: "cookie6"
                                            source: row.crop !== "" ? "file://" + row.crop : ""
                                            fallbackColor: Theme.alpha(w.ink, 0.08)
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.dp(3)

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: Theme.dp(6)

                                                LText {
                                                    role: "titleSmall"
                                                    text: row.label
                                                    color: w.ink
                                                    elide: Text.ElideRight
                                                    Layout.fillWidth: true
                                                }
                                                LText {
                                                    role: "labelSmall"
                                                    text: row.state === "done" ? "ready" : (row.state === "cancelled" ? "cancelled" : (row.state === "failed" ? "failed" : Math.round(row.progress * 100) + "%"))
                                                    color: row.state === "failed" ? Theme.error : w.inkFaint
                                                }
                                            }

                                            LinearProgress {
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: Theme.dp(5)
                                                value: row.state === "done" ? 1 : row.progress
                                                wavy: row.state === "running"
                                                animated: row.state === "running"
                                                color: row.state === "failed" ? Theme.error : Theme.primary
                                                trackColor: Theme.alpha(w.ink, 0.10)
                                            }

                                            LText {
                                                role: "labelSmall"
                                                text: row.note !== "" ? row.note : (row.state === "queued" ? "queued" : (row.state === "running" ? "building mesh" : (row.state === "cancelled" ? "cancelled" : "finished — click to open")))
                                                color: w.inkFaint
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                        }

                                        IconButton {
                                            icon: "deployed_code"
                                            size: "xs"
                                            visible: row.state === "done" && row.glb !== "" && w.width >= 360
                                            onClicked: {
                                                w.viewGlb = row.glb;
                                                w.viewLabel = row.label;
                                                w.viewPreview = row.preview;
                                                w.viewCrop = row.crop;
                                                w.showViewer = true;
                                            }
                                        }

                                        IconButton {
                                            icon: "close"
                                            size: "xs"
                                            visible: row.state === "queued" || row.state === "running"
                                            onClicked: w.cancelOne(row.oid)
                                        }

                                        Item {
                                            Layout.preferredWidth: Theme.dp(54)
                                            Layout.preferredHeight: Theme.dp(54)
                                            visible: row.state === "done" && w.width >= 400

                                            ShapedImage {
                                                anchors.fill: parent
                                                shape: "cookie12"
                                                source: row.preview !== "" ? "file://" + row.preview : ""
                                                fallbackColor: Theme.primaryContainer
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // the assembled scene
                    Item {
                        Layout.preferredWidth: Math.max(Theme.dp(150), parent.width * 0.32)
                        Layout.fillHeight: true
                        visible: w.phase === "done" && w.width >= 480

                        ColumnLayout {
                            anchors.fill: parent
                            spacing: Theme.dp(6)

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                radius: Theme.rad(28)
                                color: Theme.surfaceHighest
                                clip: true

                                Image {
                                    anchors.fill: parent
                                    source: w.scenePreview !== "" ? "file://" + w.scenePreview : ""
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }
                            }

                            LText {
                                Layout.fillWidth: true
                                role: "labelSmall"
                                text: "placement is approximate"
                                color: w.inkFaint
                            }
                        }
                    }
                }
            }

            // the whole card takes the drop
            DropArea {
                anchors.fill: parent
                keys: ["text/uri-list"]

                onEntered: (d) => {
                    w.dragging = true;
                    d.acceptProposedAction();
                }
                onExited: w.dragging = false
                onDropped: (d) => {
                    w.dragging = false;
                    if (d.urls && d.urls.length > 0)
                        w.selectImage(d.urls[0]);
                }
            }
        }
    }

    // a card-sized viewer for one finished piece
    Item {
        anchors.fill: parent
        visible: w.showViewer
        z: 50

        Rectangle {
            anchors.fill: parent
            radius: Theme.rad(28)
            color: Theme.alpha(Theme.bg, 0.94)

            Image {
                anchors.fill: parent
                anchors.margins: Theme.dp(6)
                source: {
                    if (w.viewPreview !== "")
                        return "file://" + w.viewPreview;
                    return w.viewCrop !== "" ? "file://" + w.viewCrop : "";
                }
                fillMode: Image.PreserveAspectFit
                asynchronous: true
            }

            MouseArea {
                anchors.fill: parent
                enabled: w.viewGlb !== ""
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: w.reveal(w.viewGlb)
            }

            LText {
                anchors.left: parent.left
                anchors.right: hint.left
                anchors.bottom: parent.bottom
                anchors.leftMargin: Theme.dp(14)
                anchors.rightMargin: Theme.dp(14)
                anchors.bottomMargin: Theme.dp(14)
                role: "labelMedium"
                text: w.viewLabel
                color: w.ink
                elide: Text.ElideRight
            }

            LText {
                id: hint

                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Theme.dp(14)
                role: "labelSmall"
                text: "drag to orbit · scroll to zoom"
                color: w.inkFaint
            }

            IconButton {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.dp(10)
                icon: "close"
                variant: "tonal"
                onClicked: w.showViewer = false
            }
        }
    }

    // ------------------------------------------------------------------ helpers
    function objectsDoneId() {
        for (var i = 0; i < objects.count; i++) {
            if (objects.get(i).state === "done")
                return objects.get(i).oid;
        }
        return -1;
    }

    Process {
        id: picker

        running: false
        command: ["zenity", "--file-selection", "--file-filter=Images | *.png *.jpg *.jpeg *.webp"]

        stdout: SplitParser {
            onRead: (line) => {
                if (line && line.length > 0)
                    w.selectImage(line.trim());
            }
        }
    }

    Process {
        id: scanner

        running: false
        command: ["bash", w.scanTool]

        stdout: StdioCollector {
            onStreamFinished: {
                var out = [];
                var lines = String(this.text || "").split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i].trim();
                    if (line === "")
                        continue;
                    try {
                        out.push(JSON.parse(line));
                    } catch (e) {}
                }

                var mine = null;
                var live = null;
                var interrupted = null;
                var lastDone = null;
                for (var j = 0; j < out.length; j++) {
                    var e = out[j];
                    if (e.cancelled)
                        continue;
                    if (w.ignoredPid > 0 && e.pid === w.ignoredPid)
                        continue;
                    if (w.ignoredJob !== "" && e.job_id === w.ignoredJob)
                        continue;
                    var running = e.phase !== "done" && e.phase !== "failed" && e.phase !== "cancelled";
                    if ((w.jobPid > 0 && e.pid === w.jobPid)
                            || (w.jobId !== "" && e.job_id === w.jobId))
                        mine = e;
                    if (e.alive && running && (live === null || (e.started || 0) > (live.started || 0)))
                        live = e;
                    if (!e.alive && running && (e.resume_attempts || 0) < 2
                            && e.image === w.source
                            && Date.now() / 1000 - (e.started || 0) < 86400
                            && (interrupted === null || (e.started || 0) > (interrupted.started || 0)))
                        interrupted = e;
                    if (e.phase === "done" && (lastDone === null || (e.started || 0) > (lastDone.started || 0)))
                        lastDone = e;
                }

                var nextExternal = out.filter(function (e) {
                    return e.alive && e.pid !== w.jobPid
                        && e.phase !== "done" && e.phase !== "failed" && e.phase !== "cancelled";
                });
                var externalSig = JSON.stringify(nextExternal.map(function (e) {
                    return [e.job_id || "", e.pid, e.phase, e.image || "", e.text || ""];
                }));
                if (externalSig !== w.externalSig) {
                    w.externalSig = externalSig;
                    w.external = nextExternal;
                }

                if (mine !== null) {
                    w.mirror(mine);
                    if (mine.phase === "done" || mine.phase === "failed" || mine.phase === "cancelled") {
                        w.settleDone(mine);
                        return ;
                    }
                    var unfinished = mine.phase !== "done" && mine.phase !== "failed" && mine.phase !== "cancelled";
                    if (!mine.alive && unfinished && mine.image === w.source) {
                        if (!w.resumeChecked && (mine.resume_attempts || 0) < 2) {
                            w.resumeChecked = true;
                            w.resumeJob(mine);
                        } else if (w.phase === "running" && (mine.resume_attempts || 0) >= 2) {
                            w.tracking = false;
                            w.phase = "failed";
                            w.statusText = "interrupted — start again";
                        }
                    }
                    return ;
                }
                if (w.tracking && w.jobId !== "") {
                    // the old service removed its registry file on completion;
                    // ask the job directory, not a missing file
                    if (!w.finishChecking
                            && Date.now() - w.jobStartedAt > 4000
                            && (w.jobDir !== "" || w.jobPid > 0)) {
                        w.finishChecking = true;
                        finishCheck.running = true;
                    }
                    return ;
                }
                if (w.jobId === "" && live !== null
                        && (w.source === "" || live.image === w.source)) {
                    w.adoptExternal(live);
                    return ;
                }
                if (w.jobId === "" && interrupted !== null && !w.resumeChecked) {
                    w.resumeChecked = true;
                    w.resumeJob(interrupted);
                    return ;
                }
                if (lastDone !== null && w.phase !== "running"
                        && (w.source === "" || lastDone.image === w.source)) {
                    w.mirror(lastDone);
                    w.phase = "done";
                    w.settleDone(lastDone);
                }
            }
        }
    }

    Process {
        id: finishCheck

        running: false
        command: ["bash", "-lc", "if [ \"$1\" -gt 0 ] && kill -0 \"$1\" 2>/dev/null; then echo running; elif test -f \"$2/scene.glb\"; then echo scene; else echo gone; fi", "sh", String(w.jobPid), w.jobDir]

        stdout: StdioCollector {
            onStreamFinished: {
                w.finishChecking = false;
                var answer = String(this.text || "").trim();
                if (answer === "running")
                    return ;
                w.tracking = false;
                if (answer === "scene") {
                    w.sceneGlb = w.jobDir + "/scene.glb";
                    w.scenePreview = w.jobDir + "/scene_preview.png";
                    w.phase = "done";
                    w.statusText = "meshes placed";
                    w.pickCurrent();
                } else {
                    w.phase = "failed";
                    w.statusText = "interrupted — start again";
                }
            }
        }
    }

    Binding {
        target: SpatialWall
        property: "meshBusy"
        value: w.phase === "running" || w.tracking
        when: w.scannerEnabled
    }

    Timer {
        interval: (w.phase === "running" || w.tracking) ? 500 : 4000
        running: w.scannerEnabled
        repeat: true
        triggeredOnStart: true
        onTriggered: w.scanExternal()
    }

    Process {
        id: canceller

        running: false

        function cancel(pid, id) {
            if (!pid || pid <= 0)
                return ;
            var all = (id === undefined || id === null);
            var name = all ? "all" : String(id);
            var script = "touch \"$0/cancel-" + pid + "-" + name + "\"";
            if (all)
                script += " && touch \"$0/cancelled-" + pid + "\"";
            command = ["bash", "-lc", script, w.home + "/.cache/lucid-mesh"];
            running = true;
        }
    }

    Component.onCompleted: {
        // Open on the last image instead of an empty drop surface. It is only
        // staged: nothing runs until the start button is pressed.
        var last = w.opt("last");
        if (last && last !== "") {
            w.source = last;
            w.sourceImage = last;
            w.curState = "ready";
        }
    }

    Component.onDestruction: {
        // The binding above disappears with this card; do not leave the spatial
        // wallpaper disabled if the card is removed while a job is running.
        if (w.scannerEnabled)
            SpatialWall.meshBusy = false;
    }
}
