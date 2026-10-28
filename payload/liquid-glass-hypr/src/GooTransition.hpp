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
// v2 drives per-window alpha too: outgoing windows ease 1.0 -> fade_out_min
// (default 0.33) on the upstream WINDOW_ALPHA_MOVE_FROM_WORKSPACE channel,
// incoming windows grow blob_scale -> 1.0 on a true underdamped spring
// (springStep, in_curve="spring"). True metaball fusion (screen-space
// blur/threshold pass) is reserved for v3 — see shaders/goo.frag.

#include <hyprland/src/SharedDefs.hpp>
#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/macros.hpp>

#include <chrono>
#include <cstdint>
#include <optional>
#include <unordered_map>
#include <vector>

namespace goo {

enum class Role { NONE, OUTGOING, INCOMING };

struct Transform {
    Vector2D offset      = {0, 0}; // logical px, added to window position
    Vector2D anchorShift = {0, 0}; // logical px, moves the scale anchor (collapse point)
    double   scaleX      = 1.0;
    double   scaleY      = 1.0;
    double   alpha       = 1.0; // window alpha multiplier for this frame
};

struct Transition {
    MONITORID   monitor   = MONITOR_INVALID;
    WORKSPACEID oldId     = WORKSPACE_INVALID;
    WORKSPACEID newId     = WORKSPACE_INVALID;
    int         side      = 1; // +1: new enters from right/bottom, -1: left/top
    bool        vertical  = false; // motion axis (false = x, true = y)
    std::chrono::steady_clock::time_point t0;
    PHLWORKSPACEREF oldWs; // held so m_forceRendering can be cleared at end
    PHLWORKSPACEREF newWs; // held for pointer-identity role matching
    PHLMONITORREF   mon;   // held so the tick handler can damage the monitor
    bool            finished = false;
    // Endpoint-frame grace: at t>=1 we still draw one frame at exactly 1.0
    // before releasing the warp; otherwise the last painted frame is a few
    // percent short and the restore snaps to full size = the visible jump.
    bool            atEnd   = false;
    std::chrono::steady_clock::time_point endAt{};
};

class TransitionManager {
  public:
    void  begin(MONITORID mon, WORKSPACEID oldId, WORKSPACEID newId, int side, bool vertical, PHLWORKSPACE oldWs, PHLWORKSPACE newWs,
                PHLMONITOR monPtr);
    void  finish(MONITORID mon); // clears force-render flag, damages clean, drops state
    bool  active(MONITORID mon) const;

    // 0..1 progress for the monitor's transition; nullopt when none.
    // Marks finished (but does NOT clear flags — call finish()).
    std::optional<double> progress(MONITORID mon, double durationMs);

    const Transition* get(MONITORID mon) const;
    // Live (unfinished) transitions with a valid monitor, for the sustain
    // timer: damage + expiry without depending on rendered frames.
    std::vector<std::pair<MONITORID, PHLMONITOR>> liveMonitors() const;

    // Role by workspace ID, with pointer-identity fast path: windowWsPtr is
    // window->m_workspace (may be null). Pointer match is exact; ID compare
    // is the fallback.
    Role roleFor(MONITORID mon, WORKSPACEID windowWs, PHLWORKSPACE windowWsPtr) const;

    // Full morph for one window. monitorLen = monitor width (or height in
    // vertical mode) in logical px, used to scale slide_ratio. side is the
    // transition's entry side (+1: new enters from right/bottom).
    Transform transformFor(Role role, double t, double monitorLen, int side, bool vertical) const;

  private:
    std::unordered_map<MONITORID, Transition> m_transitions;
};

// Genie target: the center of the monitor edge on the entry side, global
// logical px. Outgoing bodies drift here and tips converge here.
Vector2D edgeCenterPoint(Vector2D monPos, Vector2D monSize, int side, bool vertical);

// Easing primitives (also unit-testable in isolation).
double easeLinear(double t);
double easeInExpo(double t);
double easeOutExpo(double t);
double easeInBack(double t);
double easeOutBack(double t);
// Closed-form step response of a damped harmonic oscillator (mass = 1) with
// initial velocity v0 (a "tossed" spring: fast Material-style lead instead of
// the dead slow start of a zero-velocity release). 0 at t<=0, overshoots past
// 1 when underdamped (zeta < 1), settles to 1. zeta >= 1 falls back to a
// bounce-free critically-damped response.
double springStep(double tSeconds, double stiffness, double damping, double velocity);

// Per-window duration spread: maps global progress t (over the FULL
// transition length DURATION_MS + spread) to a per-window local progress.
// Window i traverses 0..1 over its own DURATION_MS + spread*r_i, where r_i
// mixes participant rank (even coverage: any window count spans the whole
// range) with a small hash wobble (organic). All windows START together;
// each grows at its own pace. Clamped 0..1. Stable within a transition.
double jitteredT(double t, double rank01, const void* windowKey, long long oldId, long long newId);

} // namespace goo
