import QtQuick
import Quickshell
pragma Singleton

// The hairline Hyprland draws around a window that is not focused, so the
// bar's surfaces can wear the same one instead of a style of their own.
// Read back from the compositor rather than from the config files: Settings
// can override either value, and a palette change reloads Hyprland.
Singleton {
    id: root

    // HyprConfig only talks to hyprctl when a page asks it to; the bar asks
    // as soon as it is built so the first frame already has the real recipe.
    Component.onCompleted: {
        if (Object.keys(HyprConfig.live).length === 0)
            HyprConfig.refresh();
    }

    // general:border_size. QML px and Hyprland's layout px are the same unit -
    // both are scaled by the output - so no conversion belongs here.
    readonly property real size: Math.max(0, Number(HyprConfig.num("general.border_size", 2)))
    // general:col.inactive_border; the first stop stands for a gradient
    readonly property color colour: {
        const c = HyprConfig.coloursOf(HyprConfig.value("general.col.inactive_border"));
        return c.length > 0 ? c[0] : "transparent";
    }
}
