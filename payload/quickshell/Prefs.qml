import QtQuick
import Quickshell
import Quickshell.Io
pragma Singleton

Singleton {
    id: root

    property bool loaded: false


    property bool debugRegions: false
    property var barBlurredWallpaperSource: null
    property var dockBlurredWallpaperSource: null

    IpcHandler {
        target: "debug"

        function toggle(): void {
            root.debugRegions = !root.debugRegions;
        }

        function on(): void {
            root.debugRegions = true;
        }

        function off(): void {
            root.debugRegions = false;
        }

    }

    readonly property bool barNotch: root.barStyle === "notch"
    readonly property bool dockNotch: root.dockStyle === "notch"
    readonly property int barPillRadius: Math.min(72, Math.round(root.barHeight / 2))
    // Explicit closed-tab corner radius for notch mode, independent of the
    // bar height that caps barPillRadius (a 35px tab maxes at a 17px
    // semicircle, so the height-capped value could never grow). Lets
    // notch tabs read as chunky as the expanded panels; the tab bottom
    // past h/2 renders as a continuous squircle bulge rather than a
    // semicircle. Top corners stay 0 against the screen edge.
    // Plain property (not an alias): the s.barNotchRadius twin below is
    // synced explicitly on load and on change.
    property int barNotchRadius: 32
    function syncBarNotchRadiusToFile(): void {
        if (s.barNotchRadius !== root.barNotchRadius)
            s.barNotchRadius = root.barNotchRadius;
    }
    onBarNotchRadiusChanged: root.syncBarNotchRadiusToFile()
    readonly property int effectiveBarTopMargin: root.barNotch ? 0 : root.barTopMargin
    readonly property int effectiveDockBottomMargin: root.dockNotch ? 0 : root.dockBottomMargin
    readonly property bool anyBarModuleEnabled: root.showWorkspaces || root.showMedia || root.showTray || root.showClock || root.showNotifications || root.showSystem
    readonly property var barModuleKeys: ["showWorkspaces", "showMedia", "showTray", "showClock", "showNotifications", "showSystem"]

    property alias barStyle: s.barStyle
    property alias dockStyle: s.dockStyle
    property alias accentPunch: s.accentPunch
    property alias surfaceDarkness: s.surfaceDarkness
    property alias motionScale: s.motionScale
    property alias fontFamily: s.fontFamily
    property alias fontScale: s.fontScale
    property alias wallpaperFolder: s.wallpaperFolder

    property alias barEnabled: s.barEnabled
    property alias barPopupMode: s.barPopupMode
    property alias barPopupGap: s.barPopupGap
    property alias barHeight: s.barHeight
    property alias barTopMargin: s.barTopMargin
    property alias barSideMargin: s.barSideMargin
    property alias barSpacing: s.barSpacing
    property alias barHoverGrow: s.barHoverGrow
    property alias showWorkspaces: s.showWorkspaces
    property alias showMedia: s.showMedia
    property alias showTray: s.showTray
    property alias showClock: s.showClock
    property alias showNotifications: s.showNotifications
    property alias showSystem: s.showSystem
    property alias clock24h: s.clock24h
    property alias clockShowDate: s.clockShowDate
    property alias doNotDisturb: s.doNotDisturb
    property alias toastTimeout: s.toastTimeout

    property alias dockEnabled: s.dockEnabled
    property alias dockIconSize: s.dockIconSize
    property alias dockSpacing: s.dockSpacing
    property alias dockBottomMargin: s.dockBottomMargin
    property alias dockMagnify: s.dockMagnify
    property alias dockHoverEffect: s.dockHoverEffect
    property alias barMotionScale: s.barMotionScale
    property alias barNotchFlare: s.barNotchFlare
    property alias dockNotchFlare: s.dockNotchFlare
    property alias dockAutoHide: s.dockAutoHide
    property alias dockShowIndicators: s.dockShowIndicators
    property alias dockShowTooltips: s.dockShowTooltips
    property alias dockShowRunning: s.dockShowRunning
    property alias dockIconTiles: s.dockIconTiles
    // Shared squircle smoothing, 0..1 (0 = circular corners, 0.5 = classic
    // squircle, 1 = near-rect). Read by the squircle/ QML items, the
    // liquid-glass-hypr plugin (via its prefs.json tuner), and mirrored
    // into pibble's Theme.squircleF so both shells agree on one shape.
    property alias squircleF: s.squircleF
    property alias liquidGlassEnabled: s.liquidGlassEnabled
    property alias liquidGlassNoise: s.liquidGlassNoise
    property alias liquidGlassGlow: s.liquidGlassGlow
    property alias liquidGlassPower: s.liquidGlassPower
    property alias liquidGlassWidth: s.liquidGlassWidth
    property alias liquidGlassHeight: s.liquidGlassHeight
    property alias liquidGlassA: s.liquidGlassA
    property alias liquidGlassB: s.liquidGlassB
    property alias liquidGlassC: s.liquidGlassC
    property alias liquidGlassD: s.liquidGlassD
    property alias liquidGlassFPower: s.liquidGlassFPower
    property alias liquidGlassBlurIters: s.liquidGlassBlurIters
    property alias liquidGlassBlurRadius: s.liquidGlassBlurRadius
    property alias liquidGlassBokeh: s.liquidGlassBokeh
    property alias liquidGlassBlurDownscale: s.liquidGlassBlurDownscale
    property alias liquidGlassGlowWeight: s.liquidGlassGlowWeight
    property alias liquidGlassGlowBias: s.liquidGlassGlowBias
    property alias liquidGlassGlowEdge0: s.liquidGlassGlowEdge0
    property alias liquidGlassGlowEdge1: s.liquidGlassGlowEdge1
    property alias liquidGlassOpacity: s.liquidGlassOpacity

    readonly property var themeCatalogue: [
        { "id": "matugen", "name": "Matugen", "desc": "Colors generated from your wallpaper", "swatchBg": "#12171a", "swatchAccent": "#8ad0ee" },
        { "id": "pywal", "name": "Pywal", "desc": "Wallpaper colors via pywal's classic palette", "swatchBg": "#1a1e24", "swatchAccent": "#c9a1a9" },
        { "id": "catppuccin-mocha", "name": "Catppuccin Mocha", "desc": "Soothing pastel dark theme", "swatchBg": "#1e1e2e", "swatchAccent": "#89b4fa" },
        { "id": "gruvbox", "name": "Gruvbox", "desc": "Retro groove warm palette", "swatchBg": "#282828", "swatchAccent": "#83a598" },
        { "id": "nightfox", "name": "Nightfox", "desc": "Deep navy with muted blue accents", "swatchBg": "#192330", "swatchAccent": "#719cd6" },
        { "id": "nord", "name": "Nord", "desc": "Arctic blue-grey palette", "swatchBg": "#232831", "swatchAccent": "#88c0d0" },
        { "id": "tokyo-night", "name": "Tokyo Night", "desc": "Dark blues and violets", "swatchBg": "#1a1b26", "swatchAccent": "#7aa2f7" }
    ]

    readonly property var defaults: ({
        "barStyle": "island",
        "dockStyle": "island",
        "accentPunch": 1,
        "surfaceDarkness": -1,
        "motionScale": 1,
        "fontFamily": "Google Sans",
        "fontScale": 1,
        "wallpaperFolder": "",
        "barEnabled": true,
        "barPopupMode": false,
        "barPopupGap": 10,
        "barHeight": 35,
        "barTopMargin": 22,
        "barSideMargin": 50,
        "barSpacing": 8,
        "barHoverGrow": 3,
        "showWorkspaces": true,
        "showMedia": true,
        "showTray": true,
        "showClock": true,
        "showNotifications": true,
        "showSystem": true,
        "clock24h": false,
        "clockShowDate": true,
        "doNotDisturb": false,
        "toastTimeout": 5,
        "dockEnabled": true,
        "dockIconSize": 46,
        "dockSpacing": 10,
        "dockBottomMargin": 20,
        "dockMagnify": true,
        "dockHoverEffect": 1,
        "barMotionScale": 1.35,
        "barNotchFlare": 28,
        "barNotchRadius": 32,
        "dockNotchFlare": 28,
        "dockAutoHide": false,
        "dockShowIndicators": true,
        "dockShowTooltips": true,
        "dockShowRunning": true,
        "dockIconTiles": false,
        "liquidGlassEnabled": true,
        "liquidGlassNoise": 0.06,
        "liquidGlassGlow": true,
        "liquidGlassPower": 3.0,
        "liquidGlassWidth": 3.5,
        "liquidGlassHeight": 3.5,
        "liquidGlassA": 0.7,
        "liquidGlassB": 2.3,
        "liquidGlassC": 5.2,
        "liquidGlassD": 6.9,
        "liquidGlassFPower": 1.0,
        "liquidGlassBlurIters": 1,
        "liquidGlassBlurRadius": 2.0,
        "liquidGlassBokeh": 0.0,
        "liquidGlassBlurDownscale": 0.5,
        "liquidGlassGlowWeight": 0.25,
        "liquidGlassGlowBias": 0.0,
        "liquidGlassGlowEdge0": 0.5,
        "liquidGlassGlowEdge1": -0.5,
        "liquidGlassOpacity": 0.82,
        "squircleF": 0.8
    })

    signal pinnedResetRequested()
    signal settingsRequested(string page)
    signal resetConfirmRequested(string title, string body, string confirmLabel, string action)
    signal wallpaperDeleteRequested(string path)
    signal wallpapersChanged()

    readonly property string resetAllToken: "__all__"
    readonly property string resetDockToken: "__dock__"
    readonly property string resetBlurToken: "__blur__"

    signal themeChangeRequested(string id)

    signal fontPickerRequested()

    onAnyBarModuleEnabledChanged: {
        if (!root.anyBarModuleEnabled && root.barEnabled)
            root.barEnabled = false;

    }

    function setAllBarModules(v) {
        root.showWorkspaces = v;
        root.showMedia = v;
        root.showTray = v;
        root.showClock = v;
        root.showNotifications = v;
        root.showSystem = v;
    }

    function setSurface(key, v) {
        if (key === "barEnabled") {
            if (v && !root.anyBarModuleEnabled)
                root.setAllBarModules(true);

            root.barEnabled = v;
        } else if (key === "dockEnabled") {
            root.dockEnabled = v;
        }
    }

    function askReset(title, body, action) {
        root.resetConfirmRequested(title, body, "Reset", action);
    }

    // same dialog, different verb
    function askConfirm(title, body, confirmLabel, action) {
        root.resetConfirmRequested(title, body, confirmLabel, action);
    }

    function isModified(key) {
        return root.defaults[key] !== undefined && root[key] !== root.defaults[key];
    }

    function resetAll() {
        for (var k in root.defaults) root.set(k, root.defaults[k])
    }

    function resetKeys(keys) {
        for (var i = 0; i < keys.length; i++) root.set(keys[i], root.defaults[keys[i]])
    }

    function set(key, value) {
        if (s[key] !== undefined && s[key] !== value)
            s[key] = value;
        // manually-synced twins (see barNotchRadius): the adapter write
        // above persists, this refreshes the live property
        if (key === "barNotchRadius" && root.barNotchRadius !== value)
            root.barNotchRadius = value;
    }

    Timer {
        id: writeDebounce

        interval: 120
        repeat: false
        onTriggered: prefsFile.writeAdapter()
    }

    FileView {
        id: prefsFile

        path: Quickshell.env("HOME") + "/.config/quickshell/lucidprefs/prefs.json"
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
        onAdapterUpdated: writeDebounce.restart()
        onLoaded: {
            root.barNotchRadius = s.barNotchRadius;
            root.loaded = true;
        }
        onLoadFailed: root.loaded = true

        adapter: JsonAdapter {
            id: s

            property string barStyle: "island"
            property string dockStyle: "island"
            property real accentPunch: 1
            property real surfaceDarkness: -1
            property real motionScale: 1
            property string fontFamily: "Google Sans"
            property real fontScale: 1
            property string wallpaperFolder: ""
            property bool barEnabled: true
            property bool barPopupMode: false
            property int barPopupGap: 10
            property int barHeight: 35
            property int barTopMargin: 22
            property int barSideMargin: 50
            property int barSpacing: 8
            property int barHoverGrow: 3
            property bool showWorkspaces: true
            property bool showMedia: true
            property bool showTray: true
            property bool showClock: true
            property bool showNotifications: true
            property bool showSystem: true
            property bool clock24h: false
            property bool clockShowDate: true
            property bool doNotDisturb: false
            property int toastTimeout: 5
            property bool dockEnabled: true
            property int dockIconSize: 46
            property int dockSpacing: 10
            property int dockBottomMargin: 20
            property bool dockMagnify: true
            property real dockHoverEffect: 1
            property real barMotionScale: 1.35
            property int barNotchFlare: 28
            property int barNotchRadius: 32
            property int dockNotchFlare: 28
            property bool dockAutoHide: false
            property bool dockShowIndicators: true
            property bool dockShowTooltips: true
            property bool dockShowRunning: true
            property bool dockIconTiles: false
            property bool liquidGlassEnabled: true
            property real liquidGlassNoise: 0.06
            property bool liquidGlassGlow: true
            property real liquidGlassPower: 3.0
            property real liquidGlassWidth: 3.5
            property real liquidGlassHeight: 3.5
            property real liquidGlassA: 0.7
            property real liquidGlassB: 2.3
            property real liquidGlassC: 5.2
            property real liquidGlassD: 6.9
            property real liquidGlassFPower: 1.0
            property int liquidGlassBlurIters: 1
            property real liquidGlassBlurRadius: 2.0
            property real liquidGlassBokeh: 0.0
            property real liquidGlassBlurDownscale: 0.5
            property real liquidGlassGlowWeight: 0.25
            property real liquidGlassGlowBias: 0.0
            property real liquidGlassGlowEdge0: 0.5
            property real liquidGlassGlowEdge1: -0.5
            property real liquidGlassOpacity: 0.82
            property real squircleF: 0.8
        }

    }

}
