import QtQuick
import qs
import "../squircle"

// QML glass removed: liquid-glass-hypr compositor plugin owns all glass.
// This stub keeps the public API so existing call sites don't break.
// - externalGlass:true  -> transparent (plugin draws behind)
// - externalGlass:false -> solid Theme.bg fallback (no shader, no capture)
Item {
    id: root
    property color baseColor: Theme.alpha(Theme.bgOpaque, Prefs.liquidGlassOpacity)
    property real powerFactor: Prefs.liquidGlassPower
    property real glassWidth: Prefs.liquidGlassWidth
    property real glassHeight: Prefs.liquidGlassHeight
    property real a: Prefs.liquidGlassA
    property real b: Prefs.liquidGlassB
    property real c: Prefs.liquidGlassC
    property real d: Prefs.liquidGlassD
    property real fPower: Prefs.liquidGlassFPower
    property real noiseAmount: Prefs.liquidGlassNoise
    property real blurRadius: Prefs.liquidGlassBlurRadius
    property real blurDownscale: Prefs.liquidGlassBlurDownscale
    property real blurIters: Prefs.liquidGlassBlurIters
    property real glowWeight: Prefs.liquidGlassGlow ? Prefs.liquidGlassGlowWeight : 0
    property real glowBias: Prefs.liquidGlassGlowBias
    property real glowEdge0: Prefs.liquidGlassGlowEdge0
    property real glowEdge1: Prefs.liquidGlassGlowEdge1
    property bool glassEnabled: Prefs.liquidGlassEnabled
    property bool externalGlass: false
    property real bgRadius: 0
    property real bgTopLeftRadius: -1
    property real bgTopRightRadius: -1
    property real bgBottomLeftRadius: -1
    property real bgBottomRightRadius: -1
    property bool usePill: true
    property real glassOpacity: Prefs.liquidGlassOpacity
    property var hostWindow: null
    property var targetScreen: null

    SquircleRect {
        anchors.fill: parent
        fillColor: Theme.bg
        radius: root.bgRadius
        topLeftRadius: root.bgTopLeftRadius >= 0 ? root.bgTopLeftRadius : root.bgRadius
        topRightRadius: root.bgTopRightRadius >= 0 ? root.bgTopRightRadius : root.bgRadius
        bottomLeftRadius: root.bgBottomLeftRadius >= 0 ? root.bgBottomLeftRadius : root.bgRadius
        bottomRightRadius: root.bgBottomRightRadius >= 0 ? root.bgBottomRightRadius : root.bgRadius
        smoothing: Prefs.squircleF
        visible: !root.externalGlass
        z: -1
    }
}
