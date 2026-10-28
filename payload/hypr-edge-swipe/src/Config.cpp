#include "Config.hpp"

#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/config/values/ConfigValues.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>

#include <memory>
#include <unordered_map>

namespace es {

template <typename T, typename V>
static void add(HANDLE handle, const char* name, V def) {
    HyprlandAPI::addConfigValueV2(handle, Config::Values::makeConfigValue<T>(name, "", def, Config::Values::valueOptions_t<T>{}));
}

void registerConfig(HANDLE handle) {
    using namespace Config;
    // Master switch.
    add<Values::Int>(handle, Key::ENABLED, INTEGER{1});
    // Start band width in logical px from the left/right screen edge. This is
    // the "padding to ease errors": the swipe may start anywhere inside this
    // band, not only exactly on the bezel.
    add<Values::Int>(handle, Key::ZONE_PX, INTEGER{56});
    // Ignore swipes that start within this many px of the top edge (0 = off).
    // Bump above your bar height if edge swipes near the bar feel wrong.
    add<Values::Int>(handle, Key::ZONE_TOP_PX, INTEGER{0});
    // Travel before the workspace starts following the finger. Large enough
    // that taps/jitter on the top bar are not stolen from the shell, but
    // still well under the commit distance.
    add<Values::Int>(handle, Key::SWIPE_ACTIVATION, INTEGER{12});
    // Finger travel (logical px) that slides a full screen of workspace.
    // The native 300 px full-screen travel feels ~3x too fast for a direct
    // drag; 900 keeps a full-screen slide within a comfortable thumb travel.
    add<Values::Int>(handle, Key::SWIPE_DISTANCE, INTEGER{900});
    // Inward travel required to commit on release, logical px. This is a
    // short flick: the workspace still follows the finger beyond it, but a
    // release after ~20 px switches instead of feeling stuck for half a screen.
    add<Values::Int>(handle, Key::MIN_DIST, INTEGER{20});
    // How much stronger the inward travel must be than the perpendicular
    // (1.2 = clearly sideways/vertical swipes only; 1.0 = any diagonal).
    add<Values::Float>(handle, Key::DOMINANCE, FLOAT{1.2});
    // Swap sides: left edge -> next workspace, right edge -> previous.
    add<Values::Int>(handle, Key::INVERT, INTEGER{0});
    // Enable top/bottom edge swipes (up/down in the workspace grid).
    add<Values::Int>(handle, Key::VERTICAL_ENABLED, INTEGER{1});
    // Reverse edge swipe: start just outside the normal edge band and move
    // toward that edge. Keeping the start near the edge (like the normal
    // band) prevents ordinary swipes in the middle of the screen from
    // navigating. 0 would remove the distance limit.
    add<Values::Int>(handle, Key::REVERSE_ENABLED, INTEGER{1});
    add<Values::Int>(handle, Key::REVERSE_ZONE, INTEGER{120});
    // Movement toward the edge before the reverse preview starts, logical px.
    add<Values::Int>(handle, Key::REVERSE_MIN, INTEGER{24});
    // Corner launcher: a diagonal inward swipe opens the Pibble launcher.
    add<Values::Int>(handle, Key::CORNER_ENABLED, INTEGER{1});
    // Both the start's x and y must be within this many px of the corner.
    add<Values::Int>(handle, Key::CORNER_PX, INTEGER{48});
    // The close direction (toward the top-left) gets a wider start area once
    // the launcher is open, so it is easy to grab from a little farther in.
    add<Values::Int>(handle, Key::CORNER_CLOSE_PX, INTEGER{120});
    // Both dx and dy must reach this many px before it fires.
    add<Values::Int>(handle, Key::CORNER_MIN_PX, INTEGER{24});

    // Pinch on a window: out = maximize, then fullscreen; in = step back.
    add<Values::Int>(handle, Key::PINCH_ENABLED, INTEGER{1});
    // Resize the window live while the fingers move (floats a tiled window
    // for the duration). 0 = only apply the discrete maximize/contract step.
    add<Values::Int>(handle, Key::PINCH_LIVE, INTEGER{1});
    // Finger distance must grow/shrink by this factor to commit. 1.25 means
    // +25% (out) or -20% (in); raise it if two-finger scrolling triggers.
    add<Values::Float>(handle, Key::PINCH_RATIO, FLOAT{1.25});
    // Minimum initial distance between the two fingers, logical px.
    add<Values::Int>(handle, Key::PINCH_MIN_DIST, INTEGER{40});
    // Both fingers must land within this window, ms.
    add<Values::Int>(handle, Key::PINCH_TIMEOUT, INTEGER{400});

    // Touch drag on a window body moves it (floats a tiled window first).
    // It is armed by a double tap so a normal single-finger drag/scroll is
    // left entirely to the app.
    add<Values::Int>(handle, Key::DRAG_ENABLED, INTEGER{1});
    // Pixels the finger must travel before the drag takes over from the app.
    add<Values::Int>(handle, Key::DRAG_THRESHOLD, INTEGER{24});
    // Maximum time from the first tap-down to the second tap-down, ms. A
    // tap itself must still be shorter than 300 ms.
    add<Values::Int>(handle, Key::DRAG_DOUBLE_TAP_MS, INTEGER{150});
    // Maximum distance between the two taps, logical px.
    add<Values::Int>(handle, Key::DRAG_DOUBLE_TAP_PX, INTEGER{40});
    // After a vertical one-finger swipe (scrolling), ignore drag arming for
    // this long so the next quick tap/swipe keeps scrolling the page.
    add<Values::Int>(handle, Key::DRAG_COOLDOWN_MS, INTEGER{300});
}

// CConfigValue binds to the live value object and is re-populated by the
// compositor on config reloads. With the Lua config manager, a raw
// getConfigValue() reply does not follow runtime hl.config() overrides --
// the plugin would only ever see the registered defaults.
template <typename T>
static T readCached(const char* key, T fallback) {
    static std::unordered_map<std::string, std::unique_ptr<CConfigValue<T>>> cache;

    auto& slot = cache[key];
    if (!slot)
        slot = std::make_unique<CConfigValue<T>>(key);

    if (!slot->good())
        return fallback;

    return **slot;
}

float getFloat(const char* key, float fallback) {
    try {
        return readCached<Config::FLOAT>(key, fallback);
    } catch (...) { return fallback; }
}

int getInt(const char* key, int fallback) {
    try {
        return (int)readCached<Config::INTEGER>(key, (Config::INTEGER)fallback);
    } catch (...) { return fallback; }
}

std::string getString(const char* key, const char* fallback) {
    try {
        const auto v = Config::mgr()->getConfigValue(key);
        if (!v.dataptr)
            return std::string(fallback);
        const char* s = **reinterpret_cast<Hyprlang::STRING* const*>(v.dataptr);
        return s ? std::string(s) : std::string(fallback);
    } catch (...) { return std::string(fallback); }
}

} // namespace es
