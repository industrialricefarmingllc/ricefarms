import QtQuick
import Quickshell
import Quickshell.Io
pragma Singleton

// Everything the widget needs from Lucid's theme, and nothing from the shell's
// object tree. The tone maths below is the same maths Lucid uses, so bgOpaque,
// accent and the containers resolve to the same colours as the bar and cards.
// Each source is watched: a wallpaper change, a light/dark flip, a settings
// tweak or a new surface seed lands without restarting the widget.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (root.home + "/.config")

    FileView {
        id: paletteFile

        path: root.home + "/.cache/quickshell/matugen.json"
        watchChanges: true
        blockLoading: true
        onFileChanged: reload()

        adapter: JsonAdapter {
            id: pal

            property string primary: "#a8c7fa"
            property string on_primary: "#062e6f"
            property string primary_container: "#0842a0"
            property string on_primary_container: "#d3e3fd"
            property string secondary: "#bec6dc"
            property string on_secondary: ""
            property string secondary_container: "#3e4759"
            property string on_secondary_container: ""
            property string tertiary: "#ddbce0"
            property string on_tertiary: "#3f2844"
            property string tertiary_container: ""
            property string on_tertiary_container: ""
            property string error: "#ffb4ab"
            property string on_error: "#690005"
            property string error_container: "#93000a"
            property string on_error_container: ""
            property string surface: "#111318"
            property string on_surface: "#e2e2e9"
            property string surface_variant: "#44474f"
            property string on_surface_variant: "#c4c6d0"
            property string surface_dim: "#111318"
            property string surface_bright: ""
            property string surface_tint: ""
            property string surface_container_lowest: "#0c0e13"
            property string surface_container_low: "#191c20"
            property string surface_container: "#1d2024"
            property string surface_container_high: "#282a2f"
            property string surface_container_highest: "#33353a"
            property string outline: "#8e9099"
            property string outline_variant: "#44474f"
            property string inverse_surface: "#e2e2e9"
            property string inverse_on_surface: ""
            property string inverse_primary: ""
            property string shadow: "#000000"
            property string scrim: "#000000"
            property string source_color: ""
        }

    }

    FileView {
        id: surfaceSeed

        path: root.home + "/.cache/quickshell/surface-seed.json"
        watchChanges: true
        blockLoading: true
        onFileChanged: reload()

        adapter: JsonAdapter {
            id: seed

            property real hue: -1
            property real saturation: 0
        }

    }

    FileView {
        id: themeModeFile

        path: root.home + "/.cache/quickshell/theme_mode"
        watchChanges: true
        blockLoading: true
        onFileChanged: reload()
        onLoaded: root.themeMode = text().trim() || "dark"
    }

    FileView {
        id: prefsFile

        path: root.configHome + "/quickshell/lucidprefs/prefs.json"
        watchChanges: true
        blockLoading: true
        onFileChanged: reload()

        adapter: JsonAdapter {
            id: prefs

            property real uiScale: 1
            property real fontScale: 1
            property real motionScale: 1
            property real cornerScale: 1
            property real squircleF: 0.8
            property real surfaceDarkness: -1
            property real surfaceTint: -1
            property real accentPunch: 1
            property bool barEnabled: true
            property int barHeight: 37
            property int barTopMargin: 16
            property int shellGap: 0
        }

    }

    FontLoader {
        id: flex

        source: "file://" + root.home + "/.config/quickshell/assets/fonts/GoogleSansFlex.ttf"
    }

    readonly property string fontFamily: flex.status === FontLoader.Ready ? flex.name : "Noto Sans"
    // Language names switch scripts, so use Noto Sans here rather than the
    // Latin-oriented display face. Qt falls back to the script-specific Noto
    // families when a glyph is outside the base face.
    readonly property string scriptFontFamily: "Noto Sans"
    property string themeMode: "dark"

    // ---- palette -----------------------------------------------------------
    readonly property color cPrimary: pal.primary
    readonly property color cOnPrimary: pal.on_primary
    readonly property color cPrimaryContainer: pal.primary_container
    readonly property color cOnPrimaryContainer: pal.on_primary_container
    readonly property color cSecondary: pal.secondary
    readonly property color cSecondaryContainer: pal.secondary_container
    readonly property color cTertiary: pal.tertiary
    readonly property color cOnTertiary: pal.on_tertiary
    readonly property color cError: pal.error
    readonly property color cOnError: pal.on_error
    readonly property color cErrorContainer: pal.error_container
    readonly property color cOnErrorContainer: pal.on_error_container !== "" ? pal.on_error_container : root.atTone(root.cError, root.isLight ? 10 : 90)
    readonly property color cSurface: pal.surface
    readonly property color cOnSurface: pal.on_surface
    readonly property color cSurfaceVariant: pal.surface_variant
    readonly property color cOnSurfaceVariant: pal.on_surface_variant
    readonly property color cLowest: pal.surface_container_lowest
    readonly property color cLow: pal.surface_container_low
    readonly property color cContainer: pal.surface_container
    readonly property color cHigh: pal.surface_container_high
    readonly property color cHighest: pal.surface_container_highest
    readonly property color cOutline: pal.outline
    readonly property color cOutlineVariant: pal.outline_variant
    readonly property color cShadow: pal.shadow
    readonly property color cScrim: pal.scrim

    readonly property bool isLight: root.tone(root.cSurface) > 50
    readonly property bool isLightMode: root.themeMode === "light"
    readonly property int _dir: root.isLight ? -1 : 1

    // ---- Lucid's surface / accent derivation -------------------------------
    readonly property real pillDarkness: prefs.surfaceDarkness >= 0 ? prefs.surfaceDarkness : 0
    readonly property real surfaceTint: prefs.surfaceTint >= 0 ? prefs.surfaceTint : (root.isLight ? 0.7 : 0)
    readonly property color surfaceTintSource: seed.hue >= 0 ? Qt.hsla(seed.hue / 360, Math.max(0.35, Math.min(0.8, seed.saturation > 0 ? seed.saturation : 0.4)), 0.55, 1) : root.cPrimary
    readonly property real accentPunch: prefs.accentPunch !== undefined ? prefs.accentPunch : 1
    readonly property real _toneShift: root.pillDarkness * 3
    readonly property real _tintLift: 10
    readonly property real _tintTarget: 0.13
    readonly property color _containerSeed: root.cPrimaryContainer !== "" ? root.cPrimaryContainer : root.cSurface
    readonly property real _containerHue: 0
    readonly property real _containerSatFloor: 0.22
    readonly property real _containerTone: root.isLight ? 30 : Math.max(30, root.tone(root.mHigh) + 2)
    readonly property real _containerInkTone: Math.min(98, Math.max(90, root._containerTone + 45))
    readonly property real _rampShift: root.surfaceTint <= 0 ? 0 : (root.isLight ? Math.max(0, root.tone(root.cLowest) - (100 - root.surfaceTint * root._tintLift)) : -(root.surfaceTint * root._tintLift))

    readonly property color mSurface: root.surface(root.cSurface, root._toneShift)
    readonly property color mLowest: root.surface(root.cLowest, root._toneShift)
    readonly property color mLow: root.surface(root.cLow, root._toneShift)
    readonly property color mContainer: root.surface(root.cContainer, root._toneShift)
    readonly property color mHigh: root.surface(root.cHigh, root._toneShift)
    readonly property color mHighest: root.surface(root.cHighest, root._toneShift)

    readonly property color bgOpaque: root.mContainer
    readonly property color bgHigh: root.mHighest
    readonly property color bgLow: root.mLow

    readonly property color accentBase: root.accentPunch === 1 ? root.cPrimary : root.atTone(root.cPrimary, root.tone(root.cPrimary) + root._dir * (root.accentPunch - 1) * 9)
    readonly property color accent: root.isLightMode ? Qt.lighter(root.accentBase, 1.6) : root.accentBase
    readonly property color accentHover: root.atTone(root.accent, Math.max(0, Math.min(100, root.tone(root.accent) + root._dir * 6)))
    readonly property color accentPressed: root.atTone(root.accent, Math.max(0, Math.min(100, root.tone(root.accent) - root._dir * 6)))
    readonly property color fgOnFill: root.containerFill(root._containerSeed, root.isLight ? 98 : 20)
    readonly property color fgAccent: root.fgOnFill
    readonly property color accentContainer: root.containerFill(root._containerSeed, root._containerTone, root.isLight ? root._containerSatFloor : Math.min(1, Math.max(root._containerSatFloor, root.mHigh.hslSaturation * 1.15)))
    readonly property color fgAccentContainer: root.containerInk(root._containerSeed)
    readonly property color accentMuted: root.atTone(root.withSat(root.cPrimary, 0.55), (root.tone(root.cPrimary) + root.tone(root.cOnSurfaceVariant)) / 2)

    readonly property color outline: root.tint(root.cOutlineVariant, 1.8)
    readonly property color outlineStrong: root.tint(root.cOutline, 1.8)
    readonly property color divider: root.alpha(root.cOutlineVariant, root.isLight ? 0.7 : 0.55)

    readonly property color error: root.cError
    readonly property color fgError: root.fgOnFill
    readonly property color errorContainer: root.containerFill(root.cError, root._containerTone, root.isLight ? root._containerSatFloor : Math.min(1, Math.max(root._containerSatFloor, root.mHigh.hslSaturation * 1.15)))
    readonly property color fgErrorContainer: root.containerInk(root.cError)
    readonly property color onErrorContainer: root.fgErrorContainer

    // Mirrors Lucid's card shadow: a tinted near-black in light mode, neutral
    // in dark. It sits under the card, and the compositor's soft-light wash
    // lands on top of both.
    readonly property color cardShadow: root.isLightMode ? root.alpha(root.atTone(root.cPrimary, 10), 0.20) : Qt.rgba(0, 0, 0, 0.20)

    // ---- roles the widget consumes ----------------------------------------
    readonly property color card: root.bgOpaque
    readonly property color cardBorder: root.alpha(root.outline, root.isLight ? 0.32 : 0.28)
    readonly property color text: root.cOnSurface
    readonly property color subtext: root.cOnSurfaceVariant
    readonly property color subtextDim: root.tint(root.atTone(root.cOnSurfaceVariant, root.isLight ? 50 : 65), 1.5)
    readonly property color primary: root.accent
    readonly property color onPrimary: root.fgAccent
    readonly property color onAccent: root.fgAccent
    readonly property color primaryContainer: root.accentContainer
    readonly property color onPrimaryContainer: root.fgAccentContainer
    readonly property color surfaceLow: root.mLow
    readonly property color surfaceContainer: root.mContainer
    readonly property color surfaceHigh: root.mHigh
    readonly property color surfaceHighest: root.mHighest
    readonly property color composer: root.surfaceHigh
    readonly property color composerBorder: root.alpha(root.outline, root.isLight ? 0.30 : 0.22)
    readonly property color assistantBubble: root.surfaceHigh
    readonly property color userBubble: root.primaryContainer
    readonly property color userText: root.onPrimaryContainer
    readonly property color chip: root.surfaceHigh
    // The language selection is the widget's primary highlight, so it uses
    // the shell's accent rather than a tonal container: same emphasis as the
    // launcher's selected mode pill and the bar's active workspace.
    readonly property color chipSelected: root.accent
    readonly property color chipText: root.subtext
    readonly property color chipSelectedText: root.fgAccent
    readonly property color shadow: root.cardShadow

    // ---- metrics -----------------------------------------------------------
    readonly property real uiScale: Math.max(0.7, Math.min(1.3, prefs.uiScale || 1))
    readonly property real fontScale: (prefs.fontScale || 1) * 0.9 * root.uiScale
    readonly property real motionScale: (prefs.motionScale || 1) * 1.125
    readonly property real cornerScale: Math.max(0, Math.min(1.5, prefs.cornerScale === undefined ? 1 : prefs.cornerScale))
    readonly property real squircleF: Math.max(0, Math.min(1, prefs.squircleF === undefined ? 0.8 : prefs.squircleF))
    // The bar can briefly report reserved=0 while it remaps. Fall back to the
    // same numbers Lucid writes to prefs so the card never pops under it.
    readonly property real lucidBarReserved: prefs.barEnabled ? Math.max(0, prefs.barHeight + prefs.barTopMargin + prefs.shellGap) : 0

    readonly property var curveSpatial: [0.38, 1.21, 0.22, 1, 1, 1]
    readonly property var curveEmphasized: [0.05, 0.7, 0.1, 1, 1, 1]
    readonly property var curveAccelerate: [0.3, 0, 0.8, 0.15, 1, 1]
    readonly property var curveStandard: [0.2, 0, 0, 1, 1, 1]

    function dp(px) {
        return Math.round(px * root.uiScale);
    }

    function fs(px) {
        return Math.round(px * root.fontScale);
    }

    function rad(px) {
        return px < 8 ? root.dp(px) : Math.round(px * root.uiScale * root.cornerScale);
    }

    function pill(size) {
        return size / 2 * Math.min(1, root.cornerScale);
    }

    function ms(duration) {
        return Math.round(duration * root.motionScale);
    }

    function axes(px, weight, round) {
        return {
            "wght": Math.round(Math.max(100, Math.min(800, weight || 400)) / 25) * 25,
            "opsz": Math.round(px),
            "ROND": Math.round((round || 0) / 10) * 10
        };
    }

    function alpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    // ---- Lucid tone maths --------------------------------------------------
    function _lin(c) {
        return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    }

    function _gam(c) {
        var v = c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
        return Math.max(0, Math.min(1, v));
    }

    function _y(c) {
        return 0.2126 * root._lin(c.r) + 0.7152 * root._lin(c.g) + 0.0722 * root._lin(c.b);
    }

    function _yAt(t) {
        return t <= 8 ? t / 903.2963 : Math.pow((t + 16) / 116, 3);
    }

    function tone(c) {
        var y = root._y(c);
        return y <= 0.008856 ? y * 903.2963 : 116 * Math.pow(y, 1 / 3) - 16;
    }

    function atTone(c, t) {
        var tt = Math.max(0, Math.min(100, t));
        var target = root._yAt(tt);
        var y = root._y(c);
        if (y <= 0) {
            var g = root._gam(target);
            return Qt.rgba(g, g, g, c.a);
        }
        var k = target / y;
        var lr = root._lin(c.r) * k;
        var lg = root._lin(c.g) * k;
        var lb = root._lin(c.b) * k;
        var peak = Math.max(lr, lg, lb);
        if (peak > 1) {
            lr /= peak;
            lg /= peak;
            lb /= peak;
            var yb = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb;
            var w = yb >= 1 ? 0 : Math.max(0, Math.min(1, (target - yb) / (1 - yb)));
            lr += (1 - lr) * w;
            lg += (1 - lg) * w;
            lb += (1 - lb) * w;
        }
        return Qt.rgba(root._gam(lr), root._gam(lg), root._gam(lb), c.a);
    }

    function tonal(c, t) {
        var h = c.hslHue;
        if (h < 0)
            return root.atTone(c, t);

        var lift = 1 + Math.max(0, (50 - t) / 50) * 3;
        var s = Math.min(1, c.hslSaturation * lift);
        return root.atTone(Qt.hsla(h, s, 0.5, c.a), t);
    }

    function shade(c, tones) {
        return tones === 0 ? c : root.atTone(c, root.tone(c) - tones);
    }

    function tint(c, k) {
        return root.tintTo(c, k, root.cPrimary);
    }

    function tintTo(c, k, source) {
        if (k <= 0)
            return c;

        var h = source.hslHue;
        if (h < 0)
            return c;

        var t = root.tone(c);
        var pure = root.atTone(Qt.hsla(h, Math.max(0.55, Math.min(1, source.hslSaturation)), 0.55, 1), t);
        var head = root.chromaOf(pure);
        if (head <= 0.001)
            return c;

        var f = Math.min(1, k * root._tintTarget / head);
        var mx = root._mix(c, pure, f);
        return root.atTone(Qt.rgba(mx.r, mx.g, mx.b, c.a), t);
    }

    function chromaOf(c) {
        return Math.max(c.r, c.g, c.b) - Math.min(c.r, c.g, c.b);
    }

    function surface(c, tones) {
        return root.tintTo(root.shade(c, tones + root._rampShift), root.surfaceTint, root.surfaceTintSource);
    }

    function withSat(c, k) {
        var h = c.hslHue;
        if (h < 0)
            return c;

        var s = Math.max(0, Math.min(1, c.hslSaturation * k));
        return root.atTone(Qt.hsla(h, s, c.hslLightness, c.a), root.tone(c));
    }

    function containerFill(c, t, floor) {
        var h = c.hslHue;
        if (h < 0)
            return root.atTone(c, t);

        var hh = (h + root._containerHue / 360) % 1;
        if (hh < 0)
            hh += 1;

        var s = Math.max(c.hslSaturation, floor === undefined ? root._containerSatFloor : floor);
        return root.atTone(Qt.hsla(hh, s, 0.5, c.a), t);
    }

    function containerInk(c) {
        return root.containerFill(c, root._containerInkTone);
    }

    function _mix(a, b, t) {
        return Qt.rgba(a.r * (1 - t) + b.r * t, a.g * (1 - t) + b.g * t, a.b * (1 - t) + b.b * t, 1);
    }

}
