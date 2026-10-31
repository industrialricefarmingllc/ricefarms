#pragma once

// All tunables live under plugin:liquidglass:*. Flat keys on purpose —
// no themes, no presets, no inheritance. The Quickshell settings page
// pushes these via `hyprctl keyword` for live tuning.

#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <cstdint>
#include <string>

namespace lg {

inline constexpr const char* PREFIX = "plugin:liquidglass:";

void registerConfig(HANDLE handle);

// Provided by main.cpp. void* (not HANDLE: that macro resolves
// inconsistently across translation units).
void* pluginHandle();

float getFloat(const char* key, float fallback);
int   getInt(const char* key, int fallback);
std::string getString(const char* key, const char* fallback);

// Live-tuning generation: bumps whenever prefs.json or matugen.json changes
// (mtime-gated, two stats per call). Glass layers damage on generation
// change so slider/theme edits repaint without a self-damage-every-frame
// loop keeping the compositor awake.
uint64_t tuneGeneration();

// On-screen toast (also lands in hyprland.log). Used sparingly: load,
// first draw, compile failures. This plugin is otherwise silent, so a
// missing toast IS the diagnostic.
void notify(const std::string& text);

// Namespaces are matched by substring against the layer namespace
// (quickshell bar, dock and launcher all report "quickshell").
bool namespaceAllowed(const std::string& ns);

// Window classes are matched by substring against CWindow::m_class
// (same convention as namespaceAllowed; default "kitty").
bool windowAllowed(const std::string& cls);

// Rim-overdraw exclusion list (default "kitty,zen"): matched windows keep
// the under-glass but skip the second on-top rim.
bool overRimExcluded(const std::string& cls);

} // namespace lg
