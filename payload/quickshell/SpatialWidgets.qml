import QtQuick
import Quickshell
pragma Singleton

// Screen name -> the visible widget cards on that output, in layer-local logical
// pixels. SpatialWidgetForeground samples the subject cutout inside these rects:
// when a card is hovered the foreground is hidden there, so the widget comes
// forward for interaction while its neighbours still sit behind the subject.
Singleton {
    id: root

    property var rects: ({})
    // uid -> hovered. Kept apart from the geometry array so a hover does not
    // rebuild the Repeater delegates (which would skip the fade).
    property var hovered: ({})

    function update(screen, list) {
        if (screen === undefined || screen === null || screen === "")
            return ;
        const next = {};
        for (const key in root.rects)
            next[key] = root.rects[key];
        next[screen] = list;
        root.rects = next;
    }

    function updateHovered(map) {
        const next = {};
        for (const key in root.hovered)
            next[key] = root.hovered[key];
        for (const key in map)
            next[key] = map[key] === true;
        root.hovered = next;
    }

    function clearHovered(uids) {
        const next = {};
        for (const key in root.hovered) {
            if (uids.indexOf(key) < 0)
                next[key] = root.hovered[key];
        }
        root.hovered = next;
    }

    function clear(screen) {
        if (screen === undefined || screen === null || screen === "")
            return ;
        const next = {};
        for (const key in root.rects) {
            if (key !== screen)
                next[key] = root.rects[key];
        }
        root.rects = next;
    }
}
