#pragma once

// Cursor-following rim angle. The rim light is defined by one diagonal
// (rim_angle); this helper slowly steers that diagonal toward the cursor,
// horizontally mirrored, by a small gain and a bounded deviation. All angles
// are in the shader's convention: Lxy = (cos(a), -sin(a)), a = 135 means
// light from the top-left in monitor-local framebuffer coordinates.

#include <chrono>
#include <cmath>
#include <limits>

#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprutils/math/Box.hpp>
#include <hyprutils/math/Vector2D.hpp>

namespace lg {

struct SRimFollowState {
    float angle = std::numeric_limits<float>::quiet_NaN();
    std::chrono::steady_clock::time_point last{};
    bool init = false;
};

// Cursor in this monitor's local framebuffer px (global logical cursor
// converted with the monitor's position and scale; works across outputs).
Vector2D cursorLocal(PHLMONITOR monitor);

// fbBox is monitor-local framebuffer px. baseAngle is the configured
// rim_angle. state persists per surface/pill/window. Returns the smoothed
// angle to upload as uRimAngle.
float rimAngleFor(const CBox& fbBox, const Vector2D& cursorLocal, float baseAngle, SRimFollowState& state);

} // namespace lg
