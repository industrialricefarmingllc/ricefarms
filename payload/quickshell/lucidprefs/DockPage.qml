import QtQuick
import qs

Column {
    id: page

    // shown in edit mode's sheet beside the dock itself, which needs no preview
    property bool inSheet: false

    spacing: Theme.dp(26)

    DockPreview {
        width: parent.width
        visible: !page.inSheet
    }

    SettingCard {
        title: Tr.t("ON THE DESKTOP")
        visible: !page.inSheet

        SettingRow {
            title: Tr.t("Edit the dock where it is")
            description: Tr.t("In edit mode the desktop shades over and the dock gets a handle: drag it up to float the dock higher, or down into the bottom edge to make it a notch. Right-click the dock for these settings, right beside it.")
            enabled: Prefs.dockEnabled
            disabledReason: "The dock is switched off."
            showDivider: false

            M3Button {
                text: Tr.t("Edit the dock")
                variant: "filled"
                iconPath: "edit"
                enabled: Prefs.dockEnabled
                onClicked: Edit.enterFromSettings("dock", "dock")
            }

        }

    }

    SettingCard {
        title: Tr.t("STYLE")

        SettingRow {
            title: Tr.t("Dock style")
            resetKey: "dockStyle"
            description: Prefs.dockSplit ? Tr.t("The launcher, your pinned apps and the running ones each float on an island of their own, the way the bar's modules do. They close up into one as the launcher opens out of them, and part again when it closes.") : (Prefs.dockNotch ? Tr.t("The dock sits flush against the bottom edge, its lower corners sweeping out into it.") : Tr.t("The dock floats above the bottom edge as one rounded island."))

            M3Segmented {
                width: Math.max(Theme.dp(300), fitWidth)
                current: Prefs.dockStyle
                options: [{
                    "key": "island",
                    "label": "Island"
                }, {
                    "key": "notch",
                    "label": "Notch"
                }, {
                    "key": "split",
                    "label": "Split"
                }]
                onChosen: (key) => {
                    return Prefs.dockStyle = key;
                }
            }

        }

        SettingRow {
            title: Tr.t("Edge blend")
            resetKey: "dockNotchFlare"
            description: Tr.t("How far the dock's lower corners sweep out into the bottom of the screen, so it reads as carved out of the edge rather than resting on it.")
            enabled: Prefs.dockNotch
            disabledReason: "Only a notch meets the screen edge, so there is nothing to blend into - set Dock style to Notch above."
            stacked: true

            M3Slider {
                width: parent.width
                enabled: Prefs.dockNotch
                from: 0
                to: 40
                stepSize: 1
                suffix: " px"
                value: Prefs.dockNotchFlare
                onMoved: (v) => {
                    return Prefs.dockNotchFlare = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Island gap")
            resetKey: "dockSplitGap"
            description: Tr.t("How far apart the launcher's island, the pinned apps' and the running apps' sit.")
            enabled: Prefs.dockSplit
            disabledReason: "Only a split dock has islands to space out - set Dock style to Split above."
            showDivider: false
            stacked: true

            M3Slider {
                width: parent.width
                enabled: Prefs.dockSplit
                from: 4
                to: 24
                stepSize: 1
                suffix: " px"
                value: Prefs.dockSplitGap
                onMoved: (v) => {
                    return Prefs.dockSplitGap = v;
                }
            }

        }

    }

    SettingCard {
        title: Tr.t("SIZE & PLACEMENT")

        SettingRow {
            title: Tr.t("Icon size")
            resetKey: "dockIconSize"
            description: Tr.t("The size of each icon's slot in the dock. The dock's own height follows it.")
            stacked: true

            M3Slider {
                width: parent.width
                from: 32
                to: 72
                stepSize: 1
                suffix: " px"
                value: Prefs.dockIconSize
                onMoved: (v) => {
                    return Prefs.dockIconSize = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Icon padding")
            resetKey: "dockIconPadding"
            description: Tr.t("How far each icon is inset inside its own slot. More padding shrinks the icon without moving the dock.")
            stacked: true

            M3Slider {
                width: parent.width
                from: 0
                to: 16
                stepSize: 1
                suffix: " px"
                value: Prefs.dockIconPadding
                onMoved: (v) => {
                    return Prefs.dockIconPadding = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Icon spacing")
            resetKey: "dockSpacing"
            description: Tr.t("The gap between neighbouring icons.")
            stacked: true

            M3Slider {
                width: parent.width
                from: 0
                to: 28
                stepSize: 1
                suffix: " px"
                value: Prefs.dockSpacing
                onMoved: (v) => {
                    return Prefs.dockSpacing = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Dock radius")
            resetKey: "dockRadius"
            description: Tr.t("How round the dock's corners are. Each icon's own corners follow it, up to a full circle.")
            stacked: true

            M3Slider {
                width: parent.width
                from: 0
                to: 40
                stepSize: 1
                suffix: " px"
                value: Prefs.dockRadius
                onMoved: (v) => {
                    return Prefs.dockRadius = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Distance from bottom")
            resetKey: "dockBottomMargin"
            description: Tr.t("How far the dock floats above the bottom edge of the screen.")
            enabled: !Prefs.dockNotch
            disabledReason: "A notch sits flush against the screen edge by definition - set Dock style to Island or Split above to float the dock."
            showDivider: false
            stacked: true

            M3Slider {
                width: parent.width
                enabled: !Prefs.dockNotch
                from: 0
                to: 60
                stepSize: 1
                suffix: " px"
                value: Prefs.dockBottomMargin
                onMoved: (v) => {
                    return Prefs.dockBottomMargin = v;
                }
            }

        }

    }

    SettingCard {
        title: Tr.t("BEHAVIOUR")

        SettingRow {
            title: Tr.t("Hover strength")
            resetKey: "dockHoverEffect"
            description: Tr.t("How far an icon swells and lifts under the pointer. At 0 the icons stay put - hovering still highlights them, it just stops moving them.")
            stacked: true

            M3Slider {
                width: parent.width
                from: 0
                to: 2
                stepSize: 0.1
                suffix: "x"
                value: Prefs.dockHoverEffect
                onMoved: (v) => {
                    return Prefs.dockHoverEffect = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Magnify on hover")
            description: Tr.t("Icons swell as the pointer passes over them, and their neighbours follow in a ripple.")

            M3Switch {
                checked: Prefs.dockMagnify
                onToggled: (v) => {
                    return Prefs.dockMagnify = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Auto-hide")
            description: Tr.t("Always slides the dock off the bottom of the screen until the pointer reaches the edge. Dynamic only does it while a tiled window is open on the workspace, or a floating one overlaps the dock, so it is back whenever the desktop is clear.")
            stacked: true

            M3Segmented {
                width: parent.width
                current: !Prefs.dockAutoHide ? "off" : (Prefs.dockDynamicHide ? "dynamic" : "always")
                options: [{
                    "key": "off",
                    "label": "Off"
                }, {
                    "key": "always",
                    "label": "Always"
                }, {
                    "key": "dynamic",
                    "label": "Dynamic"
                }]
                onChosen: (k) => {
                    Prefs.dockAutoHide = k !== "off";
                    Prefs.dockDynamicHide = k === "dynamic";
                }
            }

        }

        SettingRow {
            title: Tr.t("Show running applications")
            description: Tr.t("Applications that are running but not pinned appear in the dock beside the pinned ones.")

            M3Switch {
                checked: Prefs.dockShowRunning
                onToggled: (v) => {
                    return Prefs.dockShowRunning = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Icon tiles")
            description: Tr.t("Draws a filled tile behind every icon. Material 3 leaves the container empty and lets hover and press do the talking, which is how the dock looks with this off.")
            showDivider: false

            M3Switch {
                checked: Prefs.dockIconTiles
                onToggled: (v) => {
                    return Prefs.dockIconTiles = v;
                }
            }

        }

    }

    SettingCard {
        title: Tr.t("INDICATORS")

        SettingRow {
            title: Tr.t("Running indicator")
            description: Tr.t("A mark beneath any icon whose application is running - one segment per window, widening into a single bar for the window you are focused on.")

            M3Switch {
                checked: Prefs.dockShowIndicators
                onToggled: (v) => {
                    return Prefs.dockShowIndicators = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Tooltips")
            description: Tr.t("The application's name appears above its icon after a short hover.")
            showDivider: false

            M3Switch {
                checked: Prefs.dockShowTooltips
                onToggled: (v) => {
                    return Prefs.dockShowTooltips = v;
                }
            }

        }

    }

    SettingCard {
        title: Tr.t("LAUNCHER")

        SettingRow {
            title: Tr.t("Launcher")
            description: Tr.t("The search panel the dock opens into, its modes, prefixes and the clipboard behind them now has a page of its own.")
            showDivider: false

            M3Button {
                text: Tr.t("Launcher\u2026")
                variant: "tonal"
                onClicked: Prefs.settingsRequested("launcher")
            }

        }

    }

    SettingCard {
        title: Tr.t("PINNED APPLICATIONS")
        visible: !page.inSheet

        SettingRow {
            title: Tr.t("Reset pinned applications")
            description: Tr.t("Puts the dock back to its default set of pinned applications. Anything pinned or reordered since is discarded.")
            showDivider: false

            M3Button {
                text: Tr.t("Reset dock")
                variant: "text"
                destructive: true
                onClicked: Prefs.askReset(Tr.t("Reset pinned applications?"), Tr.t("The dock goes back to its default set of pinned applications. Anything pinned or reordered since is discarded."), Prefs.resetDockToken)
            }

        }

    }

}
