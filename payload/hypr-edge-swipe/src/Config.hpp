#pragma once

#include <string>

// Note: Hyprland's HANDLE is a `void*` macro from PluginAPI.hpp; take void*
// here so this header doesn't depend on include order. Same pattern as
// hypr-goo-workspaces/src/Config.hpp.
namespace es {

namespace Key {
// Workspace edge swipe.
inline constexpr const char* ENABLED        = "plugin:touch:enabled";
inline constexpr const char* ZONE_PX        = "plugin:touch:zone_px";
inline constexpr const char* ZONE_TOP_PX    = "plugin:touch:zone_top_px";
inline constexpr const char* SWIPE_ACTIVATION = "plugin:touch:swipe_activation_px";
inline constexpr const char* SWIPE_DISTANCE   = "plugin:touch:swipe_distance_px";
inline constexpr const char* MIN_DIST       = "plugin:touch:min_distance_px";
inline constexpr const char* DOMINANCE      = "plugin:touch:dominance";
inline constexpr const char* INVERT         = "plugin:touch:invert";
inline constexpr const char* VERTICAL_ENABLED = "plugin:touch:vertical_edges";
// Reverse edge swipe: start inside the screen, move toward an edge.
inline constexpr const char* REVERSE_ENABLED = "plugin:touch:reverse_enabled";
inline constexpr const char* REVERSE_ZONE    = "plugin:touch:reverse_zone_px";
inline constexpr const char* REVERSE_MIN     = "plugin:touch:reverse_min_px";
// Corner launcher gesture.
inline constexpr const char* CORNER_ENABLED = "plugin:touch:corner_enabled";
inline constexpr const char* CORNER_PX      = "plugin:touch:corner_px";
inline constexpr const char* CORNER_CLOSE_PX = "plugin:touch:corner_close_px";
inline constexpr const char* CORNER_MIN_PX  = "plugin:touch:corner_min_px";
// Two-finger pinch on a window.
inline constexpr const char* PINCH_ENABLED  = "plugin:touch:pinch_enabled";
inline constexpr const char* PINCH_LIVE     = "plugin:touch:pinch_live";
inline constexpr const char* PINCH_RATIO    = "plugin:touch:pinch_ratio";
inline constexpr const char* PINCH_MIN_DIST = "plugin:touch:pinch_min_distance_px";
inline constexpr const char* PINCH_TIMEOUT  = "plugin:touch:pinch_timeout_ms";
// One-finger window drag (armed by a double tap).
inline constexpr const char* DRAG_ENABLED   = "plugin:touch:drag_enabled";
inline constexpr const char* DRAG_THRESHOLD = "plugin:touch:drag_threshold_px";
inline constexpr const char* DRAG_DOUBLE_TAP_MS = "plugin:touch:drag_double_tap_ms";
inline constexpr const char* DRAG_DOUBLE_TAP_PX = "plugin:touch:drag_double_tap_px";
inline constexpr const char* DRAG_COOLDOWN_MS = "plugin:touch:drag_cooldown_ms";
} // namespace Key

void        registerConfig(void* handle);
float       getFloat(const char* key, float fallback);
int         getInt(const char* key, int fallback);
std::string getString(const char* key, const char* fallback);

} // namespace es
