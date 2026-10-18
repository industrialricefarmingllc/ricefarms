#include "Config.hpp"

#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/config/values/ConfigValues.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>

namespace goo {

static HANDLE PHANDLE_CFG = nullptr;

void* pluginHandle() {
    return PHANDLE_CFG;
}

template <typename T, typename V>
static void add(HANDLE handle, const char* name, V def) {
    HyprlandAPI::addConfigValueV2(handle, Config::Values::makeConfigValue<T>(name, "", def, Config::Values::valueOptions_t<T>{}));
}

void registerConfig(HANDLE handle) {
    PHANDLE_CFG = handle;
    using namespace Config;
    // Master switch.
    add<Values::Int>(handle, Key::ENABLED, INTEGER{1});
    // Transition length. 450-650ms reads "liquid"; shorter reads "snappy".
    add<Values::Float>(handle, Key::DURATION_MS, FLOAT{550.0});
    // Slide distance as a fraction of monitor width (0.35 = windows travel
    // ~1/3 of the screen while morphing). Outgoing slides toward the entry
    // side; incoming travels in from the entry side.
    add<Values::Float>(handle, Key::SLIDE_RATIO, FLOAT{0.35});
    // Goo stretch: peak horizontal elongate of outgoing windows (0.25 = +25%
    // wide at mid-transition, paired with vertical squash below). This is
    // the "morph towards the incoming side" from the brief.
    add<Values::Float>(handle, Key::STRETCH, FLOAT{0.28});
    // Vertical squash paired with the stretch (volume-preservation fake).
    add<Values::Float>(handle, Key::SQUASH, FLOAT{0.18});
    // Incoming windows start at this scale (liquid blob) and grow to 1.0
    // with overshoot. Lower = more liquid.
    add<Values::Float>(handle, Key::BLOB_SCALE, FLOAT{0.42});
    // Damped-sine wobble amplitude on the incoming grow (blob-switch wobble).
    // 0 disables; ~0.06 is visible but tasteful.
    add<Values::Float>(handle, Key::WOBBLE_AMP, FLOAT{0.06});
    // Wobble oscillations per transition (1.5 = one and a half wobbles).
    add<Values::Float>(handle, Key::WOBBLE_FREQ, FLOAT{1.5});
    // Direction policy: "auto" (new id > old id => new enters from right),
    // "forward" (always from right), "backward" (always from left).
    add<Values::String>(handle, Key::DIRECTION, STRING{"auto"});
    // 0 = horizontal slide (default), 1 = vertical (new enters from bottom
    // when moving forward). Pairs with direction the same way.
    add<Values::Int>(handle, Key::VERTICAL, INTEGER{0});
    // Easing names: "expo" | "back" | "linear". Outgoing uses ease-in-ish,
    // incoming ease-out (with overshoot on "back").
    add<Values::String>(handle, Key::OUT_CURVE, STRING{"expo"});
    add<Values::String>(handle, Key::IN_CURVE, STRING{"back"});
    // Cascade: fraction of the duration reserved for the per-window stagger.
    // Windows near the entry edge start first, far ones catch up — 0 = off.
    add<Values::Float>(handle, Key::STAGGER, FLOAT{0.25});
    // Droplet rounding: peak extra corner rounding (logical px) applied to
    // participating windows mid-transition. 0 = off.
    add<Values::Float>(handle, Key::DROPLET, FLOAT{28.0});
    // Outgoing end scale: windows collapse toward a point on the entry side,
    // shrinking to this fraction (liquid-into-the-new-selection).
    add<Values::Float>(handle, Key::COLLAPSE, FLOAT{0.32});
    // Screen-space goo (fullscreen directional smear queued after windows,
    // under the top layers): peak mix 0..1. 0 = pass off (zero cost).
    add<Values::Float>(handle, Key::GOO_STRENGTH, FLOAT{0.4});
    // Max smear spread along the motion axis, logical px (x monitor scale).
    add<Values::Float>(handle, Key::GOO_SMEAR, FLOAT{20.0});
    // Perpendicular UV wobble amplitude, logical px. 0 = off.
    add<Values::Float>(handle, Key::GOO_WOBBLE, FLOAT{6.0});
}

float getFloat(const char* key, float fallback) {
    try {
        const auto v = Config::mgr()->getConfigValue(key);
        return (float)**reinterpret_cast<Hyprlang::FLOAT* const*>(v.dataptr);
    } catch (...) { return fallback; }
}

int getInt(const char* key, int fallback) {
    try {
        const auto v = Config::mgr()->getConfigValue(key);
        return (int)**reinterpret_cast<Hyprlang::INT* const*>(v.dataptr);
    } catch (...) { return fallback; }
}

std::string getString(const char* key, const char* fallback) {
    try {
        const auto v = Config::mgr()->getConfigValue(key);
        const char* s = **reinterpret_cast<Hyprlang::STRING* const*>(v.dataptr);
        return s ? std::string(s) : std::string(fallback);
    } catch (...) { return std::string(fallback); }
}

} // namespace goo
