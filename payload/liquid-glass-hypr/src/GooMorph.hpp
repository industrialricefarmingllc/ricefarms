#pragma once

// Workspace-morph driver. Lives inside liquid-glass-hypr because there is
// exactly ONE renderWindow trampoline slot: liquid-glass owns it, so the
// morph warps windows from inside its hook (see hkRenderWindow) instead of
// fighting over the hook. Everything else (rounding hook, pass element,
// events) is collision-free.
//
// Mechanism: workspace.active opens a per-monitor transition and pins the
// outgoing workspace with m_forceRendering so its windows still render.
// beginWindowMorph() (called first in hkRenderWindow, so glass snapshots see
// warped geometry and follow the morph) warps the window's position/size +
// move-from-workspace alpha animvars, and sets the m_animatingIn stretch
// flag (upstream stretches sub-full-size boxes only for in-animations —
// otherwise content crops 1:1 showing its top-left). Surface elements sample
// all three AFTER the hook returns (pass execution), so everything persists
// to RENDER_POST of the same frame, which restores + drops it all: bounded
// per frame, nothing strands. Every begin restores clean from the live entry
// (no compounding across passes) and self-heals the channel. Floor the fade
// above 0 (fade_out_min 0.02): Hyprland skips effectiveAlpha==0 windows
// before drawing, and skipped windows run no hooks — 0.0 would strand.
// Progress + finish are driven from every path that observes a live
// transition (hook, rounding, goo pass) — never from tick, which only fires
// while native animations run.

#include <hyprland/src/SharedDefs.hpp>
#include <hyprland/src/desktop/DesktopTypes.hpp>

#include "GooTransition.hpp"

#include <vector>

namespace goo {

struct SMorphSave {
    Vector2D  pos{0, 0};
    Vector2D  size{0, 0};
    float     alphaFrom   = 1.0f; // saved WINDOW_ALPHA_MOVE_FROM_WORKSPACE
    MONITORID mon         = MONITOR_INVALID;
    bool      warped      = false;
    bool      alphaWarped = false;
    bool      wasAnimatingIn = false; // m_animatingIn before the warp (stretch flag)
};

// One morphing window's rect for this frame (global logical px), consumed by
// the funnel pass element queued at POST_WINDOWS. Outgoing windows grow a
// leading funnel to the edge point (early) plus a trailing point behind
// (delayed); incoming windows emerge from the edge point (early).
struct SMorphTip {
    CBox box{0, 0, 0, 0};
    int  side     = 1;
    bool vertical = false;
    Role role = Role::NONE;
};

void       initMorph(void* handle);
void       exitMorph();
// Warp the window for this frame if it participates in a live transition.
// Never throws; returns unwarped save when idle/skipped.
SMorphSave beginWindowMorph(PHLWINDOW window, PHLMONITOR monitor, bool ignorePosition, bool standalone);
void       endWindowMorph(PHLWINDOW window, const SMorphSave& save);
// Drain this frame's outgoing rects for a monitor (clears the store).
std::vector<SMorphTip> takeTips(MONITORID mon);

} // namespace goo
