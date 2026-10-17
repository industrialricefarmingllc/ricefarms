import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs

Column {
    id: page

    readonly property string home: Quickshell.env("HOME")
    readonly property var blurSteps: [0, 0.2, 0.5, 0.8, 1]
    readonly property var blurLabels: ["Off", "Light", "Balanced", "Heavy", "Full"]
    readonly property int blurIndex: {
        var best = 0, dist = 999;
        for (var i = 0; i < page.blurSteps.length; i++) {
            var d = Math.abs(page.blurSteps[i] - Theme.blurAmount);
            if (d < dist) {
                dist = d;
                best = i;
            }
        }
        return best;
    }
    property string currentTheme: "matugen"
    property string appliedWallpaper: ""
    readonly property string wallpaperDir: Prefs.wallpaperFolder !== "" ? Prefs.wallpaperFolder : (page.home + "/Pictures/wallpapers/" + page.currentTheme)

    function applyTheme(id) {
        if (id === page.currentTheme)
            return ;

        Prefs.themeChangeRequested(id);
    }

    function applyWallpaper(path) {
        if (path === "")
            return;

        Quickshell.execDetached([page.home + "/.config/hypr/scripts/wallpaper/set-wallpaper.sh", path]);
    }

    spacing: 26

    FileView {
        path: page.home + "/.cache/current_theme"
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            var t = text().trim();
            page.currentTheme = t !== "" ? t : "matugen";
        }
    }

    onWallpaperDirChanged: wallpaperScan.restart()

    Process {
        id: wallpaperScan

        function restart() {
            wallpaperScan.running = false;
            wallpaperScan.command = ["sh", "-c", "d=\"" + page.wallpaperDir + "\"; [ -d \"$d\" ] || exit 0; find \"$d\" -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \\) | sort"];
            wallpaperScan.running = true;
        }

        stdout: StdioCollector {
            onStreamFinished: {
                wallpapers.clear();
                var lines = text.split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var p = lines[i].trim();
                    if (p === "")
                        continue;

                    var base = p.substring(p.lastIndexOf("/") + 1);
                    var dot = base.lastIndexOf(".");
                    wallpapers.append({
                        "path": p,
                        "name": dot > 0 ? base.substring(0, dot) : base
                    });
                }
            }
        }

    }

    Process {
        id: wallpaperPicker

        stdout: StdioCollector {
            onStreamFinished: {
                var chosen = text.trim();
                if (chosen === "")
                    return;

                wallpaperImport.command = ["sh", "-c", "mkdir -p \"" + page.wallpaperDir + "\" && cp -n \"" + chosen + "\" \"" + page.wallpaperDir + "/\" && echo \"" + page.wallpaperDir + "/$(basename \"" + chosen + "\")\""];
                wallpaperImport.running = true;
            }
        }

    }

    Process {
        id: wallpaperImport

        stdout: StdioCollector {
            onStreamFinished: {
                var added = text.trim();
                wallpaperScan.restart();
                Prefs.wallpapersChanged();
                if (added !== "")
                    page.applyWallpaper(added);

            }
        }

    }

    FileView {
        path: page.home + "/.cache/current_wallpaper"
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
        onLoaded: page.appliedWallpaper = text().trim()
    }

    Process {
        id: wallpaperDelete

        stdout: StdioCollector {
            onStreamFinished: {
                wallpaperScan.restart();
                Prefs.wallpapersChanged();
            }
        }

    }

    Connections {
        function onWallpaperDeleteRequested(path) {
            wallpaperDelete.running = false;
            wallpaperDelete.command = ["sh", "-c", "gio trash \"" + path + "\" 2>/dev/null || rm -f \"" + path + "\"; echo done"];
            wallpaperDelete.running = true;
        }

        target: Prefs
    }

    ListModel {
        id: wallpapers
    }

    Component.onCompleted: wallpaperScan.restart()

    SettingCard {
        title: "SHAPE"

        SettingRow {
            title: "Bar style"
            description: "Islands float free of the screen edge. Notches sit flush against it, squaring off the corners that meet it."

            M3Segmented {
                width: 260
                current: Prefs.barStyle
                options: [{
                    "key": "island",
                    "label": "Islands"
                }, {
                    "key": "notch",
                    "label": "Notches"
                }]
                onChosen: (key) => {
                    return Prefs.barStyle = key;
                }
            }

        }

        SettingRow {
            title: "Dock style"
            description: "The same choice for the dock, against the bottom edge."
            showDivider: false

            M3Segmented {
                width: 260
                current: Prefs.dockStyle
                options: [{
                    "key": "island",
                    "label": "Islands"
                }, {
                    "key": "notch",
                    "label": "Notches"
                }]
                onChosen: (key) => {
                    return Prefs.dockStyle = key;
                }
            }

        }

        SettingRow {
            title: "Squircle corners"
            resetKey: "squircleF"
            description: "How smoothly every corner in the shell flows into its edges. 0 is a classic circular round, 0.5 a balanced squircle, 1 almost a rectangle with soft corners. Applies to the bar, dock, widgets, screen corners, Pibble, and window glass alike."
            showDivider: false
            stacked: true

            M3Slider {
                width: parent.width
                from: 0
                to: 1
                stepSize: 0.05
                decimals: 2
                value: Prefs.squircleF
                onMoved: (v) => {
                    return Prefs.squircleF = v;
                }
            }

        }

    }

    SettingCard {
        title: "SURFACES"

        SettingRow {
            title: "Glass"
            resetAction: Prefs.resetBlurToken
            resetVisible: Theme.blurAmount !== 0
            description: "How far the compositor blurs the desktop through the shell's surfaces. This replaced the launcher's old >blur strip, which now opens this page instead."
            warning: "Frosting is handled by the compositor, not the shell, and is buggy \u2014 expect visual artefacts. Set this to Off to avoid them."
            stacked: true

            M3Slider {
                width: parent.width
                from: 0
                to: 4
                stepSize: 1
                stepLabels: page.blurLabels
                value: page.blurIndex
                onMoved: (v) => {
                    return Theme.setBlurAmount(page.blurSteps[Math.round(v)]);
                }
            }

        }

        SettingRow {
            title: "Accent intensity"
            resetKey: "accentPunch"
            description: "Lifts the accent colour away from the wallpaper-derived original. 1.0 uses it exactly as generated."
            stacked: true

            M3Slider {
                width: parent.width
                from: 1
                to: 2
                stepSize: 0.05
                decimals: 2
                value: Prefs.accentPunch
                onMoved: (v) => {
                    return Prefs.accentPunch = v;
                }
            }

        }

        SettingRow {
            title: "Liquid glass"
            description: "Port of OverShifted/LiquidGlass — squircle SDF + edge glow + noise over Theme.bg. Blur slider above still controls the Hyprland wallpaper blur underneath."
            stacked: true

            Column {
                width: parent.width
                spacing: 10
                Row {
                    width: parent.width
                    spacing: 10
                    M3Switch {
                        checked: Prefs.liquidGlassEnabled
                        onToggled: (v) => Prefs.liquidGlassEnabled = v
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Prefs.liquidGlassEnabled ? "On — bar & dock use glass shader" : "Off — plain Theme.bg"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }
                }
                Row {
                    width: parent.width
                    spacing: 10
                    visible: Prefs.liquidGlassEnabled
                    M3Switch {
                        checked: Prefs.liquidGlassGlow
                        onToggled: (v) => Prefs.liquidGlassGlow = v
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Edge glow"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }
                    Item { width: 20; height: 1 }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Noise"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }
                    M3Slider {
                        width: 160
                        from: 0
                        to: 0.15
                        stepSize: 0.01
                        decimals: 2
                        value: Prefs.liquidGlassNoise
                        onMoved: (v) => Prefs.liquidGlassNoise = v
                    }
                }
            }
        }

        SettingRow {
            title: "Surface darkness"
            resetKey: "surfaceDarkness"
            description: "How far every panel is darkened beneath the theme's own surface colour. Auto follows the theme."
            showDivider: false
            stacked: true

            Row {
                spacing: 16
                width: parent.width

                M3Slider {
                    width: parent.width - resetDark.width - 16
                    enabled: Prefs.surfaceDarkness >= 0
                    from: 0
                    to: 0.8
                    stepSize: 0.05
                    decimals: 2
                    value: Prefs.surfaceDarkness >= 0 ? Prefs.surfaceDarkness : 0.45
                    onMoved: (v) => {
                        return Prefs.surfaceDarkness = v;
                    }
                }

                M3Button {
                    id: resetDark

                    anchors.verticalCenter: parent.verticalCenter
                    text: Prefs.surfaceDarkness >= 0 ? "Auto" : "Manual"
                    variant: Prefs.surfaceDarkness >= 0 ? "tonal" : "filled"
                    onClicked: Prefs.surfaceDarkness = Prefs.surfaceDarkness >= 0 ? -1 : 0.45
                }

            }

        }

    }

    // Full port of LiquidGlass controls — mirrors LiquidGlass.cpp / BatchRenderer2D.glsl
    SettingCard {
        title: "LIQUID GLASS — ADVANCED"
        visible: Prefs.liquidGlassEnabled

        SettingRow {
            title: "Shape — Power"
            description: "Superellipse exponent. 1 = diamond, 2 = circle, 3 = squircle (default), 6 = near-rect. Original slider 1.001..6."
            stacked: true
            M3Slider {
                width: parent.width
                from: 1.001
                to: 6
                stepSize: 0.05
                decimals: 2
                value: Prefs.liquidGlassPower
                onMoved: (v) => Prefs.liquidGlassPower = v
            }
        }
        SettingRow {
            title: "Size — Width / Height"
            description: "Original quad size 0..10, default 3.5 each. Scales the squircle before superellipse (p *= 3.5/size). Larger = smaller highlight."
            stacked: true
            Column {
                width: parent.width
                spacing: 8
                Row { width: parent.width; spacing: 8
                    Text { width: 60; anchors.verticalCenter: parent.verticalCenter; text: "Width"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 70; from: 0.1; to: 10; stepSize: 0.1; decimals: 1; value: Prefs.liquidGlassWidth; onMoved: (v) => Prefs.liquidGlassWidth = v }
                }
                Row { width: parent.width; spacing: 8
                    Text { width: 60; anchors.verticalCenter: parent.verticalCenter; text: "Height"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 70; from: 0.1; to: 10; stepSize: 0.1; decimals: 1; value: Prefs.liquidGlassHeight; onMoved: (v) => Prefs.liquidGlassHeight = v }
                }
            }
        }
        SettingRow {
            title: "Refraction — f(x)=1 - b·(c·e)^(-d·x - a)"
            description: "Controls the f(x) curve that warps the highlight like a lens. a 0..5, b 0..6, c 0..6, d 0..10. Default a=0.7 b=2.3 c=5.2 d=6.9 (from LiquidGlass.h)."
            stacked: true
            Column {
                width: parent.width
                spacing: 8
                Row { width: parent.width; spacing: 8
                    Text { width: 18; anchors.verticalCenter: parent.verticalCenter; text: "a"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 28; from: 0; to: 5; stepSize: 0.05; decimals: 2; value: Prefs.liquidGlassA; onMoved: (v) => Prefs.liquidGlassA = v }
                }
                Row { width: parent.width; spacing: 8
                    Text { width: 18; anchors.verticalCenter: parent.verticalCenter; text: "b"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 28; from: 0; to: 6; stepSize: 0.05; decimals: 2; value: Prefs.liquidGlassB; onMoved: (v) => Prefs.liquidGlassB = v }
                }
                Row { width: parent.width; spacing: 8
                    Text { width: 18; anchors.verticalCenter: parent.verticalCenter; text: "c"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 28; from: 0; to: 6; stepSize: 0.05; decimals: 2; value: Prefs.liquidGlassC; onMoved: (v) => Prefs.liquidGlassC = v }
                }
                Row { width: parent.width; spacing: 8
                    Text { width: 18; anchors.verticalCenter: parent.verticalCenter; text: "d"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 28; from: 0; to: 10; stepSize: 0.05; decimals: 2; value: Prefs.liquidGlassD; onMoved: (v) => Prefs.liquidGlassD = v }
                }
            }
        }
        SettingRow {
            title: "f(x) Power"
            description: "pow(f(dist), fPower). Negative inverts bending. Original -1.5..6, default 1.0."
            stacked: true
            M3Slider {
                width: parent.width
                from: -1.5
                to: 6
                stepSize: 0.05
                decimals: 2
                value: Prefs.liquidGlassFPower
                onMoved: (v) => Prefs.liquidGlassFPower = v
            }
        }
        SettingRow {
            title: "Glow"
            description: "Weight -1..1, Bias -1..1, Edges -1..1. Glow = sin(atan)·weight·smoothstep(edge0,edge1,dist)+1+bias, multiplied by refraction."
            stacked: true
            Column {
                width: parent.width
                spacing: 8
                Row { width: parent.width; spacing: 8
                    Text { width: 70; anchors.verticalCenter: parent.verticalCenter; text: "Weight"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 80; from: -1; to: 1; stepSize: 0.05; decimals: 2; value: Prefs.liquidGlassGlowWeight; onMoved: (v) => Prefs.liquidGlassGlowWeight = v }
                }
                Row { width: parent.width; spacing: 8
                    Text { width: 70; anchors.verticalCenter: parent.verticalCenter; text: "Bias"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 80; from: -1; to: 1; stepSize: 0.05; decimals: 2; value: Prefs.liquidGlassGlowBias; onMoved: (v) => Prefs.liquidGlassGlowBias = v }
                }
                Row { width: parent.width; spacing: 8
                    Text { width: 70; anchors.verticalCenter: parent.verticalCenter; text: "Edge0"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 80; from: -1; to: 1; stepSize: 0.05; decimals: 2; value: Prefs.liquidGlassGlowEdge0; onMoved: (v) => Prefs.liquidGlassGlowEdge0 = v }
                }
                Row { width: parent.width; spacing: 8
                    Text { width: 70; anchors.verticalCenter: parent.verticalCenter; text: "Edge1"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 80; from: -1; to: 1; stepSize: 0.05; decimals: 2; value: Prefs.liquidGlassGlowEdge1; onMoved: (v) => Prefs.liquidGlassGlowEdge1 = v }
                }
            }
        }
        SettingRow {
            title: "Blur & Noise — independent of Surfaces > Glass"
            description: "Original BlurIters 0..10, Radius 0..10, Downscale 0.1..1, Noise 0..0.3, Bokeh 0..1 (highlight discs, costs fill-rate). Glass blur is separate from compositor blur (Surfaces > Glass) and modulates refraction."
            stacked: true
            Column {
                width: parent.width
                spacing: 8
                Row { width: parent.width; spacing: 8
                    Text { width: 90; anchors.verticalCenter: parent.verticalCenter; text: "Blur Iters"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 100; from: 0; to: 10; stepSize: 1; decimals: 0; value: Prefs.liquidGlassBlurIters; onMoved: (v) => Prefs.liquidGlassBlurIters = Math.round(v) }
                }
                Row { width: parent.width; spacing: 8
                    Text { width: 90; anchors.verticalCenter: parent.verticalCenter; text: "Blur Radius"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 100; from: 0; to: 10; stepSize: 0.1; decimals: 1; value: Prefs.liquidGlassBlurRadius; onMoved: (v) => Prefs.liquidGlassBlurRadius = v }
                }
                Row { width: parent.width; spacing: 8
                    Text { width: 90; anchors.verticalCenter: parent.verticalCenter; text: "Bokeh"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 100; from: 0; to: 1; stepSize: 0.05; decimals: 2; value: Prefs.liquidGlassBokeh; onMoved: (v) => Prefs.liquidGlassBokeh = v }
                }
                Row { width: parent.width; spacing: 8
                    Text { width: 90; anchors.verticalCenter: parent.verticalCenter; text: "Downscale"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 100; from: 0.1; to: 1; stepSize: 0.05; decimals: 2; value: Prefs.liquidGlassBlurDownscale; onMoved: (v) => Prefs.liquidGlassBlurDownscale = v }
                }
                Row { width: parent.width; spacing: 8
                    Text { width: 90; anchors.verticalCenter: parent.verticalCenter; text: "Noise"; color: Theme.subtext; font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel }
                    M3Slider { width: parent.width - 100; from: 0; to: 0.3; stepSize: 0.01; decimals: 2; value: Prefs.liquidGlassNoise; onMoved: (v) => Prefs.liquidGlassNoise = v }
                }
            }
        }
        SettingRow {
            title: "Opacity — independent of Surfaces > Glass"
            description: "Tint strength only — the glass effects themselves always render full-strength. 0 = untinted, 1 = full tint. Default 0.82."
            stacked: true
            M3Slider {
                width: parent.width
                from: 0.1
                to: 1
                stepSize: 0.05
                decimals: 2
                value: Prefs.liquidGlassOpacity
                onMoved: (v) => Prefs.liquidGlassOpacity = v
            }
        }
        SettingRow {
            title: "Reset Liquid Glass"
            description: "Restores all LiquidGlass params to OverShifted defaults (incl. size/blur/opacity)."
            showDivider: false
            M3Button {
                text: "Reset"
                onClicked: {
                    Prefs.liquidGlassPower = Prefs.defaults["liquidGlassPower"]
                    Prefs.liquidGlassWidth = Prefs.defaults["liquidGlassWidth"]
                    Prefs.liquidGlassHeight = Prefs.defaults["liquidGlassHeight"]
                    Prefs.liquidGlassA = Prefs.defaults["liquidGlassA"]
                    Prefs.liquidGlassB = Prefs.defaults["liquidGlassB"]
                    Prefs.liquidGlassC = Prefs.defaults["liquidGlassC"]
                    Prefs.liquidGlassD = Prefs.defaults["liquidGlassD"]
                    Prefs.liquidGlassFPower = Prefs.defaults["liquidGlassFPower"]
                    Prefs.liquidGlassBlurIters = Prefs.defaults["liquidGlassBlurIters"]
                    Prefs.liquidGlassBlurRadius = Prefs.defaults["liquidGlassBlurRadius"]
                    Prefs.liquidGlassBokeh = Prefs.defaults["liquidGlassBokeh"]
                    Prefs.liquidGlassBlurDownscale = Prefs.defaults["liquidGlassBlurDownscale"]
                    Prefs.liquidGlassNoise = Prefs.defaults["liquidGlassNoise"]
                    Prefs.liquidGlassGlowWeight = Prefs.defaults["liquidGlassGlowWeight"]
                    Prefs.liquidGlassGlowBias = Prefs.defaults["liquidGlassGlowBias"]
                    Prefs.liquidGlassGlowEdge0 = Prefs.defaults["liquidGlassGlowEdge0"]
                    Prefs.liquidGlassGlowEdge1 = Prefs.defaults["liquidGlassGlowEdge1"]
                    Prefs.liquidGlassOpacity = Prefs.defaults["liquidGlassOpacity"]
                }
            }
        }
    }

    SettingCard {
        title: "MOTION & TYPE"

        SettingRow {
            title: "Animation speed"
            resetKey: "motionScale"
            description: "Scales every transition in the shell. 1.00x is the shipped speed; drag to 0 for no animation at all."
            stacked: true

            M3Slider {
                width: parent.width
                from: 0
                to: 2
                stepSize: 0.25
                decimals: 2
                suffix: "x"
                value: Prefs.motionScale
                onMoved: (v) => {
                    return Prefs.motionScale = v;
                }
            }

        }

        SettingRow {
            title: "Interface font"
            resetKey: "fontFamily"
            description: "Applied everywhere the shell draws text. Chosen from the fonts installed on this machine."

            M3Button {
                text: Prefs.fontFamily
                variant: "tonal"
                onClicked: Prefs.fontPickerRequested()
            }

        }

        SettingRow {
            title: "Text size"
            resetKey: "fontScale"
            description: "Scales the shell's whole type ramp at once."
            showDivider: false
            stacked: true

            M3Slider {
                width: parent.width
                from: 0.8
                to: 1.4
                stepSize: 0.05
                decimals: 2
                suffix: "x"
                value: Prefs.fontScale
                onMoved: (v) => {
                    return Prefs.fontScale = v;
                }
            }

        }

    }

    SettingCard {
        title: "THEME"

        SettingRow {
            title: "Colour scheme"
            description: "Switching also swaps the wallpaper folder below to that theme's own."
            showDivider: false
            stacked: true

            Flow {
                width: parent.width
                spacing: 10

                Repeater {
                    model: Prefs.themeCatalogue

                    Rectangle {
                        id: swatch

                        required property var modelData

                        readonly property bool selected: page.currentTheme === swatch.modelData.id

                        width: 150
                        height: 60
                        radius: Theme.radiusMd
                        color: swatch.selected ? Theme.accentContainer : (swatchArea.containsMouse ? Theme.bgHover : Theme.bgSunken)

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.durShort
                            }

                        }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 10

                            Rectangle {
                                width: 28
                                height: 28
                                radius: 14
                                anchors.verticalCenter: parent.verticalCenter
                                color: swatch.modelData.swatchBg

                                Rectangle {
                                    width: 12
                                    height: 12
                                    radius: 6
                                    anchors.centerIn: parent
                                    color: swatch.modelData.swatchAccent
                                }

                            }

                            Text {
                                width: 90
                                anchors.verticalCenter: parent.verticalCenter
                                text: swatch.modelData.name
                                color: swatch.selected ? Theme.text : Theme.subtext
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontLabel
                                font.bold: swatch.selected
                                wrapMode: Text.WordWrap
                            }

                        }

                        MouseArea {
                            id: swatchArea

                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: page.applyTheme(swatch.modelData.id)
                        }

                    }

                }

            }

        }

    }

    SettingCard {
        title: "WALLPAPER"

        SettingRow {
            title: "Wallpaper strip"
            description: wallpapers.count + " in " + page.wallpaperDir.replace(page.home, "~")
            stacked: true

            Column {
                width: parent.width
                spacing: 14

                Flow {
                    width: parent.width
                    spacing: 10

                    Repeater {
                        model: wallpapers

                        Rectangle {
                            id: tile

                            required property string path
                            required property string name

                            readonly property bool selected: page.appliedWallpaper === tile.path

                            width: 150
                            height: 88
                            radius: Theme.radiusSm
                            color: Theme.bgSunken

                            Image {
                                id: thumb

                                anchors.fill: parent
                                source: "file://" + tile.path
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                sourceSize.width: 300
                                sourceSize.height: 176
                                visible: false
                            }

                            Rectangle {
                                id: thumbMask

                                anchors.fill: parent
                                radius: tile.radius
                                visible: false
                                layer.enabled: true
                            }

                            OpacityMask {
                                anchors.fill: parent
                                source: thumb
                                maskSource: thumbMask
                                visible: thumb.status === Image.Ready
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: parent.radius
                                color: "transparent"
                                border.width: tile.selected ? 3 : (tileArea.containsMouse ? 2 : 0)
                                border.color: tile.selected ? Theme.accent : Theme.alpha(Theme.text, 0.5)

                                Behavior on border.width {
                                    NumberAnimation {
                                        duration: Theme.durQuick
                                    }

                                }

                            }

                            MouseArea {
                                id: tileArea

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: page.applyWallpaper(tile.path)
                            }

                            Rectangle {
                                id: delBtn

                                readonly property bool active: tileArea.containsMouse || delArea.containsMouse

                                width: 28
                                height: 28
                                radius: 14
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: 6
                                color: delArea.containsMouse ? Theme.error : Theme.alpha(Theme.cShadow, 0.65)
                                opacity: delBtn.active ? 1 : 0
                                visible: opacity > 0.01
                                scale: delBtn.active ? 1 : 0.7

                                Behavior on opacity {
                                    NumberAnimation {
                                        duration: Theme.durQuick
                                    }

                                }

                                Behavior on scale {
                                    NumberAnimation {
                                        duration: Theme.durShort
                                        easing.type: Theme.easeEmphasized
                                        easing.overshoot: Theme.emphasizedOvershoot
                                    }

                                }

                                Behavior on color {
                                    ColorAnimation {
                                        duration: Theme.durQuick
                                    }

                                }

                                Item {
                                    id: bin

                                    readonly property color glyph: delArea.containsMouse ? Theme.onError : "white"
                                    // authored on a 24x24 grid, drawn at 16
                                    readonly property real unit: 16 / 24
                                    readonly property real stroke: 2.4
                                    property real lidAngle: delArea.containsMouse ? 32 : 0
                                    property real lidLift: delArea.containsMouse ? -1.4 : 0

                                    anchors.centerIn: parent
                                    width: 16
                                    height: 16

                                    Behavior on lidAngle {
                                        NumberAnimation {
                                            duration: Theme.durMedium
                                            easing.type: Theme.easeEmphasized
                                            easing.overshoot: 1.5
                                        }

                                    }

                                    Behavior on lidLift {
                                        NumberAnimation {
                                            duration: Theme.durMedium
                                            easing.type: Theme.easeEmphasized
                                            easing.overshoot: 1.5
                                        }

                                    }

                                    Shape {
                                        anchors.fill: parent
                                        preferredRendererType: Shape.CurveRenderer

                                        ShapePath {
                                            strokeColor: bin.glyph
                                            strokeWidth: bin.stroke
                                            fillColor: "transparent"
                                            capStyle: ShapePath.RoundCap
                                            joinStyle: ShapePath.RoundJoin

                                            PathSvg {
                                                path: "M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"
                                            }

                                        }

                                        ShapePath {
                                            strokeColor: bin.glyph
                                            strokeWidth: bin.stroke
                                            fillColor: "transparent"
                                            capStyle: ShapePath.RoundCap

                                            PathSvg {
                                                path: "M10 11v6"
                                            }

                                        }

                                        ShapePath {
                                            strokeColor: bin.glyph
                                            strokeWidth: bin.stroke
                                            fillColor: "transparent"
                                            capStyle: ShapePath.RoundCap

                                            PathSvg {
                                                path: "M14 11v6"
                                            }

                                        }

                                        transform: Scale {
                                            xScale: bin.unit
                                            yScale: bin.unit
                                        }

                                    }

                                    Item {
                                        anchors.fill: parent

                                        transform: Rotation {
                                            origin.x: 21 * bin.unit
                                            origin.y: 6 * bin.unit
                                            angle: bin.lidAngle
                                        }

                                        Shape {
                                            anchors.fill: parent
                                            y: bin.lidLift
                                            preferredRendererType: Shape.CurveRenderer

                                            ShapePath {
                                                strokeColor: bin.glyph
                                                strokeWidth: bin.stroke
                                                fillColor: "transparent"
                                                capStyle: ShapePath.RoundCap

                                                PathSvg {
                                                    path: "M3 6h18"
                                                }

                                            }

                                            ShapePath {
                                                strokeColor: bin.glyph
                                                strokeWidth: bin.stroke
                                                fillColor: "transparent"
                                                capStyle: ShapePath.RoundCap
                                                joinStyle: ShapePath.RoundJoin

                                                PathSvg {
                                                    path: "M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"
                                                }

                                            }

                                            transform: Scale {
                                                xScale: bin.unit
                                                yScale: bin.unit
                                            }

                                        }

                                    }

                                }

                                MouseArea {
                                    id: delArea

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Prefs.askConfirm("Delete this wallpaper?", "\"" + tile.name + "\" is moved to the trash, so it can be restored from there if you change your mind.", "Delete", "wallpaper:" + tile.path)
                                }

                            }

                        }

                    }

                }

                Text {
                    text: "No images in this folder yet - add one below."
                    color: Theme.subtext
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontBody
                    visible: wallpapers.count === 0
                }

                Row {
                    spacing: 10

                    M3Button {
                        text: "Add wallpaper..."
                        variant: "filled"
                        iconPath: "M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2Z"
                        onClicked: {
                            wallpaperPicker.command = ["sh", "-c", "zenity --file-selection --title='Add wallpaper' --file-filter='Images | *.jpg *.jpeg *.png *.webp *.JPG *.PNG' 2>/dev/null || true"];
                            wallpaperPicker.running = true;
                        }
                    }

                    M3Button {
                        text: "Open folder"
                        onClicked: Quickshell.execDetached(["sh", "-c", "xdg-open '" + page.wallpaperDir + "'"])
                    }

                    M3Button {
                        text: "Rescan"
                        variant: "text"
                        onClicked: wallpaperScan.restart()
                    }

                }

            }

        }

        SettingRow {
            title: "Custom folder"
            description: "Leave empty to follow the current theme's own wallpaper folder."
            showDivider: false

            M3TextField {
                width: 260
                text: Prefs.wallpaperFolder
                placeholder: "~/Pictures/wallpapers/" + page.currentTheme
                onAccepted: (v) => {
                    return Prefs.wallpaperFolder = v.trim().replace("~", page.home);
                }
            }

        }

    }

}
