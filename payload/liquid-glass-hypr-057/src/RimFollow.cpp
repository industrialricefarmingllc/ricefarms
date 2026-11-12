#include "RimFollow.hpp"
#include "Config.hpp"

#include <hyprland/src/managers/input/InputManager.hpp>

#include <algorithm>

namespace {

constexpr float PI_F = 3.14159265358979323846f;

// Keep the full 360° orientation: the two opposite lights make +a and +a+180
// visually the same pair, but preserving the sign of small offsets is what
// lets vertical pointer movement tilt the diagonal instead of folding onto
// the same undirected line.
float wrap360(float a) {
    while (a > 180.0f)
        a -= 360.0f;
    while (a <= -180.0f)
        a += 360.0f;
    return a;
}

float shortest360(float from, float to) {
    return wrap360(to - from);
}

float smoothstep01(float x) {
    x = std::clamp(x, 0.0f, 1.0f);
    return x * x * (3.0f - 2.0f * x);
}

} // namespace

namespace lg {

Vector2D cursorLocal(PHLMONITOR monitor) {
    if (!monitor || !g_pInputManager)
        return Vector2D{NAN, NAN};
    const Vector2D global = g_pInputManager->getMouseCoordsInternal();
    const float scale = monitor->m_scale > 0.001f ? monitor->m_scale : 1.0f;
    return Vector2D{(global.x - monitor->m_position.x) * scale, (global.y - monitor->m_position.y) * scale};
}

float rimAngleFor(const CBox& fbBox, const Vector2D& cursor, float baseAngle, SRimFollowState& state) {
    const float base = wrap360(baseAngle);

    if (!getInt("plugin:liquidglass:rim_follow", 1) || fbBox.w <= 0.0 || fbBox.h <= 0.0
        || !std::isfinite(cursor.x) || !std::isfinite(cursor.y)) {
        state.init = false;
        return base;
    }

    const auto now = std::chrono::steady_clock::now();
    float dt = state.init ? std::chrono::duration<float>(now - state.last).count() : 0.0f;
    state.last = now;
    // Cap the step after an idle gap: a short filter should not snap in one
    // frame when the compositor resumes drawing the surface.
    dt = std::clamp(dt, 0.0f, 0.10f);

    if (!state.init) {
        state.angle = base;
        state.init = true;
    }

    const float cx = fbBox.x + fbBox.w * 0.5f;
    const float cy = fbBox.y + fbBox.h * 0.5f;
    float dx = cursor.x - cx;
    const float dy = cursor.y - cy;
    // Horizontal mirror only. dy stays signed, so moving up and moving down
    // rotate the diagonal in opposite directions instead of collapsing to the
    // same undirected line.
    dx = -dx;

    const float dist = std::sqrt(dx * dx + dy * dy);
    const float dead = std::max(6.0f, (float)std::max(fbBox.w, fbBox.h) * 0.08f);
    // Near the centre the cursor direction is undefined/noisy; fade the
    // effect in so a tiny pointer movement cannot swing the rim.
    const float fade = smoothstep01((dist - dead) / std::max(dead, 1.0f));

    const float baseRad = base * PI_F / 180.0f;
    const float baseX = std::cos(baseRad);
    const float baseY = -std::sin(baseRad); // shader convention: +y is down
    // Signed angle of the cursor direction relative to the base direction.
    // Using the oriented cross/dot (not atan2 modulo 180) preserves vertical
    // sign: pointer above the base direction goes one way, below goes the
    // other.
    const float rel = std::atan2(baseX * dy - baseY * dx, baseX * dx + baseY * dy) * 180.0f / PI_F;
    const float gain = std::clamp(getFloat("plugin:liquidglass:rim_follow_strength", 0.2f), 0.0f, 1.0f);
    const float maxDev = std::clamp(getFloat("plugin:liquidglass:rim_follow_max", 15.0f), 0.0f, 45.0f);
    const float target = base + std::clamp(rel * gain * fade, -maxDev, maxDev);

    const float tau = std::max(getFloat("plugin:liquidglass:rim_follow_smoothing", 0.3f), 0.05f);
    const float alpha = 1.0f - std::exp(-dt / tau);
    state.angle = wrap360(state.angle + shortest360(state.angle, target) * alpha);
    return state.angle;
}

} // namespace lg
