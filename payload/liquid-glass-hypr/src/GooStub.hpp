#pragma once

// Temporary 0.57 build shim: the goo workspace-morph driver still uses the
// pre-0.57 numeric WORKSPACEID and the old per-frame render state, so it is
// compiled out of this build until it gets its own port. Glass, borders,
// shadows and the window wash are independent of it.

#include <hyprland/src/SharedDefs.hpp>
#include <hyprland/src/desktop/DesktopTypes.hpp>

namespace goo {

struct SMorphSave {
    bool warped = false;
};

inline void initMorph(void*) {}
inline void exitMorph() {}

inline bool transitioning(MONITORID) {
    return false;
}

inline SMorphSave beginWindowMorph(PHLWINDOW, PHLMONITOR, bool, bool) {
    return {};
}

inline void endWindowMorph(PHLWINDOW, const SMorphSave&) {}

} // namespace goo
