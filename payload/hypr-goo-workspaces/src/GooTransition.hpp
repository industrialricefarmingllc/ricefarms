#pragma once

// Gooey workspace-switch transition state + morph math.
//
// Reference mapping (see README):
//  - ainalem "Gooey radio buttons": the indicator ball stretches toward the
//    newly selected option and fuses via an SVG goo filter (blur + alpha
//    threshold). Here, outgoing windows are the old selection: they stretch
//    toward the entry side the new workspace comes in from.
//  - konstantindenerz "Blob Switch": the incoming blob wobbles through
//    intermediate shapes then settles with spring overshoot. Here, incoming
//    windows grow from a condensed blob scale with a damped-sine wobble and
//    an easeOutBack overshoot.
//
// v1 is geometry-only (position + anisotropic scale). True metaball fusion
// (screen-space blur/threshold pass) is reserved for v2 — see
// shaders/goo.frag.

#include <hyprland/src/SharedDefs.hpp>
#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/macros.hpp>

#include <chrono>
#include <cstdint>
#include <optional>
#include <unordered_map>

namespace goo {

enum class Role { NONE, OUTGOING, INCOMING };

struct Transform {
    Vector2D offset      = {0, 0}; // logical px, added to window position
    Vector2D anchorShift = {0, 0}; // logical px, moves the scale anchor (collapse point)
    double   scaleX      = 1.0;
    double   scaleY      = 1.0;
};

struct Transition {
    MONITORID   monitor   = MONITOR_INVALID;
    WORKSPACEID oldId     = WORKSPACE_INVALID;
    WORKSPACEID newId     = WORKSPACE_INVALID;
    int         side      = 1; // +1: new enters from right/bottom, -1: left/top
    std::chrono::steady_clock::time_point t0;
    PHLWORKSPACEREF oldWs; // held so m_forceRendering can be cleared at end
    PHLWORKSPACEREF newWs; // held for pointer-identity role matching
    PHLMONITORREF   mon;   // held so the tick handler can damage the monitor
    bool            finished = false;
};

class TransitionManager {
  public:
    void  begin(MONITORID mon, WORKSPACEID oldId, WORKSPACEID newId, int side, PHLWORKSPACE oldWs, PHLWORKSPACE newWs, PHLMONITOR monPtr);
    void  finish(MONITORID mon); // clears force-render flag, damages clean, drops state
    bool  active(MONITORID mon) const;

    // 0..1 progress for the monitor's transition; nullopt when none.
    // Marks finished (but does NOT clear flags — call finish()).
    std::optional<double> progress(MONITORID mon, double durationMs);

    const Transition* get(MONITORID mon) const;

    // Role by workspace ID, with pointer-identity fast path: windowWsPtr is
    // window->m_workspace (may be null). Pointer match is exact; ID compare
    // is the fallback.
    Role roleFor(MONITORID mon, WORKSPACEID windowWs, PHLWORKSPACE windowWsPtr) const;

    // Full morph for one window. monitorLen = monitor width (or height in
    // vertical mode) in logical px, used to scale slide_ratio. side is the
    // transition's entry side (+1: new enters from right/bottom).
    Transform transformFor(Role role, double t, double monitorLen, int side) const;

  private:
    std::unordered_map<MONITORID, Transition> m_transitions;
};

// Easing primitives (also unit-testable in isolation).
double easeLinear(double t);
double easeInExpo(double t);
double easeOutExpo(double t);
double easeInBack(double t);
double easeOutBack(double t);

// Cascade stagger: maps global progress t to a per-window local progress.
// Windows near the entry edge (d=0) start immediately; far ones (d=1) are
// delayed by up to staggerReserve (fraction of the duration). centerCoord is
// the window center along the motion axis, monMin/monLen describe the
// monitor span on that axis. Returns clamped 0..1.
double staggeredT(double t, double centerCoord, double monMin, double monLen, int side);

} // namespace goo
