import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
pragma Singleton

// A soundtrack for every wallpaper, pulled from YouTube and kept quiet under
// everything else. The lists live beside the widget store, keyed by the same
// wallpaper key the boards use, so switching wallpaper switches the score.
//
// Every track for the wallpaper plays at the same time. A helper script
// (scripts/ambience-play.sh) fetches anything missing into a local cache and
// starts one looping mpv per track, all at once. Going through mpv's own ytdl
// hook put the stream in ffmpeg's hands, which on some networks cannot reach
// YouTube's media hosts even when yt-dlp can; the cache also makes looping and
// a second pass free.
//
// A wallpaper change starts the new group while the old one is still playing.
// When the new group has prepared, both crossfade over five seconds: the old
// group is asked to stop and fades itself out, the new group fades itself in.
//
// Playback is automatic. There is no transport anywhere.
Singleton {
    id: root

    readonly property string storePath: Quickshell.env("HOME") + "/.config/quickshell/lucidwidgets/ambience.json"
    readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/quickshell/lucid-ambience"
    readonly property string playerScript: Quickshell.shellPath("scripts/ambience-play.sh")
    readonly property string volumeScript: Quickshell.shellPath("scripts/ambience-volume.py")
    readonly property string titleScript: Quickshell.shellPath("scripts/ambience-title.sh")
    readonly property string headScript: Quickshell.shellPath("scripts/ambience-heads.sh")
    readonly property string browserScript: Quickshell.shellPath("scripts/ambience-browser.py")
    // each layer plays at this volume unless its own row says otherwise
    readonly property int volume: 50

    // ---- ducking ----------------------------------------------------------
    // the score gets out of the way of anything else making sound: three
    // quarters of its mix while another stream is audible, one and a half
    // times the mix when it is alone. Stored row volumes are never rewritten; this is a gain
    // applied on top when values go to mpv, so the sliders keep meaning the
    // user's own mix.
    readonly property real duckedGain: 0.75
    readonly property real soloGain: 1.5
    readonly property real duckThreshold: 0.002
    // whether another stream has been audible long enough to duck under
    property bool ducked: false
    // what the browser's own pages say is playing: pwa, other, both, none,
    // or unavailable when the debugging port cannot be read
    property string browserAudio: "unavailable"
    // a short click or notification must not pump the whole soundtrack, but
    // real playback should be picked up almost at once
    readonly property int duckAttackMs: 120
    readonly property int duckReleaseMs: 500
    property double loudSince: 0
    property double lastHeard: 0
    // animated so the jump between three quarters and one and a half is not a jolt
    property real duckGain: 1.5

    // our own players must never count as another app, but Lucid UI sounds and
    // Quickshell audio do now. Bucklespring stays out too, and so do the
    // recorder's loopback streams, which are a copy of the mix rather than a
    // second thing playing.
    readonly property string playerPrefix: "Lucid Ambience "
    readonly property var ignoredAudioPrefixes: ["buckle", "lucidshot-"]

    function ignoredStream(n) {
        if (!n)
            return true;

        var props = n.properties || ({});
        var app = String(props["application.name"] || "");
        var node = String(n.name || "");
        if (app.indexOf(root.playerPrefix) === 0 || node.indexOf(root.playerPrefix) === 0)
            return true;

        var names = [props["application.name"], props["application.process.binary"], props["node.name"], props["media.name"], n.name];
        for (var i = 0; i < names.length; i++) {
            var s = String(names[i] || "").toLowerCase();
            if (s === "")
                continue;

            for (var j = 0; j < root.ignoredAudioPrefixes.length; j++) {
                if (s.indexOf(root.ignoredAudioPrefixes[j]) === 0)
                    return true;
            }
        }
        return false;
    }

    // YouTube Music's installed PWA runs inside Helium and shares Helium's
    // audio client, so it can only be recognised by its app window. The PWA
    // title is static and its media session may be taken over by another tab,
    // so the window plus an audible-stream count is what identifies it.
    readonly property string ytMusicWindow: {
        var list = (Hyprland.toplevels && Hyprland.toplevels.values) ? Hyprland.toplevels.values : [];
        for (var i = 0; i < list.length; i++) {
            var ipc = list[i] ? list[i].lastIpcObject : null;
            if (!ipc)
                continue;

            var title = String(ipc.title || "");
            var cls = String(ipc.class || ipc.initialClass || "");
            if (cls.indexOf("chrome-") === 0 && title.indexOf("YouTube Music") >= 0)
                return title;
        }
        return "";
    }

    // every other playback stream, without the ambience's own players
    readonly property var externalStreams: {
        var list = Audio.playbackStreams || [];
        var out = [];
        for (var i = 0; i < list.length; i++) {
            if (!root.ignoredStream(list[i]))
                out.push(list[i]);
        }
        return out;
    }

    // how many other streams are actually making sound right now
    readonly property int audibleExternalCount: {
        var count = 0;
        var list = (otherPeaks && otherPeaks.instances) ? otherPeaks.instances : [];
        for (var i = 0; i < list.length; i++) {
            var p = list[i] ? list[i].peak : 0;
            if (typeof p === "number" && p > root.duckThreshold)
                count += 1;
        }
        return count;
    }

    // the only case where another app is audible yet the score should stay up:
    // the YouTube Music PWA window is open while exactly one browser stream is
    // making sound and nothing else is. Two browser tabs playing still ducks.
    readonly property bool pwaOnlyAudio: {
        var list = root.externalStreams;
        var peaks = (otherPeaks && otherPeaks.instances) ? otherPeaks.instances : [];
        var browserAudible = 0;
        var otherAudible = 0;
        for (var i = 0; i < list.length; i++) {
            var p = peaks[i] ? peaks[i].peak : 0;
            if (!(typeof p === "number" && p > root.duckThreshold))
                continue;

            var props = list[i].properties || ({});
            var app = String(props["application.name"] || "").toLowerCase();
            if (app.indexOf("helium") === 0 || app.indexOf("chromium") === 0 || app.indexOf("chrome") === 0)
                browserAudible += 1;
            else
                otherAudible += 1;
        }

        // any non-browser source always ducks
        if (otherAudible > 0)
            return false;

        // the DevTools helper knows which page is really playing
        if (root.browserAudio === "both" || root.browserAudio === "other" || root.browserAudio === "none")
            return false;
        if (root.browserAudio === "pwa")
            return browserAudible <= 1;

        // helper unavailable: fall back to the PWA window and one stream
        if (root.ytMusicWindow === "")
            return false;
        return browserAudible === 1;
    }

    // the loudest of the other streams right now
    readonly property real otherPeak: {
        var best = 0;
        var list = (otherPeaks && otherPeaks.instances) ? otherPeaks.instances : [];
        for (var i = 0; i < list.length; i++) {
            var p = list[i] ? list[i].peak : 0;
            if (typeof p === "number" && p > best)
                best = p;
        }
        return best;
    }

    // the PWA alone should not lower the score, but any other audible source
    // still should
    readonly property real effectivePeak: root.pwaOnlyAudio ? 0 : root.otherPeak

    // the gain the duck state settles on. Kept as a function because a binding
    // read from onDuckedChanged can still be one step behind the change.
    function settledGain() {
        return root.ducked ? root.duckedGain : root.soloGain;
    }

    onDuckedChanged: root.duckGain = root.settledGain()
    onDuckGainChanged: root.pushGain()
    // react on the peak itself, not only on the next watch tick, so a source
    // starting up is caught as soon as its first buffer is metered
    onOtherPeakChanged: root.sampleDuck()

    Behavior on duckGain {
        NumberAnimation {
            duration: 2000
            // most of the travel happens early, so the score reacts as soon
            // as the change is detected while still settling smoothly
            easing.type: Easing.OutCubic
        }

    }

    // the sound modes, in the order the row icon cycles through them. "dry" is
    // the unprocessed baseline; the rest are ten real filters.
    readonly property var modes: [{
        "id": "dry",
        "label": "Dry",
        "icon": "graphic_eq",
        "filter": ""
    }, {
        "id": "room",
        "label": "Next room",
        "icon": "window",
        "filter": "lowpass=f=650"
    }, {
        "id": "hall",
        "label": "Hall",
        "icon": "blur_on",
        "filter": "aecho=0.8:0.88:80|160:0.4|0.2"
    }, {
        "id": "cave",
        "label": "Cave",
        "icon": "dark_mode",
        "filter": "aecho=0.8:0.9:220|440|660:0.5|0.35|0.2"
    }, {
        "id": "phone",
        "label": "Telephone",
        "icon": "call",
        "filter": "highpass=f=450,lowpass=f=3000"
    }, {
        "id": "water",
        "label": "Underwater",
        "icon": "water_drop",
        "filter": "lowpass=f=550,aecho=0.8:0.9:260:0.35"
    }, {
        "id": "vinyl",
        "label": "Vinyl",
        "icon": "album",
        "filter": "highpass=f=250,lowpass=f=4500,acrusher=bits=12:mix=0.2"
    }, {
        "id": "wide",
        "label": "Wide",
        "icon": "headphones",
        "filter": "stereowiden=delay=18:feedback=0.3:crossfeed=0.3:drymix=0.8"
    }, {
        "id": "slow",
        "label": "Slow",
        "icon": "nightlight",
        "filter": "asetrate=41013,aresample=44100"
    }, {
        "id": "warm",
        "label": "Warm",
        "icon": "speaker",
        "filter": "bass=g=5:f=120:w=0.6,treble=g=-2:f=6000"
    }, {
        "id": "bright",
        "label": "Bright",
        "icon": "wb_sunny",
        "filter": "treble=g=5:f=6000,highpass=f=80"
    }]

    // the wallpaper the desktop is showing, and its own list
    readonly property string wallpaperKey: Widgets.boardKey
    readonly property var tracks: {
        var list = root.library[root.wallpaperKey];
        return Array.isArray(list) ? list : [];
    }
    readonly property int count: root.tracks.length
    readonly property bool hasTracks: root.count > 0
    readonly property string wallpaperName: {
        var k = root.wallpaperKey;
        if (k === "")
            return "this wallpaper";

        var base = String(k).split("/").pop();
        try {
            base = decodeURIComponent(base);
        } catch (e) {}
        base = base.replace(/\.[A-Za-z0-9]+$/, "").replace(/[_-]+/g, " ").trim();
        return base === "" ? "this wallpaper" : base;
    }

    // wallpaper key -> [{ id, url, title, volume, mode }]
    property var library: ({})
    // reusable track lists, global across wallpapers
    property var presets: []
    property bool loaded: false
    property bool enabled: true

    // what the group of players is doing right now
    property bool playing: false
    property bool preparing: false
    // how many files actually made it to disk and started
    property int audible: 0
    property string error: ""

    // a group of players is one Process; two slots let the old group fade out
    // while the new one fades in
    property var activeSlot: null
    property var retiringSlot: null
    property int activeToken: 0
    property int tokenSeq: 0
    property var pendingList: null
    property string activeSig: ""
    property bool cleaned: false
    // the script pid of the group whose live volumes can be nudged
    property string activeGroup: ""
    property string pendingGroup: ""
    property string volumeGroup: ""
    property var launchedModes: []
    property bool modesPending: false
    // players appended to the live group after it started; they are not part
    // of the group script's own child list, so keep their count separately
    property int activeExtra: 0
    // library row -> the group's socket index for that player. Removing a row
    // shifts the library but leaves the other players on their own sockets.
    property var liveOrder: []
    property int groupCount: 0
    // the background prefix builder is running or has new tracks to cover
    property bool headDirty: false
    property var pendingFilters: ({})

    // the little title fetch queue, so pasting several links stays orderly
    property var titleQueue: []
    property string titleUrl: ""
    property string titleText: ""

    onWallpaperKeyChanged: root.retune()
    onEnabledChanged: root.retune()
    onPlayingChanged: root.syncLevels()
    Component.onCompleted: {
        // a reload can reuse this singleton; clear the old group before the
        // startup cleaner runs so a fresh group is not started into its pkill
        root.activeSlot = null;
        root.retiringSlot = null;
        root.activeToken = 0;
        root.pendingList = null;
        root.stopVolumeControl();
        root.playing = false;
        root.preparing = false;
        root.audible = 0;
        root.error = "";
        root.activeSig = "";
        root.launchedModes = [];
        root.liveOrder = [];
        root.groupCount = 0;
        root.modesPending = false;
        root.activeExtra = 0;
        root.cleaned = false;
        cleanupPlayers.running = true;
        root.retune();
    }
    Component.onDestruction: {
        Cava.drop("ambience-levels");
        root.stop();
    }

    // the board key can be restored from the widget file a beat before the
    // wallpaper caches have both spoken; waiting avoids a short burst of the
    // previous wallpaper's score at start-up
    Connections {
        function onLoadedChanged() {
            root.retune();
        }

        function onWallpaperLoadedChanged() {
            root.retune();
        }

        target: Widgets
    }

    function signature(list) {
        var out = [];
        for (var i = 0; i < list.length; i++) out.push(list[i].url)
        return out.join("\n");
    }

    // a change that only appended tracks can be grown in place; anything else
    // still goes through the crossfading group restart
    function appendedOnly(oldList, newList) {
        if (!Array.isArray(oldList) || !Array.isArray(newList))
            return false;

        if (newList.length <= oldList.length)
            return false;

        for (var i = 0; i < oldList.length; i++) {
            if (oldList[i].url !== newList[i].url)
                return false;
        }
        return true;
    }

    // a change that only removed rows, keeping the rest in order. Returns the
    // old-list indices that are gone, or null when this is not a pure removal.
    function removedOnly(oldList, newList) {
        if (!Array.isArray(oldList) || !Array.isArray(newList))
            return null;

        if (newList.length >= oldList.length)
            return null;

        var removed = [];
        var j = 0;
        for (var i = 0; i < oldList.length; i++) {
            if (j < newList.length && oldList[i].url === newList[j].url) {
                j += 1;
            } else {
                removed.push(i);
            }
        }
        return j === newList.length ? removed : null;
    }

    function canGrowLive(oldList) {
        if (!root.playing || root.preparing || root.retiringSlot !== null)
            return false;

        if (root.activeGroup === "" || root.launchedModes.length !== oldList.length || root.liveOrder.length !== oldList.length)
            return false;

        return root.activeSig === (root.wallpaperKey + "\n" + root.signature(oldList));
    }

    function addToRunning(oldList, newList) {
        if (root.activeGroup === "")
            return false;

        var added = newList.length - oldList.length;
        var modes = root.launchedModes.slice();
        var order = root.liveOrder.slice();
        var next = 0;
        for (var k = 0; k < order.length; k++) next = Math.max(next, order[k] + 1);
        for (var i = oldList.length; i < newList.length; i++) {
            var t = newList[i];
            var m = root.modeInfo(t.mode);
            var spec = t.id + ";" + t.url + ";" + t.volume + ";" + m.filter;
            // one extra mpv in the same group, with the next socket index; the
            // group's own players are not touched
            Quickshell.execDetached(["sh", root.playerScript, "--add", root.cacheDir, root.activeGroup, String(next), root.duckGain.toFixed(4), spec]);
            modes.push(m.id);
            order.push(next);
            next += 1;
        }

        root.liveOrder = order;
        root.launchedModes = modes;
        root.activeExtra += added;
        root.audible = Math.min(root.count, root.audible + added);
        root.activeSig = root.wallpaperKey + "\n" + root.signature(newList);
        root.modesPending = false;
        root.pushVolumes();
        if (volumeProc.running && root.activeGroup !== "" && root.volumeGroup === root.activeGroup)
            root.pushModes();
        else
            root.modesPending = true;

        return true;
    }

    // A player that is still starting has no socket yet, so a quit alone can
    // miss it. Poll the per-track client name briefly and kill it when it
    // appears. The bracket stops the watchdog matching its own command line.
    function watchRemovedTrack(group, track) {
        if (group === "" || !track)
            return ;

        var id = String(track.id || root.videoId(track.url));
        if (id === "")
            return ;

        var prefix = "Lucid Ambience " + group + " " + id;
        var pattern = prefix.substring(0, prefix.length - 1) + "[" + prefix.slice(-1) + "]";
        Quickshell.execDetached(["sh", "-c", 'sleep 0.3; for i in $(seq 1 25); do pkill -f -- "$1" && exit 0; sleep 0.12; done', "lucid-ambience-remove", pattern]);
    }

    function removeFromRunning(oldList, newList, removed) {
        if (root.activeGroup === "" || !volumeProc.running || root.volumeGroup !== root.activeGroup)
            return false;

        var order = root.liveOrder.slice();
        var modes = root.launchedModes.slice();
        var extras = 0;
        for (var k = removed.length - 1; k >= 0; k--) {
            var at = removed[k];
            if (at < 0 || at >= order.length)
                continue;

            var sock = order[at];
            if (sock >= root.groupCount)
                extras += 1;

            root.watchRemovedTrack(root.activeGroup, oldList[at]);

            // mpv's own quit, after muting this one player; the rest keep
            // their sockets and positions
            volumeProc.write("q " + sock + "\n");
            order.splice(at, 1);
            modes.splice(at, 1);
        }

        root.liveOrder = order;
        root.launchedModes = modes;
        root.activeExtra = Math.max(0, root.activeExtra - extras);
        root.audible = Math.max(0, root.audible - removed.length);
        root.activeSig = root.wallpaperKey + "\n" + root.signature(newList);
        root.modesPending = false;
        root.pushVolumes();
        root.pushModes();

        if (newList.length === 0) {
            // let the helper read the quits before the group is torn down
            root.activeSig = root.wallpaperKey + "\n" + root.signature(newList);
            removeStop.restart();
        }
        return true;
    }

    // The card no longer draws a spectrum: the silhouette Shape and the 40 ms
    // tick that fed it were removed, so nothing consumes these bands. Keeping
    // the demand would spawn a cava process with no reader.
    function syncLevels() {
        Cava.drop("ambience-levels");
    }

    // called a few times a second while some other stream exists. The peak
    // has to stay up through the attack window, so a keystroke or a one-shot
    // notification does not duck the score; it then stays ducked through the
    // quiet gaps of speech until the other stream has been silent for a while.
    function sampleDuck() {
        var now = Date.now();
        if (root.effectivePeak > root.duckThreshold) {
            root.lastHeard = now;
            if (root.loudSince === 0)
                root.loudSince = now;
            if (!root.ducked && now - root.loudSince >= root.duckAttackMs)
                root.ducked = true;
        } else {
            root.loudSince = 0;
            if (root.ducked && now - root.lastHeard >= root.duckReleaseMs)
                root.ducked = false;
        }
    }

    function videoId(raw) {
        var s = String(raw || "").trim();
        if (/^[A-Za-z0-9_-]{11}$/.test(s))
            return s;

        var m = s.match(/(?:v=|youtu\.be\/|shorts\/|embed\/|live\/|\/v\/)([A-Za-z0-9_-]{11})/);
        return m ? m[1] : "";
    }

    function normalise(raw) {
        var id = root.videoId(raw);
        return id === "" ? "" : "https://www.youtube.com/watch?v=" + id;
    }

    function cleanTrack(t) {
        if (!t || typeof t.url !== "string")
            return null;

        var url = root.normalise(t.url);
        if (url === "")
            return null;

        var title = (typeof t.title === "string" && t.title.trim() !== "") ? t.title.trim() : "YouTube audio";
        var volume = (typeof t.volume === "number" && isFinite(t.volume)) ? Math.max(0, Math.min(100, Math.round(t.volume))) : root.volume;
        var mode = "dry";
        if (typeof t.mode === "string") {
            for (var j = 0; j < root.modes.length; j++) {
                if (root.modes[j].id === t.mode) {
                    mode = t.mode;
                    break;
                }
            }
        }
        return {
            "id": root.videoId(url),
            "url": url,
            "title": title,
            "volume": volume,
            "mode": mode
        };
    }

    function uniqueTracks(list) {
        var out = [];
        var seen = {};
        for (var i = 0; i < list.length; i++) {
            var t = root.cleanTrack(list[i]);
            if (t === null || seen[t.url] === true)
                continue;

            seen[t.url] = true;
            out.push(t);
        }
        return out;
    }

    function retune() {
        if (!root.loaded || !root.cleaned || !Widgets.loaded || !Widgets.wallpaperLoaded)
            return ;

        // read the list straight from the store: this runs from the board's
        // change signal and from setTracks, where the tracks binding may not
        // have been re-evaluated yet
        var stored = root.library[root.wallpaperKey];
        var list = (root.enabled && Array.isArray(stored)) ? stored : [];
        var sig = root.wallpaperKey + "\n" + root.signature(list);
        if (sig === root.activeSig)
            return ;

        root.activeSig = sig;
        if (list.length === 0) {
            root.stop(false);
            root.activeSig = sig;
            return ;
        }
        root.requestPlayback(list);
    }

    function slots() {
        return [slotA, slotB];
    }

    function freeSlot() {
        var list = root.slots();
        for (var i = 0; i < list.length; i++) {
            var s = list[i];
            if (s !== root.activeSlot && s !== root.retiringSlot && !s.running)
                return s;
        }
        return null;
    }

    function requestPlayback(list) {
        root.pendingList = list.slice();
        root.tryStart();
    }

    function tryStart() {
        if (root.pendingList === null)
            return ;

        var slot = root.freeSlot();
        if (!slot)
            return ;

        var list = root.pendingList;
        root.pendingList = null;
        root.startGroup(slot, list);
    }

    function startGroup(slot, list) {
        if (list.length === 0) {
            root.stop();
            return ;
        }

        root.tokenSeq += 1;
        var token = root.tokenSeq;
        slot.token = token;
        slot.group = "";

        var old = root.activeSlot;
        root.activeSlot = slot;
        root.activeToken = token;
        // the old group keeps playing until this one reports ready; then both
        // fade over five seconds
        root.retiringSlot = old;

        root.preparing = true;
        root.playing = false;
        root.audible = 0;
        root.error = "";
        root.activeSig = root.wallpaperKey + "\n" + root.signature(list);
        // the old group is still audible while this one prepares; its live
        // volume control is no longer the list on screen
        root.stopVolumeControl();
        volumeSettle.stop();
        root.launchedModes = list.map((t) => {
            return (typeof t.mode === "string") ? t.mode : "dry";
        });
        root.liveOrder = list.map((t, i) => i);
        root.groupCount = list.length;
        root.modesPending = false;
        root.activeExtra = 0;

        var command = ["sh", root.playerScript, root.cacheDir, root.settledGain().toFixed(4)];
        for (var i = 0; i < list.length; i++) {
            var m = root.modeInfo(list[i].mode);
            command.push(list[i].id + ";" + list[i].url + ";" + list[i].volume + ";" + m.filter);
        }
        slot.command = command;
        slot.running = true;
    }

    function slotReady(slot, count) {
        if (slot !== root.activeSlot || slot.token !== root.activeToken)
            return ;

        root.preparing = false;
        root.playing = true;
        root.audible = Math.min(root.count, count + root.activeExtra);
        root.error = "";
        root.activeGroup = slot.group;
        root.startVolumeControl();
        root.modesPending = root.modesPending || root.modesDiffer();
        root.flushModes();
        volumeSettle.restart();

        // now that the new group is on, let the old one fade away
        var old = root.retiringSlot;
        root.retiringSlot = null;
        if (old && old !== slot && old.running)
            old.running = false;

    }

    function slotEmpty(slot) {
        if (slot !== root.activeSlot || slot.token !== root.activeToken)
            return ;

        root.error = "Couldn't prepare this wallpaper's tracks";
    }

    function slotFinished(slot, code) {
        if (slot === root.retiringSlot) {
            root.retiringSlot = null;
            root.tryStart();
            return ;
        }

        if (slot === root.activeSlot) {
            var old = root.retiringSlot;
            root.retiringSlot = null;
            if (old && old !== slot && old.running)
                old.running = false;

            var wasPlaying = root.playing;
            root.activeSlot = null;
            root.activeToken = 0;
            root.playing = false;
            root.preparing = false;
            root.stopVolumeControl();
            volumeSettle.stop();
            root.launchedModes = [];
            root.liveOrder = [];
            root.groupCount = 0;
            root.modesPending = false;
            root.activeExtra = 0;
            if (code !== 0 || root.audible === 0)
                root.error = "Couldn't play this wallpaper's soundtrack";
            else if (wasPlaying)
                root.error = "Playback stopped";

            root.tryStart();
            return ;
        }

        // a slot that stop() already released
        root.tryStart();
    }

    function stop(clearSig) {
        root.pendingList = null;
        if (root.activeSlot && root.activeSlot.running)
            root.activeSlot.running = false;
        if (root.retiringSlot && root.retiringSlot.running)
            root.retiringSlot.running = false;

        root.activeSlot = null;
        root.retiringSlot = null;
        root.activeToken = 0;
        root.playing = false;
        root.preparing = false;
        root.audible = 0;
        root.error = "";
        root.stopVolumeControl();
        volumeSettle.stop();
        root.launchedModes = [];
        root.liveOrder = [];
        root.groupCount = 0;
        root.modesPending = false;
        root.activeExtra = 0;
        if (clearSig !== false)
            root.activeSig = "";

    }

    function addTrack(raw) {
        if (!root.loaded) {
            root.error = "Still loading";
            return false;
        }
        if (root.wallpaperKey === "") {
            root.error = "Waiting for a wallpaper";
            return false;
        }

        var url = root.normalise(raw);
        if (url === "") {
            root.error = "Paste a YouTube link";
            return false;
        }

        var list = root.tracks.slice();
        for (var i = 0; i < list.length; i++) {
            if (list[i].url === url) {
                root.error = "Already on this wallpaper";
                return false;
            }
        }
        list.push({
            "id": root.videoId(url),
            "url": url,
            "title": "YouTube audio",
            "volume": root.volume,
            "mode": "dry"
        });
        root.error = "";
        root.setTracks(root.wallpaperKey, list);
        root.fetchTitle(url);
        return true;
    }

    function removeTrack(index) {
        if (index < 0 || index >= root.count)
            return ;

        var list = root.tracks.slice();
        list.splice(index, 1);
        root.error = "";
        root.setTracks(root.wallpaperKey, list);
    }

    function clearTracks() {
        if (root.wallpaperKey === "")
            return ;

        root.error = "";
        root.setTracks(root.wallpaperKey, []);
    }

    // every track gets a small cached prefix, even when it has never played;
    // switching wallpapers then starts from that prefix while the real stream
    // is opened behind it
    function scheduleHeads() {
        if (!root.loaded)
            return ;

        if (headProc.running) {
            root.headDirty = true;
            return ;
        }

        var specs = [];
        var seen = {};
        for (var key in root.library) {
            var list = root.library[key];
            if (!Array.isArray(list))
                continue;

            for (var i = 0; i < list.length; i++) {
                var t = list[i];
                if (!t || typeof t.url !== "string" || t.url === "" || seen[t.url] === true)
                    continue;

                seen[t.url] = true;
                specs.push((t.id || root.videoId(t.url)) + ";" + t.url);
            }
        }
        if (specs.length === 0)
            return ;

        root.headDirty = false;
        headProc.command = ["nice", "-n", "10", "sh", root.headScript, root.cacheDir].concat(specs);
        headProc.running = true;
    }

    function setTracks(key, list) {
        if (key === "")
            return ;

        var old = root.library[key];
        var clean = root.uniqueTracks(list);
        var grow = key === root.wallpaperKey && root.appendedOnly(old, clean) && root.canGrowLive(old);
        var gone = key === root.wallpaperKey ? root.removedOnly(old, clean) : null;
        var shrink = gone !== null && root.canGrowLive(old) && volumeProc.running && root.volumeGroup === root.activeGroup;

        var next = Object.assign({}, root.library);
        next[key] = clean;
        root.library = next;
        root.save();
        headSettle.restart();

        if (key !== root.wallpaperKey)
            return ;

        // adding or removing rows should not restart the layers that stay
        if (grow && root.addToRunning(old, clean))
            return ;
        if (shrink && root.removeFromRunning(old, clean, gone))
            return ;

        // even on the restart path, catch a player that is still starting
        if (!grow && !shrink && gone !== null && root.activeGroup !== "" && root.playing
                && root.activeSig === (root.wallpaperKey + "\n" + root.signature(old))) {
            for (var r = 0; r < gone.length; r++)
                root.watchRemovedTrack(root.activeGroup, old[gone[r]]);
        }

        root.retune();
    }

    function clearError() {
        if (root.error !== "")
            root.error = "";

    }

    // ---- presets ----------------------------------------------------------
    // a preset is a global copy of a wallpaper's whole running order. Loading
    // one adds its tracks to the current list; it never replaces what is there.

    function presetAt(id) {
        for (var i = 0; i < root.presets.length; i++) {
            if (root.presets[i].id === id)
                return root.presets[i];
        }
        return null;
    }

    function savePreset(name) {
        var list = root.tracks;
        if (list.length === 0)
            return "";

        var tracks = [];
        for (var i = 0; i < list.length; i++) {
            var t = list[i];
            tracks.push({
                "id": t.id,
                "url": t.url,
                "title": t.title,
                "volume": (typeof t.volume === "number") ? t.volume : root.volume,
                "mode": (typeof t.mode === "string") ? t.mode : "dry"
            });
        }
        var label = String(name || "").trim();
        if (label === "")
            label = "Preset " + (root.presets.length + 1);

        var id = "p" + Date.now() + Math.floor(Math.random() * 1000);
        var next = root.presets.slice();
        next.push({
            "id": id,
            "name": label,
            "tracks": tracks
        });
        root.presets = next;
        root.save();
        return id;
    }

    function deletePreset(id) {
        var next = [];
        var found = false;
        for (var i = 0; i < root.presets.length; i++) {
            if (root.presets[i].id === id) {
                found = true;
                continue;
            }
            next.push(root.presets[i]);
        }
        if (found) {
            root.presets = next;
            root.save();
        }
        return found;
    }

    function loadPreset(id) {
        var preset = root.presetAt(id);
        if (preset === null || root.wallpaperKey === "")
            return false;

        var current = root.tracks.slice();
        var seen = {};
        for (var i = 0; i < current.length; i++) seen[current[i].url] = true;

        var added = 0;
        for (var j = 0; j < preset.tracks.length; j++) {
            var t = root.cleanTrack(preset.tracks[j]);
            if (t === null || seen[t.url] === true)
                continue;

            seen[t.url] = true;
            current.push(t);
            added += 1;
        }
        root.error = "";
        root.setTracks(root.wallpaperKey, current);
        return added > 0;
    }

    // ---- per-track volume -------------------------------------------------
    // the rows are sliders: the fill is updated from the widget's draft while
    // the pointer is down, and these two calls push the value to the playing
    // mpv group and persist it for the next start.

    function setTrackVolume(index, value) {
        if (index < 0 || index >= root.count)
            return ;

        var v = Math.max(0, Math.min(100, Math.round(value)));
        var list = (root.library[root.wallpaperKey] || []).slice();
        if (index < 0 || index >= list.length)
            return ;

        var t = list[index];
        if (t.volume === v) {
            root.setVolumeLive(index, v);
            return ;
        }
        list[index] = {
            "id": t.id,
            "url": t.url,
            "title": t.title,
            "volume": v,
            "mode": t.mode
        };
        var next = Object.assign({}, root.library);
        next[root.wallpaperKey] = list;
        root.library = next;
        root.save();
        root.setVolumeLive(index, v);
    }

    // the widget's rows stay the user's own mix. The helper is told those
    // values and the automatic gain separately, so ducking never rewrites a
    // row, a preset, or anything the widget draws.
    function setVolumeLive(index, value) {
        if (!volumeProc.running || index < 0 || root.activeGroup === "" || root.volumeGroup !== root.activeGroup)
            return ;

        var v = Math.max(0, Math.min(100, Math.round(value)));
        var at = root.liveOrder[index];
        if (at === undefined)
            return ;

        volumeProc.write(at + " v " + v + "\n");
    }

    function pushVolumes() {
        if (!volumeProc.running || root.activeGroup === "" || root.volumeGroup !== root.activeGroup)
            return ;

        var list = root.library[root.wallpaperKey];
        if (!Array.isArray(list))
            return ;

        for (var i = 0; i < list.length; i++) {
            var at = root.liveOrder[i];
            if (at === undefined)
                continue;

            var v = (typeof list[i].volume === "number") ? list[i].volume : root.volume;
            volumeProc.write(at + " v " + v + "\n");
        }
    }

    function pushGain() {
        if (!volumeProc.running || root.activeGroup === "" || root.volumeGroup !== root.activeGroup)
            return ;

        volumeProc.write("g " + root.duckGain.toFixed(4) + "\n");
    }

    // ---- per-track sound mode ---------------------------------------------

    function modeInfo(id) {
        for (var i = 0; i < root.modes.length; i++) {
            if (root.modes[i].id === id)
                return root.modes[i];
        }
        return root.modes[0];
    }

    function modesDiffer() {
        if (root.launchedModes.length !== root.tracks.length)
            return true;

        for (var i = 0; i < root.tracks.length; i++) {
            if (root.modeInfo(root.tracks[i].mode).id !== root.launchedModes[i])
                return true;
        }
        return false;
    }

    function flushModes() {
        if (root.modesPending && volumeProc.running && root.activeGroup !== "" && root.volumeGroup === root.activeGroup) {
            root.modesPending = false;
            root.pushModes();
        }
    }

    function nextMode(id) {
        var at = 0;
        for (var i = 0; i < root.modes.length; i++) {
            if (root.modes[i].id === id) {
                at = i;
                break;
            }
        }
        return root.modes[(at + 1) % root.modes.length];
    }

    function cycleMode(index) {
        var list = root.library[root.wallpaperKey];
        if (!Array.isArray(list) || index < 0 || index >= list.length)
            return ;

        var next = root.nextMode(list[index].mode);
        root.setTrackMode(index, next.id);
    }

    function setFilterLive(index, filter) {
        if (!volumeProc.running || index < 0 || root.activeGroup === "" || root.volumeGroup !== root.activeGroup) {
            root.modesPending = true;
            return ;
        }
        // running through the modes quickly should only rebuild mpv's filter
        // chain once, on the mode the pointer stops on
        var at = root.liveOrder[index];
        if (at === undefined) {
            root.modesPending = true;
            return ;
        }

        var pending = Object.assign({}, root.pendingFilters);
        pending[at] = filter === "" ? "-" : filter;
        root.pendingFilters = pending;
        filterSettle.restart();
    }

    function pushModes() {
        if (!volumeProc.running || root.activeGroup === "" || root.volumeGroup !== root.activeGroup)
            return ;

        root.pendingFilters = ({});
        filterSettle.stop();
        var list = root.library[root.wallpaperKey];
        if (!Array.isArray(list))
            return ;

        for (var i = 0; i < list.length; i++) {
            var at = root.liveOrder[i];
            if (at === undefined)
                continue;

            var m = root.modeInfo(list[i].mode);
            volumeProc.write(at + " f " + (m.filter === "" ? "-" : m.filter) + "\n");
        }
    }

    function setTrackMode(index, modeId) {
        if (index < 0 || index >= root.count)
            return ;

        var info = root.modeInfo(modeId);
        var list = (root.library[root.wallpaperKey] || []).slice();
        if (index < 0 || index >= list.length)
            return ;

        var t = list[index];
        if (t.mode === info.id) {
            root.setFilterLive(index, info.filter);
            return ;
        }
        list[index] = {
            "id": t.id,
            "url": t.url,
            "title": t.title,
            "volume": t.volume,
            "mode": info.id
        };
        var next = Object.assign({}, root.library);
        next[root.wallpaperKey] = list;
        root.library = next;
        root.save();
        if (volumeProc.running && root.activeGroup !== "" && root.volumeGroup === root.activeGroup)
            root.setFilterLive(index, info.filter);
        else
            root.modesPending = true;

    }

    function startVolumeControl() {
        if (root.activeGroup === "")
            return ;

        if (volumeProc.running) {
            if (root.volumeGroup === root.activeGroup) {
                root.pushVolumes();
                return ;
            }
            root.pendingGroup = root.activeGroup;
            volumeProc.running = false;
            return ;
        }
        root.launchVolumeControl(root.activeGroup);
    }

    function launchVolumeControl(group) {
        if (group === "")
            return ;

        root.pendingGroup = "";
        root.volumeGroup = group;
        volumeProc.command = ["python3", root.volumeScript, root.cacheDir, group, root.settledGain().toFixed(4)];
        volumeProc.running = true;
    }

    function stopVolumeControl() {
        root.pendingGroup = "";
        root.activeGroup = "";
        root.volumeGroup = "";
        root.pendingFilters = ({});
        filterSettle.stop();
        if (volumeProc.running)
            volumeProc.running = false;

    }

    function fetchTitle(url) {
        if (url === "")
            return ;

        var q = root.titleQueue.slice();
        q.push({
            "url": url
        });
        root.titleQueue = q;
        root.pumpTitle();
    }

    function pumpTitle() {
        if (!root.loaded || titleProc.running || root.titleQueue.length === 0)
            return ;

        var q = root.titleQueue.slice();
        var job = q.shift();
        root.titleQueue = q;
        root.titleUrl = job.url;
        root.titleText = "";
        titleProc.command = ["sh", root.titleScript, job.url];
        titleProc.running = true;
    }

    function finishTitle() {
        var url = root.titleUrl;
        var lines = root.titleText.trim().split("\n").map((line) => {
            return line.trim();
        }).filter((line) => {
            return line !== "";
        });
        var title = lines.length > 0 ? lines[lines.length - 1] : "";
        root.titleUrl = "";
        root.titleText = "";
        if (url !== "" && title !== "")
            root.setTitle(url, title);

        root.pumpTitle();
    }

    function setTitle(url, title) {
        var next = {};
        var changed = false;
        for (var key in root.library) {
            var list = root.library[key];
            var out = [];
            for (var i = 0; i < list.length; i++) {
                if (list[i].url === url && list[i].title !== title) {
                    out.push({
                        "id": list[i].id,
                        "url": list[i].url,
                        "title": title,
                        "volume": list[i].volume,
                        "mode": list[i].mode
                    });
                    changed = true;
                } else {
                    out.push(list[i]);
                }
            }
            next[key] = out;
        }
        if (changed) {
            root.library = next;
            root.save();
        }
    }

    function restore(raw) {
        var data = null;
        try {
            data = JSON.parse(raw);
        } catch (e) {
            data = null;
        }

        var lib = {};
        if (data && data.wallpapers && typeof data.wallpapers === "object") {
            for (var key in data.wallpapers) {
                if (Array.isArray(data.wallpapers[key]))
                    lib[key] = root.uniqueTracks(data.wallpapers[key]);

            }
        }

        var saved = [];
        if (data && Array.isArray(data.presets)) {
            for (var i = 0; i < data.presets.length; i++) {
                var p = data.presets[i];
                if (!p || typeof p.id !== "string" || typeof p.name !== "string" || !Array.isArray(p.tracks))
                    continue;

                saved.push({
                    "id": p.id,
                    "name": p.name,
                    "tracks": root.uniqueTracks(p.tracks)
                });
            }
        }
        root.enabled = !data || data.enabled !== false;
        root.library = lib;
        root.presets = saved;
        root.loaded = true;
        root.retune();
        root.pumpTitle();
        // the file loads synchronously, before later children like the head
        // timer exist; defer the first prefix build until creation is done
        Qt.callLater(function () {
            headSettle.restart();
        });
    }

    function save() {
        if (root.loaded)
            saveTimer.restart();

    }

    function serialise() {
        return JSON.stringify({
            "version": 1,
            "enabled": root.enabled,
            "wallpapers": root.library,
            "presets": root.presets
        }, null, 2);
    }

    Timer {
        id: saveTimer

        interval: 300
        onTriggered: {
            if (root.loaded)
                storeFile.setText(root.serialise());

        }
    }

    FileView {
        id: storeFile

        path: root.storePath
        blockLoading: true
        printErrors: false
        onLoaded: root.restore(text())
        onLoadFailed: {
            root.loaded = true;
            root.retune();
        }
    }

    // only the final mode in a quick run should reach mpv
    Timer {
        id: filterSettle

        interval: 120
        onTriggered: {
            var pending = root.pendingFilters;
            root.pendingFilters = ({});
            if (!volumeProc.running || root.activeGroup === "" || root.volumeGroup !== root.activeGroup)
                return ;

            for (var key in pending) volumeProc.write(key + " f " + pending[key] + "\n")
        }
    }

    // the script's five-second fade uses the volumes it was started with; this
    // re-applies the stored values once that fade is over, catching a row that
    // was dragged while the new group was still preparing
    Timer {
        id: volumeSettle

        interval: 5200
        onTriggered: root.pushVolumes()
    }

    // the helper starts with the settled gain, but a duck change can land
    // while its stdin is still coming up; send the live value once more
    Timer {
        id: gainSync

        interval: 180
        onTriggered: root.pushGain()
    }

    Timer {
        id: removeStop

        interval: 500
        onTriggered: {
            if (root.count === 0)
                root.stop(false);
        }
    }

    // ask the browser itself which page is playing. The YouTube Music PWA and
    // ordinary tabs share Helium's audio client, so PipeWire cannot tell them
    // apart; the DevTools target list can.
    Process {
        id: browserProc

        running: true
        command: ["python3", root.browserScript]

        stdout: SplitParser {
            onRead: (line) => {
                var s = String(line).trim();
                if (s !== "")
                    root.browserAudio = s;

            }
        }

        onExited: browserRetry.restart()
    }

    Timer {
        id: browserRetry

        interval: 3000
        onTriggered: browserProc.running = true
    }

    // build the cached prefixes in the background; a switch can then start
    // from one while the real stream is opened behind it
    Process {
        id: headProc

        running: false

        stderr: SplitParser {
            onRead: (line) => {
                var s = String(line).trim();
                if (s.toLowerCase().indexOf("error") >= 0)
                    console.log("ambience heads: " + s);

            }
        }

        onExited: {
            if (root.headDirty)
                headSettle.restart();

        }
    }

    Timer {
        id: headSettle

        interval: 4000
        onTriggered: root.scheduleHeads()
    }

    // one peak meter per other playback stream. Audio already keeps every
    // playback node open, so these can attach straight to it.
    Variants {
        id: otherPeaks

        model: root.externalStreams

        delegate: Component {
            PwNodePeakMonitor {
                required property var modelData

                node: modelData
                enabled: true
            }

        }

    }

    Timer {
        id: duckWatch

        interval: 80
        repeat: true
        running: root.externalStreams.length > 0 || root.ducked
        onTriggered: root.sampleDuck()
    }

    // a previous shell may have been killed hard enough that its player groups
    // survived. clear them once before this shell starts its own group.
    Process {
        id: cleanupPlayers

        running: false
        // brackets keep pkill from matching this cleanup's own command line;
        // killing the old scripts first stops them starting one last loop
        command: ["sh", "-c", "pkill -f -- '[a]mbience-play.sh' 2>/dev/null; pkill -f -- '[a]mbience-fade.py' 2>/dev/null; pkill -f -- '[a]mbience-volume.py' 2>/dev/null; pkill -f -- '[-]-audio-client-name=Lucid Ambience' 2>/dev/null; rm -f \"$1\"/ambience-*.sock; exit 0", "lucid-ambience-clean", root.cacheDir]

        onExited: {
            root.cleaned = true;
            root.retune();
        }
    }

    Timer {
        interval: 1200
        running: !root.cleaned
        onTriggered: {
            root.cleaned = true;
            root.retune();
        }
    }

    Process {
        id: slotA

        property int token: 0
        property string group: ""

        running: false

        stdout: SplitParser {
            onRead: (line) => {
                var s = String(line).trim();
                var g = s.match(/^@@group:(\d+)@@$/);
                if (g) {
                    slotA.group = g[1];
                    return ;
                }
                var m = s.match(/^@@ready:(\d+)@@$/);
                if (m) {
                    root.slotReady(slotA, parseInt(m[1], 10));
                    return ;
                }
                var a = s.match(/^@@alive:(\d+)@@$/);
                if (a) {
                    if (slotA === root.activeSlot && slotA.token === root.activeToken)
                        root.audible = Math.min(root.count, parseInt(a[1], 10) + root.activeExtra);
                    return ;
                }
                if (s === "@@empty@@")
                    root.slotEmpty(slotA);

            }
        }

        stderr: SplitParser {
            onRead: (line) => {
                if (String(line).toLowerCase().indexOf("error") >= 0)
                    console.log("ambience: " + line);

            }
        }

        onExited: (code) => root.slotFinished(slotA, code)
    }

    Process {
        id: slotB

        property int token: 0
        property string group: ""

        running: false

        stdout: SplitParser {
            onRead: (line) => {
                var s = String(line).trim();
                var g = s.match(/^@@group:(\d+)@@$/);
                if (g) {
                    slotB.group = g[1];
                    return ;
                }
                var m = s.match(/^@@ready:(\d+)@@$/);
                if (m) {
                    root.slotReady(slotB, parseInt(m[1], 10));
                    return ;
                }
                var a = s.match(/^@@alive:(\d+)@@$/);
                if (a) {
                    if (slotB === root.activeSlot && slotB.token === root.activeToken)
                        root.audible = Math.min(root.count, parseInt(a[1], 10) + root.activeExtra);
                    return ;
                }
                if (s === "@@empty@@")
                    root.slotEmpty(slotB);

            }
        }

        stderr: SplitParser {
            onRead: (line) => {
                if (String(line).toLowerCase().indexOf("error") >= 0)
                    console.log("ambience: " + line);

            }
        }

        onExited: (code) => root.slotFinished(slotB, code)
    }

    // a long-lived helper on the active group's stdin; rows write "index volume"
    Process {
        id: volumeProc

        running: false
        stdinEnabled: true

        stderr: SplitParser {
            onRead: (line) => {
                if (String(line).toLowerCase().indexOf("error") >= 0)
                    console.log("ambience volume: " + line);

            }
        }

        onRunningChanged: {
            if (volumeProc.running) {
                // stdin may not accept writes the instant the process starts,
                // and the gain can change again while it is coming up
                gainSync.restart();
                root.flushModes();
            }
        }

        onExited: {
            if (root.pendingGroup !== "") {
                var g = root.pendingGroup;
                root.pendingGroup = "";
                if (g === root.activeGroup)
                    root.launchVolumeControl(g);

            }
        }
    }

    Process {
        id: titleProc

        running: false

        stdout: SplitParser {
            onRead: (line) => root.titleText += line + "\n"
        }

        stderr: SplitParser {
            onRead: (line) => {
                var s = String(line).trim();
                if (s.toLowerCase().indexOf("error") >= 0)
                    console.log("ambience title: " + s);

            }
        }

        onRunningChanged: {
            if (!titleProc.running)
                titleSettle.restart();

        }

        onExited: titleSettle.restart()
    }

    Timer {
        id: titleSettle

        interval: 80
        onTriggered: root.finishTitle()
    }

    IpcHandler {
        target: "ambience"

        function add(url: string): string {
            return root.addTrack(url) ? "" : root.error;
        }

        function remove(index: string): string {
            var i = parseInt(index, 10);
            if (!isFinite(i) || i < 0 || i >= root.count)
                return "no track at " + index;

            root.removeTrack(i);
            return "";
        }

        function clear(): void {
            root.clearTracks();
        }

        function modes(): string {
            return root.modes.map((m) => {
                return m.id + " (" + m.label + ")";
            }).join(", ");
        }

        function duck(): string {
            return (root.ducked ? "ducked" : "solo") + " · gain " + Math.round(root.duckGain * 100) + "% · other peak " + root.effectivePeak.toFixed(4) + " · " + root.audibleExternalCount + (root.audibleExternalCount === 1 ? " other stream" : " other streams") + (root.pwaOnlyAudio ? " · YouTube Music PWA" : "");
        }

        function pwa(): string {
            return "window=" + root.ytMusicWindow + " browser=" + root.browserAudio + " only=" + root.pwaOnlyAudio + " audible=" + root.audibleExternalCount + " streams=" + root.externalStreams.length;
        }

        function heads(): string {
            return "running=" + headProc.running + " dirty=" + root.headDirty + " script=" + root.headScript;
        }

        function buildheads(): void {
            root.scheduleHeads();
        }

        function presets(): string {
            if (root.presets.length === 0)
                return "no presets saved";

            return root.presets.map((p) => {
                return p.id + "  " + p.name + "  (" + p.tracks.length + " tracks)";
            }).join("\n");
        }

        function savepreset(name: string): string {
            var id = root.savePreset(name);
            return id === "" ? "this wallpaper has no tracks to save" : id;
        }

        function loadpreset(id: string): string {
            return root.loadPreset(id) ? "" : "nothing new in that preset";
        }

        function deletepreset(id: string): string {
            return root.deletePreset(id) ? "" : "no preset called " + id;
        }

        // qs ipc call ambience volume 0 35
        function volume(index: string, value: string): string {
            var i = parseInt(index, 10);
            var v = parseInt(value, 10);
            if (!isFinite(i) || i < 0 || i >= root.count)
                return "no track at " + index;
            if (!isFinite(v))
                return "volume must be 0..100";

            root.setTrackVolume(i, v);
            return "";
        }

        // qs ipc call ambience mode 0 cave
        function mode(index: string, value: string): string {
            var i = parseInt(index, 10);
            if (!isFinite(i) || i < 0 || i >= root.count)
                return "no track at " + index;

            if (value === "") {
                root.cycleMode(i);
                return "";
            }

            var info = root.modeInfo(value);
            if (info.id !== value)
                return "no mode called " + value + "; try: " + root.modes.map((m) => {
                    return m.id;
                }).join(" ");

            root.setTrackMode(i, info.id);
            return "";
        }

        function list(): string {
            if (root.count === 0)
                return "no tracks for " + root.wallpaperName;

            var out = [];
            for (var i = 0; i < root.count; i++) {
                var t = root.tracks[i];
                var v = (typeof t.volume === "number") ? t.volume : root.volume;
                var m = root.modeInfo(t.mode);
                out.push("  " + (i + 1) + ". [" + v + "%] [" + m.label + "] " + t.title + "  " + t.url);
            }
            return out.join("\n");
        }

        function status(): string {
            if (root.count === 0)
                return "ambience: nothing queued for " + root.wallpaperName;

            var state = root.error !== "" ? root.error : (root.preparing ? "preparing" : (root.playing ? "playing" : "ready"));
            var lo = 100;
            var hi = 0;
            for (var i = 0; i < root.count; i++) {
                var v = (typeof root.tracks[i].volume === "number") ? root.tracks[i].volume : root.volume;
                lo = Math.min(lo, v);
                hi = Math.max(hi, v);
            }
            var range = lo === hi ? (lo + "%") : (lo + "–" + hi + "%");
            return "ambience: " + state + " " + root.audible + "/" + root.count + " layers · volumes " + range + " for " + root.wallpaperName;
        }
    }

}

