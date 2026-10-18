#pragma once

#include <string>

// Note: Hyprland's HANDLE is a `void*` macro from PluginAPI.hpp; take void*
// here so this header doesn't depend on include order.
namespace goo {

namespace Key {
inline constexpr const char* ENABLED      = "plugin:gooworkspaces:enabled";
inline constexpr const char* DURATION_MS  = "plugin:gooworkspaces:duration_ms";
inline constexpr const char* SLIDE_RATIO  = "plugin:gooworkspaces:slide_ratio";
inline constexpr const char* STRETCH      = "plugin:gooworkspaces:stretch";
inline constexpr const char* SQUASH       = "plugin:gooworkspaces:squash";
inline constexpr const char* BLOB_SCALE   = "plugin:gooworkspaces:blob_scale";
inline constexpr const char* WOBBLE_AMP   = "plugin:gooworkspaces:wobble_amp";
inline constexpr const char* WOBBLE_FREQ  = "plugin:gooworkspaces:wobble_freq";
inline constexpr const char* DIRECTION    = "plugin:gooworkspaces:direction";
inline constexpr const char* VERTICAL     = "plugin:gooworkspaces:vertical";
inline constexpr const char* OUT_CURVE    = "plugin:gooworkspaces:out_curve";
inline constexpr const char* IN_CURVE     = "plugin:gooworkspaces:in_curve";
inline constexpr const char* STAGGER      = "plugin:gooworkspaces:stagger";
inline constexpr const char* DROPLET      = "plugin:gooworkspaces:droplet";
inline constexpr const char* COLLAPSE     = "plugin:gooworkspaces:collapse";
inline constexpr const char* GOO_STRENGTH = "plugin:gooworkspaces:goo_strength";
inline constexpr const char* GOO_SMEAR    = "plugin:gooworkspaces:goo_smear";
inline constexpr const char* GOO_WOBBLE   = "plugin:gooworkspaces:goo_wobble";
} // namespace Key

void        registerConfig(void* handle);
float       getFloat(const char* key, float fallback);
int         getInt(const char* key, int fallback);
std::string getString(const char* key, const char* fallback);
void*       pluginHandle();

} // namespace goo
