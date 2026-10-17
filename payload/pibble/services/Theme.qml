pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "root:/config"

// The resolved palette, type scale and surfaces every window paints with.
//
// Named schemes plus two computed ones: "matugen" (labelled "Dynamic" in
// settings) samples the current wallpaper for the launcher and volume OSD and
// tints each notification from its own app icon; "custom" is the user's own
// palette from the color picker.
Singleton {
    id: root

    readonly property var presets: [
        {
            id: "amber",
            name: "Amber",
            accent: "#e8a24a",
            fg: "#f3ede4",
            muted: "#8a8378"
        },
        {
            id: "frost",
            name: "Frost",
            accent: "#7ab8e0",
            fg: "#e6eef4",
            muted: "#83919c"
        },
        {
            id: "moss",
            name: "Moss",
            accent: "#a3c76a",
            fg: "#eef3e4",
            muted: "#8d9378"
        },
        {
            id: "rose",
            name: "Rose",
            accent: "#e07a9a",
            fg: "#f4e8ec",
            muted: "#9c8389"
        },
        {
            id: "custom",
            name: "Custom",
            accent: "",
            fg: "",
            muted: ""
        },
        {
            id: "matugen",
            name: "Dynamic",
            accent: "",
            fg: "",
            muted: ""
        }
    ]

    // filled in from matugen (current wallpaper) at startup and on every pick
    property var dynamic: ({
        accent: "#e8a24a",
        fg: "#f3ede4",
        muted: "#8a8a8a",
        container: "#3a332c",
        onContainer: "#f3ede4"
    })
    // user-defined palette, edited via the color picker under the theme row
    readonly property var custom: ({
        accent: Settings.customAccent,
        fg: Settings.customFg,
        muted: Settings.customMuted
    })

    readonly property var active: Settings.theme === "matugen" ? root.dynamic : Settings.theme === "custom" ? root.custom : (root.presets.find(t => t.id === Settings.theme) ?? root.presets[0])

    readonly property color accent: root.active.accent
    readonly property color fg: root.active.fg
    readonly property color muted: root.active.muted
    // Tinted selection fill, Lucid's accentContainer equivalent: matugen's
    // primary_container (with its on_primary_container for content drawn on
    // top) while the Dynamic theme is active, else a translucent accent wash
    // so every other theme keeps a borderless selected state too.
    readonly property color accentContainer: Settings.theme === "matugen" ? root.dynamic.container : Qt.alpha(root.accent, 0.28)
    readonly property color onAccentContainer: Settings.theme === "matugen" ? root.dynamic.onContainer : root.fg
    // Shared system light/dark mode (same file Lucid reads): selects the
    // matugen scheme roles above, and brightens the clock in light mode.
    // A mode flip must resample - dark and light roles are different
    // palettes, not shades of one.
    readonly property bool isLightMode: root.themeMode === "light"
    property string themeMode: "dark"
    onThemeModeChanged: {
        if (Settings.theme === "matugen")
            root.sampleWallpaper();
    }
    FileView {
        path: Quickshell.env("HOME") + "/.cache/quickshell/theme_mode"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.themeMode = text().trim() || "dark"
    }
    // backdrop the launcher dims the screen with
    readonly property color surface: "#0a0908"
    // card surface behind both flyouts
    readonly property color flyoutSurface: "#0c0c10"

    // "" (system default) leaves Settings.fontFamily empty, in which case the
    // launcher follows Lucid's widget font (lucidprefs/prefs.json fontFamily,
    // mirrored live below) and only then falls back to the GTK monospace font
    // the `pibble` script resolved into QS_FONT_FAMILY at startup (see
    // export_font_family) - Qt's own font.family: "" resolution isn't reliable
    // in a bare layer-shell session, the same problem export_icon_theme works
    // around for icons.
    readonly property string fontFamily: Settings.fontFamily || root.lucidFontFamily || Quickshell.env("QS_FONT_FAMILY") || ""

    function fontSize(px: int): int {
        return Math.round(px * Settings.fontScale);
    }

    // Every corner radius the shell draws goes through here, so Settings >
    // General > "Rounded corners" can square all of them with one switch -
    // pass the radius the corner wants when rounding is on. The only radius
    // that deliberately bypasses this is the launch reveal's growing circle
    // (LauncherWindow's growMask, and LaunchPreview's stand-in for it): that
    // one is animation geometry rather than a corner, and the compositor blur
    // region traced to match it is a true ellipse either way (see
    // LauncherState.revealBlurDiameter).
    function radius(px: real): real {
        return Settings.roundedCorners ? px : 0;
    }

    // Shared squircle smoothing, 0..1 (0 = circular corners, 0.5 = classic
    // squircle, 1 = near-rect). Owned by the Lucid settings menu
    // (PREFS > SHAPE > "Squircle corners") and mirrored here read-only, so
    // both shells and the window glass agree on one shape. Falls back to
    // 0.5 when Lucid's prefs file is absent (standalone pibble).
    // The same file also owns the Lucid widget font (fontFamily), mirrored
    // as lucidFontFamily so the launcher defaults to Lucid's typeface.
    property real squircleF: 0.5
    property string lucidFontFamily: ""
    FileView {
        path: Quickshell.env("HOME") + "/.config/quickshell/lucidprefs/prefs.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const prefs = JSON.parse(text());
                root.squircleF = prefs.squircleF ?? 0.5;
                root.lucidFontFamily = prefs.fontFamily ?? "";
            } catch (e) {
                root.squircleF = 0.5;
            }
        }
    }

    // "matugen" ("Dynamic"): near-black card, bubble tinted from the app icon;
    // the volume level bar still follows the wallpaper palette
    readonly property bool tintNotificationsFromIcon: Settings.theme === "matugen"
    readonly property var notification: root.tintNotificationsFromIcon ? ({
            accent: root.active.accent,
            fg: "#f2f0ee",
            muted: "#908c87"
        }) : root.active

    // ---------- matugen (Dynamic theme) ----------

    // Kicked off imperatively from SettingsStore's initial load and from
    // LauncherWindow.commitWallpaper() on every wallpaper pick - never via a
    // `running: Settings.theme === "matugen"`-style binding. That was tried and
    // races: the settings file load is async, so Settings.currentWallpaper is
    // still "" (the adapter's blank default) when the tree is first
    // constructed, even though Settings.theme already reads "matugen" (its
    // default too). The natural fix looked like adding
    // `&& Settings.currentWallpaper !== ""` to the binding, but that still
    // loses: once the load completes, `running` and `command` both react to the
    // same Settings.currentWallpaper change as sibling bindings on this
    // Process, and Qt doesn't guarantee `command` has re-evaluated to the
    // loaded path before `running`'s flip spawns the process - so it reliably
    // ran with an empty $WALL anyway. Driving both imperatively, one statement
    // after the other, forces the ordering.
    function sampleWallpaper(): void {
        if (matugen.running)
            matugen.rerun = true;
        else
            matugen.running = true;
    }

    // External picks (Lucid picker, scripts) never go through pibble's
    // commitWallpaper, so without this the Dynamic palette froze at
    // whatever pibble last sampled itself. The system wallpaper file is
    // live-watched (see Wallpapers.sysWallpaper); a change re-kicks the
    // sampler imperatively, same as the paths above.
    Connections {
        target: Wallpapers
        function onSysWallpaperChanged(): void {
            if (Settings.theme === "matugen")
                root.sampleWallpaper();
        }
    }

    Process {
        id: matugen

        property bool rerun: false
        onRunningChanged: {
            if (!running && rerun) {
                rerun = false;
                Qt.callLater(() => running = true);
            }
        }

        // samples Wallpapers.matugenSource (system wallpaper truth with
        // pibble-record fallback) with the SAME flags as the system run
        // (set-wallpaper.sh: `matugen image WALL -m MODE`, config default
        // prefer) - a `--prefer saturation` override here once produced a
        // completely different primary (#ecc06c vs the system's #8ad0ef)
        // for the same image, so Lucid and pibble visibly disagreed.
        // Roles follow the shared theme mode, like the system templates.
        command: ["bash", "-c", `
            export PATH="$HOME/.local/bin:$PATH"
            command -v matugen >/dev/null || { echo NOMATUGEN; exit 0; }
            img="$1"
            mode="$2"
            [ -n "$img" ] || exit 0
            [ "$mode" = "light" ] || mode="dark"
            matugen image "$img" -m "$mode" --json hex --dry-run 2>/dev/null`, "_", Wallpapers.matugenSource, root.themeMode]

        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "NOMATUGEN") {
                    if (Settings.theme === "matugen")
                        Notifier.missingDependency("matugen not found", "Install matugen to use the Dynamic theme.");
                    return;
                }
                // empty output is benign (the wallpaper daemon not up yet at
                // login, no wallpaper set, or a run torn down early): keep the
                // last palette silently instead of raising a false alarm
                if (!text.trim())
                    return;
                try {
                    const colors = JSON.parse(text).colors;
                    const mode = root.themeMode === "light" ? "light" : "dark";
                    root.dynamic = {
                        accent: colors.primary[mode].color,
                        fg: colors.on_surface[mode].color,
                        muted: colors.outline[mode].color,
                        container: (colors.primary_container[mode] ?? colors.primary[mode]).color,
                        onContainer: (colors.on_primary_container[mode] ?? colors.on_surface[mode]).color
                    };
                } catch (e) {
                    if (Settings.theme === "matugen")
                        Notifier.error("Matugen theme failed", "matugen returned no palette for the current wallpaper");
                }
            }
        }
    }
}
