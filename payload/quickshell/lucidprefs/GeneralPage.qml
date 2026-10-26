import QtQuick
import Quickshell
import qs

Column {
    id: page

    readonly property string home: Quickshell.env("HOME")
    spacing: Theme.dp(26)

    SettingCard {
        title: "SIZE"

        SettingRow {
            title: "Interface size"
            resetKey: "uiScale"
            description: "Scales the whole shell at once: bar, dock, panels, menus and the text in them. Applications and the screen's own scale are not affected."
            showDivider: false
            stacked: true

            M3Slider {
                id: sizeSlider

                width: parent.width
                from: 0.75
                to: 1.25
                stepSize: 0.05
                stepLabels: ["75%", "80%", "85%", "90%", "95%", "100%", "105%", "110%", "115%", "120%", "125%"]
                value: Prefs.uiScale
                // applied on release: resizing live would pull this window out from under the pointer
                onDraggingChanged: {
                    var v = Math.round(sizeSlider.dragValue * 100) / 100;
                    if (!sizeSlider.dragging && v !== Prefs.uiScale)
                        Prefs.uiScale = v;

                }
            }

        }

    }

    SettingCard {
        title: "SHAPE"

        SettingRow {
            title: "Corner rounding"
            resetKey: "cornerScale"
            description: "How round the whole shell is: cards, panels, menus, pills and buttons. Lower squares them off, higher rounds them further; avatars, dots and the like stay round."
            stacked: true

            M3Slider {
                width: parent.width
                from: 0
                to: 1.5
                stepSize: 0.25
                stepLabels: ["Square", "25%", "50%", "75%", "As shipped", "125%", "150%"]
                value: Prefs.cornerScale
                onMoved: (v) => {
                    return Prefs.cornerScale = Math.round(v * 100) / 100;
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
            description: "How far the desktop shows through the shell, the terminal and your windows now has a page of its own."

            M3Button {
                text: "Glass…"
                variant: "tonal"
                onClicked: Prefs.settingsRequested("glass")
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
            description: "Port of OverShifted/LiquidGlass — squircle SDF + edge glow + noise over Theme.bg. The Glass page above still controls the compositor blur underneath."
            stacked: true

            Column {
                width: parent.width
                spacing: Theme.dp(10)

                Row {
                    width: parent.width
                    spacing: Theme.dp(10)

                    M3Switch {
                        checked: Prefs.liquidGlassEnabled
                        onToggled: (v) => {
                            Prefs.liquidGlassEnabled = v;
                            Quickshell.execDetached(["liquid-glass-toggle", v ? "--on" : "--off"]);
                        }
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
                    spacing: Theme.dp(10)
                    visible: Prefs.liquidGlassEnabled

                    M3Switch {
                        checked: Prefs.gooWorkspacesEnabled
                        onToggled: (v) => {
                            Prefs.gooWorkspacesEnabled = v;
                            Quickshell.execDetached(["liquid-glass-toggle", v ? "--goo-on" : "--goo-off"]);
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Prefs.gooWorkspacesEnabled ? "Workspace goo morph — on" : "Workspace goo morph — off (stock slide)"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                }

                Text {
                    width: parent.width
                    visible: Prefs.liquidGlassEnabled
                    text: "Independent of glass; turn off if workspace switches stutter. Glass stays on."
                    color: Theme.subtextDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontLabel
                    wrapMode: Text.WordWrap
                }

                Row {
                    width: parent.width
                    spacing: Theme.dp(10)
                    visible: Prefs.liquidGlassEnabled

                    M3Switch {
                        checked: Prefs.liquidGlassGlow
                        onToggled: (v) => {
                            Prefs.liquidGlassGlow = v;
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Edge glow"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    Item {
                        width: Theme.dp(20)
                        height: 1
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Noise"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: Theme.dp(160)
                        from: 0
                        to: 0.15
                        stepSize: 0.01
                        decimals: 2
                        value: Prefs.liquidGlassNoise
                        onMoved: (v) => {
                            Prefs.liquidGlassNoise = v;
                        }
                    }

                }

            }

        }

        SettingRow {
            title: "Surface darkness"
            resetKey: "surfaceDarkness"
            description: "How far every panel is darkened beneath the theme's own surface colour. Auto follows the theme."
            stacked: true

            Row {
                spacing: Theme.dp(16)
                width: parent.width

                M3Slider {
                    width: parent.width - resetDark.width - Theme.dp(16)
                    enabled: Prefs.surfaceDarkness >= 0
                    from: 0
                    to: 0.8
                    stepSize: 0.05
                    decimals: 2
                    value: Prefs.surfaceDarkness >= 0 ? Prefs.surfaceDarkness : Theme.pillDarkness
                    onMoved: (v) => {
                        return Prefs.surfaceDarkness = v;
                    }
                }

                M3Button {
                    id: resetDark

                    anchors.verticalCenter: parent.verticalCenter
                    text: Prefs.surfaceDarkness >= 0 ? "Auto" : "Manual"
                    variant: Prefs.surfaceDarkness >= 0 ? "tonal" : "filled"
                    onClicked: Prefs.surfaceDarkness = Prefs.surfaceDarkness >= 0 ? -1 : 0.3
                }

            }

        }

        SettingRow {
            title: "Accent tint"
            resetKey: "surfaceTint"
            description: "How much of the accent colour is mixed into every panel. A light palette comes out of the generator almost white, so Auto tints it and leaves dark panels flat."
            showDivider: false
            stacked: true

            Row {
                spacing: Theme.dp(16)
                width: parent.width

                M3Slider {
                    width: parent.width - resetTint.width - Theme.dp(16)
                    enabled: Prefs.surfaceTint >= 0
                    from: 0
                    to: 1
                    stepSize: 0.05
                    decimals: 2
                    value: Prefs.surfaceTint >= 0 ? Prefs.surfaceTint : (Theme.isLight ? 0.7 : 0)
                    onMoved: (v) => {
                        return Prefs.surfaceTint = v;
                    }
                }

                M3Button {
                    id: resetTint

                    anchors.verticalCenter: parent.verticalCenter
                    text: Prefs.surfaceTint >= 0 ? "Auto" : "Manual"
                    variant: Prefs.surfaceTint >= 0 ? "tonal" : "filled"
                    onClicked: Prefs.surfaceTint = Prefs.surfaceTint >= 0 ? -1 : (Theme.isLight ? 0.7 : 0.2)
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
                onMoved: (v) => {
                    Prefs.liquidGlassPower = v;
                }
            }

        }

        SettingRow {
            title: "Size — Width / Height"
            description: "Original quad size 0..10, default 3.5 each. Scales the squircle before superellipse (p *= 3.5/size). Larger = smaller highlight."
            stacked: true

            Column {
                width: parent.width
                spacing: Theme.dp(8)

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(60)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Width"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(68)
                        from: 0.1
                        to: 10
                        stepSize: 0.1
                        decimals: 1
                        value: Prefs.liquidGlassWidth
                        onMoved: (v) => {
                            Prefs.liquidGlassWidth = v;
                        }
                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(60)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Height"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(68)
                        from: 0.1
                        to: 10
                        stepSize: 0.1
                        decimals: 1
                        value: Prefs.liquidGlassHeight
                        onMoved: (v) => {
                            Prefs.liquidGlassHeight = v;
                        }
                    }

                }

            }

        }

        SettingRow {
            title: "Refraction — f(x)=1 - b·(c·e)^(-d·x - a)"
            description: "Controls the f(x) curve that warps the highlight like a lens. a 0..5, b 0..6, c 0..6, d 0..10. Default a=0.7 b=2.3 c=5.2 d=6.9 (from LiquidGlass.h)."
            stacked: true

            Column {
                width: parent.width
                spacing: Theme.dp(8)

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(18)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "a"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(26)
                        from: 0
                        to: 5
                        stepSize: 0.05
                        decimals: 2
                        value: Prefs.liquidGlassA
                        onMoved: (v) => {
                            Prefs.liquidGlassA = v;
                        }
                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(18)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "b"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(26)
                        from: 0
                        to: 6
                        stepSize: 0.05
                        decimals: 2
                        value: Prefs.liquidGlassB
                        onMoved: (v) => {
                            Prefs.liquidGlassB = v;
                        }
                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(18)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "c"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(26)
                        from: 0
                        to: 6
                        stepSize: 0.05
                        decimals: 2
                        value: Prefs.liquidGlassC
                        onMoved: (v) => {
                            Prefs.liquidGlassC = v;
                        }
                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(18)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "d"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(26)
                        from: 0
                        to: 10
                        stepSize: 0.05
                        decimals: 2
                        value: Prefs.liquidGlassD
                        onMoved: (v) => {
                            Prefs.liquidGlassD = v;
                        }
                    }

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
                onMoved: (v) => {
                    Prefs.liquidGlassFPower = v;
                }
            }

        }

        SettingRow {
            title: "Glow"
            description: "Weight -1..1, Bias -1..1, Edges -1..1. Glow = sin(atan)·weight·smoothstep(edge0,edge1,dist)+1+bias, multiplied by refraction."
            stacked: true

            Column {
                width: parent.width
                spacing: Theme.dp(8)

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(70)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Weight"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(78)
                        from: -1
                        to: 1
                        stepSize: 0.05
                        decimals: 2
                        value: Prefs.liquidGlassGlowWeight
                        onMoved: (v) => {
                            Prefs.liquidGlassGlowWeight = v;
                        }
                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(70)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Bias"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(78)
                        from: -1
                        to: 1
                        stepSize: 0.05
                        decimals: 2
                        value: Prefs.liquidGlassGlowBias
                        onMoved: (v) => {
                            Prefs.liquidGlassGlowBias = v;
                        }
                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(70)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Edge0"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(78)
                        from: -1
                        to: 1
                        stepSize: 0.05
                        decimals: 2
                        value: Prefs.liquidGlassGlowEdge0
                        onMoved: (v) => {
                            Prefs.liquidGlassGlowEdge0 = v;
                        }
                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(70)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Edge1"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(78)
                        from: -1
                        to: 1
                        stepSize: 0.05
                        decimals: 2
                        value: Prefs.liquidGlassGlowEdge1
                        onMoved: (v) => {
                            Prefs.liquidGlassGlowEdge1 = v;
                        }
                    }

                }

            }

        }

        SettingRow {
            title: "Blur & Noise — independent of Surfaces > Glass"
            description: "Original BlurIters 0..10, Radius 0..10, Downscale 0.1..1, Noise 0..0.3, Bokeh 0..1 (highlight discs, costs fill-rate). Glass blur is separate from compositor blur (Surfaces > Glass) and modulates refraction."
            stacked: true

            Column {
                width: parent.width
                spacing: Theme.dp(8)

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(90)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Blur Iters"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(98)
                        from: 0
                        to: 10
                        stepSize: 1
                        decimals: 0
                        value: Prefs.liquidGlassBlurIters
                        onMoved: (v) => {
                            Prefs.liquidGlassBlurIters = Math.round(v);
                        }
                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(90)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Blur Radius"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(98)
                        from: 0
                        to: 10
                        stepSize: 0.1
                        decimals: 1
                        value: Prefs.liquidGlassBlurRadius
                        onMoved: (v) => {
                            Prefs.liquidGlassBlurRadius = v;
                        }
                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(90)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Bokeh"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(98)
                        from: 0
                        to: 1
                        stepSize: 0.05
                        decimals: 2
                        value: Prefs.liquidGlassBokeh
                        onMoved: (v) => {
                            Prefs.liquidGlassBokeh = v;
                        }
                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(90)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Downscale"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(98)
                        from: 0.1
                        to: 1
                        stepSize: 0.05
                        decimals: 2
                        value: Prefs.liquidGlassBlurDownscale
                        onMoved: (v) => {
                            Prefs.liquidGlassBlurDownscale = v;
                        }
                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.dp(8)

                    Text {
                        width: Theme.dp(90)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Noise"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                    }

                    M3Slider {
                        width: parent.width - Theme.dp(98)
                        from: 0
                        to: 0.3
                        stepSize: 0.01
                        decimals: 2
                        value: Prefs.liquidGlassNoise
                        onMoved: (v) => {
                            Prefs.liquidGlassNoise = v;
                        }
                    }

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
                onMoved: (v) => {
                    Prefs.liquidGlassOpacity = v;
                }
            }

        }

        SettingRow {
            title: "Reset Liquid Glass"
            description: "Restores all LiquidGlass params to OverShifted defaults (incl. size/blur/opacity)."
            showDivider: false

            M3Button {
                text: "Reset"
                onClicked: {
                    Prefs.resetKeys(["liquidGlassPower", "liquidGlassWidth", "liquidGlassHeight", "liquidGlassA", "liquidGlassB", "liquidGlassC", "liquidGlassD", "liquidGlassFPower", "liquidGlassBlurIters", "liquidGlassBlurRadius", "liquidGlassBokeh", "liquidGlassBlurDownscale", "liquidGlassNoise", "liquidGlassGlowWeight", "liquidGlassGlowBias", "liquidGlassGlowEdge0", "liquidGlassGlowEdge1", "liquidGlassOpacity"]);
                }
            }

        }

    }

    SettingCard {
        title: "MOTION"

        SettingRow {
            title: "Animation speed"
            resetKey: "motionScale"
            description: "Scales every transition in the shell. 1.00x is the shipped speed; drag to 0 for no animation at all."
            showDivider: false
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

    }

    SettingCard {
        title: "DESKTOP"

        SettingRow {
            title: "Selection box"
            resetKey: "desktopSelection"
            description: Prefs.desktopIcons ? "Drag across empty desktop to draw a box, the way it does on Windows and macOS. It selects the icons and the widgets it touches; hold Ctrl or Shift to add icons to what is already selected. Selected widgets move together when you drag any one of them; pinned widgets are left out. Click the desktop to let go." : "Drag across empty desktop to draw a box, the way it does on Windows and macOS. Widgets it touches are selected and move together when you drag any one of them; pinned widgets are left out. Click the desktop to let go."

            M3Switch {
                checked: Prefs.desktopSelection
                onToggled: (v) => {
                    return Prefs.desktopSelection = v;
                }
            }

        }

        SettingRow {
            title: "Right-click menu"
            resetKey: "desktopMenu"
            description: "Right-click empty desktop for wallpaper and theme, the widgets you have placed, a screenshot and settings."
            showDivider: false

            M3Switch {
                checked: Prefs.desktopMenu
                onToggled: (v) => {
                    return Prefs.desktopMenu = v;
                }
            }

        }

    }

    SettingCard {
        title: "DESKTOP ICONS"

        SettingRow {
            title: "Show icons"
            resetKey: "desktopIcons"
            description: "What is in your Desktop folder sits on the wallpaper of the main display, with the drives you plug in. Widgets keep their space: an icon one covers steps to the nearest free cell and goes back when the widget moves. Select with a click or a box, drag into folders, the Trash or any app, and right-click for New Item, Open With, Get Info, tags, compress and more. Ctrl+Z undoes the last change."

            M3Switch {
                checked: Prefs.desktopIcons
                onToggled: (v) => {
                    return Prefs.desktopIcons = v;
                }
            }

        }

        SettingRow {
            title: "Icon theme"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: "Folders, files and apps are drawn by your icon theme, " + (Prefs.envIconTheme !== "" ? Prefs.envIconTheme.replace(/_/g, " ") : "the system's") + ", the same set your apps use. Change it on the Environment page."

            M3Button {
                text: "Environment"
                variant: "tonal"
                enabled: Prefs.desktopIcons
                onClicked: Prefs.settingsRequested("environment")
            }

        }

        SettingRow {
            title: "Size"
            resetKey: "desktopIconSize"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."

            M3Segmented {
                width: Math.max(Theme.dp(240), fitWidth)
                current: Prefs.desktopIconSize
                options: [{
                    "key": "small",
                    "label": "Small"
                }, {
                    "key": "medium",
                    "label": "Medium"
                }, {
                    "key": "large",
                    "label": "Large"
                }]
                onChosen: (key) => {
                    return Prefs.desktopIconSize = key;
                }
            }

        }

        SettingRow {
            title: "Spacing"
            resetKey: "desktopIconSpacing"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: "How far apart the icons sit. Names wrap to two lines either way."

            M3Segmented {
                width: Math.max(Theme.dp(260), fitWidth)
                current: Prefs.desktopIconSpacing
                options: [{
                    "key": "compact",
                    "label": "Compact"
                }, {
                    "key": "normal",
                    "label": "Normal"
                }, {
                    "key": "roomy",
                    "label": "Roomy"
                }]
                onChosen: (key) => {
                    return Prefs.desktopIconSpacing = key;
                }
            }

        }

        SettingRow {
            title: "Arrange by"
            resetKey: "desktopIconsSort"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: "The order new icons take, and the one Arrange By on the desktop's menu puts everything back in. Folders come first."

            M3Segmented {
                width: Math.max(Theme.dp(300), fitWidth)
                current: Prefs.desktopIconsSort
                options: [{
                    "key": "name",
                    "label": "Name"
                }, {
                    "key": "type",
                    "label": "Type"
                }, {
                    "key": "size",
                    "label": "Size"
                }, {
                    "key": "date",
                    "label": "Modified"
                }]
                onChosen: (key) => {
                    DesktopIcons.arrangeBy(key);
                }
            }

        }

        SettingRow {
            title: "Start from"
            resetKey: "desktopIconsCorner"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: "New icons fill the columns from this side of the screen, top to bottom."

            M3Segmented {
                width: Math.max(Theme.dp(180), fitWidth)
                current: Prefs.desktopIconsCorner
                options: [{
                    "key": "left",
                    "label": "Left"
                }, {
                    "key": "right",
                    "label": "Right"
                }]
                onChosen: (key) => {
                    return Prefs.desktopIconsCorner = key;
                }
            }

        }

        SettingRow {
            title: "Order"
            resetKey: "desktopIconsSortDesc"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: "Folders stay first either way."

            M3Segmented {
                width: Math.max(Theme.dp(240), fitWidth)
                current: Prefs.desktopIconsSortDesc ? "desc" : "asc"
                options: [{
                    "key": "asc",
                    "label": "Ascending"
                }, {
                    "key": "desc",
                    "label": "Descending"
                }]
                onChosen: (key) => {
                    Prefs.desktopIconsSortDesc = key === "desc";
                    Qt.callLater(DesktopIcons.arrange);
                }
            }

        }

        SettingRow {
            title: "Auto arrange"
            resetKey: "desktopIconsAutoArrange"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: "Keep every icon in order from the starting corner, the way Windows does. Off, each icon stays where you drop it."

            M3Switch {
                checked: Prefs.desktopIconsAutoArrange
                onToggled: (v) => {
                    return Prefs.desktopIconsAutoArrange = v;
                }
            }

        }

        SettingRow {
            title: "Spring-loaded folders"
            resetKey: "desktopIconsSpring"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: "Hold a drag over a folder for a moment and it opens in your file manager, so you can drop deeper inside, as on a Mac."

            M3Switch {
                checked: Prefs.desktopIconsSpring
                onToggled: (v) => {
                    return Prefs.desktopIconsSpring = v;
                }
            }

        }

        SettingRow {
            title: "Open with"
            resetKey: "desktopIconsOpen"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."

            M3Segmented {
                width: Math.max(Theme.dp(240), fitWidth)
                current: Prefs.desktopIconsOpen
                options: [{
                    "key": "double",
                    "label": "Double click"
                }, {
                    "key": "single",
                    "label": "Single click"
                }]
                onChosen: (key) => {
                    return Prefs.desktopIconsOpen = key;
                }
            }

        }

        SettingRow {
            title: "Previews"
            resetKey: "desktopIconsThumbs"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: "Pictures, videos, music with cover art and documents show what is in them, the way a file manager does, and share its thumbnails."

            M3Switch {
                checked: Prefs.desktopIconsThumbs
                onToggled: (v) => {
                    return Prefs.desktopIconsThumbs = v;
                }
            }

        }

        SettingRow {
            title: "File extensions"
            resetKey: "desktopIconsHideExt"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: Prefs.desktopIconsHideExt ? "Names leave off a short extension like .txt or .png; the whole name shows under the pointer and when selected." : "Every name shows in full, extension and all."

            M3Segmented {
                width: Math.max(Theme.dp(180), fitWidth)
                current: Prefs.desktopIconsHideExt ? "hide" : "show"
                options: [{
                    "key": "show",
                    "label": "Show"
                }, {
                    "key": "hide",
                    "label": "Hide"
                }]
                onChosen: (key) => {
                    return Prefs.desktopIconsHideExt = key === "hide";
                }
            }

        }

        SettingRow {
            title: "Hidden files"
            resetKey: "desktopIconsHidden"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: "Files whose name starts with a dot, shown faded. Ctrl+H on the desktop flips this."

            M3Switch {
                checked: Prefs.desktopIconsHidden
                onToggled: (v) => {
                    return Prefs.desktopIconsHidden = v;
                }
            }

        }

        SettingRow {
            title: "Home folder"
            resetKey: "desktopIconsHome"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."

            M3Switch {
                checked: Prefs.desktopIconsHome
                onToggled: (v) => {
                    return Prefs.desktopIconsHome = v;
                }
            }

        }

        SettingRow {
            title: "Trash"
            resetKey: "desktopIconsTrash"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: "Drop files on it to throw them away; right-click it to empty it."

            M3Switch {
                checked: Prefs.desktopIconsTrash
                onToggled: (v) => {
                    return Prefs.desktopIconsTrash = v;
                }
            }

        }

        SettingRow {
            title: "Drives"
            resetKey: "desktopIconsDrives"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: "USB sticks, phones and other drives while they are mounted. Right-click one to eject it."

            M3Switch {
                checked: Prefs.desktopIconsDrives
                onToggled: (v) => {
                    return Prefs.desktopIconsDrives = v;
                }
            }

        }

        SettingRow {
            title: "Add an app"
            enabled: Prefs.desktopIcons
            disabledReason: "Turn on Show icons first."
            description: "Puts a launcher for it on the desktop. Launchers that arrive any other way ask before they run the first time."
            showDivider: false

            M3Button {
                text: "Choose\u2026"
                variant: "tonal"
                enabled: Prefs.desktopIcons
                onClicked: Prefs.appPickerRequested("::desktop")
            }

        }

    }

    SettingCard {
        title: "SCREENSHOTS"

        SettingRow {
            title: "After a capture"
            resetKey: "shotPreview"
            description: Prefs.shotPreview === "preview" ? "A card in the corner shows it, to open, mark up, drag into an app, find in its folder or delete. Recordings get one too." : (Prefs.shotPreview === "notify" ? "A notification says where it went. Screenshots are on the clipboard either way." : "Nothing shows. Screenshots are still copied to the clipboard.")

            M3Segmented {
                width: Math.max(Theme.dp(300), fitWidth)
                current: Prefs.shotPreview
                options: [{
                    "key": "preview",
                    "label": "Preview"
                }, {
                    "key": "notify",
                    "label": "Notification"
                }, {
                    "key": "none",
                    "label": "Nothing"
                }]
                onChosen: (key) => {
                    return Prefs.shotPreview = key;
                }
            }

        }

        SettingRow {
            title: "Preview stays for"
            resetKey: "shotPreviewSeconds"
            enabled: Prefs.shotPreview === "preview"
            description: "Resting the pointer on the card holds it for as long as you like."
            showDivider: false
            stacked: true

            M3Slider {
                width: parent.width
                enabled: Prefs.shotPreview === "preview"
                from: 3
                to: 20
                stepSize: 1
                suffix: " s"
                value: Prefs.shotPreviewSeconds
                onMoved: (v) => {
                    return Prefs.shotPreviewSeconds = v;
                }
            }

        }

    }

    SettingCard {
        title: "ON-SCREEN DISPLAY"

        SettingRow {
            title: "Caps Lock"
            resetKey: "osdCapsLock"
            description: Prefs.osdCapsLock ? "A card shows ABC or abc as Caps Lock goes on or off." : "Caps Lock changes without a card. Its sound has a switch of its own in Sound."

            M3Switch {
                checked: Prefs.osdCapsLock
                onToggled: (v) => {
                    Prefs.osdCapsLock = v;
                }
            }

        }

        SettingRow {
            title: "Num Lock"
            resetKey: "osdNumLock"
            description: Prefs.osdNumLock ? "A card shows 123 or arrows as Num Lock goes on or off." : "Num Lock changes without a card."
            showDivider: false

            M3Switch {
                checked: Prefs.osdNumLock
                onToggled: (v) => {
                    Prefs.osdNumLock = v;
                }
            }

        }

    }

}
