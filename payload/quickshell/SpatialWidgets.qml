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
    // Screen -> stable uid list. The foreground Repeater is keyed on this, not
    // on the geometry array, so a moving card updates its delegate's bindings
    // instead of destroying and recreating every delegate on each 30 Hz tick.
    property var uids: ({})
    // Screen -> { uid: rect }, replaced on every geometry update so the
    // delegates can do one O(1) lookup without rebuilding the model.
    property var byUid: ({})
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

        const map = {};
        const ids = [];
        for (let i = 0; i < list.length; i++) {
            const r = list[i];
            if (!r || r.uid === undefined)
                continue;
            map[r.uid] = r;
            ids.push(r.uid);
        }
        const by = {};
        for (const key in root.byUid)
            by[key] = root.byUid[key];
        by[screen] = map;
        root.byUid = by;

        const prev = root.uids[screen] || [];
        let same = prev.length === ids.length;
        if (same) {
            for (let i = 0; i < ids.length; i++) {
                if (prev[i] !== ids[i]) {
                    same = false;
                    break;
                }
            }
        }
        if (!same) {
            const u = {};
            for (const key in root.uids)
                u[key] = root.uids[key];
            u[screen] = ids;
            root.uids = u;
        }
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
        const by = {};
        for (const key in root.byUid) {
            if (key !== screen)
                by[key] = root.byUid[key];
        }
        root.byUid = by;
        const u = {};
        for (const key in root.uids) {
            if (key !== screen)
                u[key] = root.uids[key];
        }
        root.uids = u;
    }
}
