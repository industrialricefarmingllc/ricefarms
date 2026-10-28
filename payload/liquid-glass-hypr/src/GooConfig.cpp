#include "GooConfig.hpp"

#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/config/values/ConfigValues.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>

namespace goo {

template <typename T, typename V>
static void add(void* handle, const char* name, V def) {
    HyprlandAPI::addConfigValueV2(handle, Config::Values::makeConfigValue<T>(name, "", def, Config::Values::valueOptions_t<T>{}));
}

void registerConfig(void* handle) {
    using namespace Config;
    // Master switch. Ships OFF: enable live via
    // hyprctl eval "hl.config({plugin={gooworkspaces={enabled=1}}})".
    add<Values::Int>(handle, Key::ENABLED, INTEGER{0});
    // Transition length. Calm default; raise toward 600 for more liquid.
    add<Values::Float>(handle, Key::DURATION_MS, FLOAT{600.0});
    // Slide distance as a fraction of monitor width. Outgoing slides toward
    // the entry side; incoming travels in from the entry side.
    add<Values::Float>(handle, Key::SLIDE_RATIO, FLOAT{0.18});
    // Goo stretch: peak elongation of outgoing windows along the motion axis,
    // paired with squash below.
    add<Values::Float>(handle, Key::STRETCH, FLOAT{0.10});
    // Vertical squash paired with the stretch (volume-preservation fake).
    add<Values::Float>(handle, Key::SQUASH, FLOAT{0.06});
    // Incoming windows start at this scale (liquid blob) and grow to 1.0
    // with overshoot. Lower = more liquid.
    add<Values::Float>(handle, Key::BLOB_SCALE, FLOAT{0.60});
    // Damped-sine wobble amplitude on the incoming grow (blob-switch wobble).
    // 0 disables.
    add<Values::Float>(handle, Key::WOBBLE_AMP, FLOAT{0.02});
    // Wobble oscillations per transition (1.5 = one and a half wobbles).
    add<Values::Float>(handle, Key::WOBBLE_FREQ, FLOAT{1.5});
    // Direction policy: "auto" (new id > old id => new enters from right),
    // "forward" (always from right), "backward" (always from left).
    add<Values::String>(handle, Key::DIRECTION, STRING{"auto"});
    // 0 = horizontal slide (default), 1 = vertical (new enters from bottom
    // when moving forward). Pairs with direction the same way.
    add<Values::Int>(handle, Key::VERTICAL, INTEGER{0});
    // Easing names: outgoing "expo" | "back" | "linear" (ease-in-ish);
    // incoming "spring" (default: true underdamped spring on wall-clock time,
    // slight soft bounce) | "back" (legacy overshoot) | "expo" | "linear".
    add<Values::String>(handle, Key::OUT_CURVE, STRING{"expo"});
    add<Values::String>(handle, Key::IN_CURVE, STRING{"spring"});
    // Outgoing end alpha: windows dim 1.0 -> this, never fully fading.
    // Default 0.33 (slight fade); 1.0 disables the dim.
    add<Values::Float>(handle, Key::FADE_OUT_MIN, FLOAT{0.33});
    // Spring for in_curve="spring" (mass = 1): higher stiffness = faster,
    // higher damping = less bounce, velocity = initial toss toward the goal
    // (fast Material-style lead; 0 = classic release with a dead slow start).
    // Defaults (~9% overshoot, settled inside the transition, zeta ~0.62:
    // soft, not stiff) track easeOutBack closely by design.
    add<Values::Float>(handle, Key::SPRING_STIFF, FLOAT{110.0});
    add<Values::Float>(handle, Key::SPRING_DAMP, FLOAT{13.0});
    add<Values::Float>(handle, Key::SPRING_VEL, FLOAT{4.0});
    // Legacy: start-delay stagger (fraction of duration). Unused since the
    // duration-spread redesign (all windows start together); kept registered
    // so old configs never error on unknown keys.
    add<Values::Float>(handle, Key::STAGGER, FLOAT{0.10});
    // Per-window DURATION spread (absolute ms): window i animates over
    // DURATION_MS + spread*r_i (r_i in [0,1] from rank+hash), so all start
    // together but each grows at its own pace across a `spread` range.
    // The transition itself runs DURATION_MS + spread (slowest completes).
    add<Values::Float>(handle, Key::DUR_SPREAD, FLOAT{500.0});
    // Droplet rounding: peak extra corner rounding (logical px) applied to
    // participating windows mid-transition. 0 = off (sharp edges connect
    // the funnels seamlessly; rounding would fringe the seam).
    add<Values::Float>(handle, Key::DROPLET, FLOAT{0.0});
    // Outgoing end scale: windows collapse toward a point on the entry side,
    // shrinking to this fraction (liquid-into-the-new-selection).
    add<Values::Float>(handle, Key::COLLAPSE, FLOAT{0.40});
    // Screen-space goo (fullscreen directional smear queued after windows,
    // under the top layers): peak mix 0..1. 0 = pass off (zero cost).
    // Default OFF: the smear rewrote pixels outside the damage contract and
    // left wave/ghost trails; geometry morph carries the effect alone.
    add<Values::Float>(handle, Key::GOO_STRENGTH, FLOAT{0.0});
    // Max smear spread along the motion axis, logical px (x monitor scale).
    add<Values::Float>(handle, Key::GOO_SMEAR, FLOAT{20.0});
    // Perpendicular UV wobble amplitude, logical px. 0 = off.
    add<Values::Float>(handle, Key::GOO_WOBBLE, FLOAT{6.0});
    // Droplet tip: the outgoing window's leading edge is pulled into a point
    // aimed at the screen edge (CodePen droplet). 0 = off.
    add<Values::Int>(handle, Key::TIP_ENABLE, INTEGER{0});
    // Tip silhouette: profile pow on sin(pi*v); >1 narrows the tip (concave
    // flanks), <1 fattens it.
    add<Values::Float>(handle, Key::TIP_CURVE, FLOAT{1.5});
    // Tip reach cap, logical px. Default effectively uncapped so the funnel
    // apex always sits on the screen edge; lower it to shorten the filament.
    add<Values::Float>(handle, Key::TIP_MAX, FLOAT{4000.0});
    // Genie suck: migrate the scale anchor toward the edge-center point so
    // the window converges into it (outgoing) / emerges from it (incoming).
    // 0 = plain slide+scale.
    add<Values::Float>(handle, Key::GENIE_PULL, FLOAT{1.0});
    // Non-uniform liquid deformation applied while a window is manually or
    // tiling-manager resized (the workspace morph's stretch, for resize).
    add<Values::Float>(handle, Key::RESIZE_STRETCH, FLOAT{0.10});
}

float getFloat(const char* key, float fallback) {
    try {
        const auto v = Config::mgr()->getConfigValue(key);
        if (!v.dataptr)
            return fallback; // unregistered key: no value store (SEGVs if deref'd)
        return (float)**reinterpret_cast<Hyprlang::FLOAT* const*>(v.dataptr);
    } catch (...) { return fallback; }
}

int getInt(const char* key, int fallback) {
    try {
        const auto v = Config::mgr()->getConfigValue(key);
        if (!v.dataptr)
            return fallback; // unregistered key: no value store (SEGVs if deref'd)
        return (int)**reinterpret_cast<Hyprlang::INT* const*>(v.dataptr);
    } catch (...) { return fallback; }
}

std::string getString(const char* key, const char* fallback) {
    try {
        const auto v = Config::mgr()->getConfigValue(key);
        if (!v.dataptr)
            return std::string(fallback); // unregistered key: no value store (SEGVs if deref'd)
        const char* s = **reinterpret_cast<Hyprlang::STRING* const*>(v.dataptr);
        return s ? std::string(s) : std::string(fallback);
    } catch (...) { return std::string(fallback); }
}

} // namespace goo
