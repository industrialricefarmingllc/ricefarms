#pragma once

// 0.57 moved window bookkeeping off the flat CWindow fields. These helpers
// keep the port readable at the call sites.

#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>

#include <cstdint>

namespace lg {

inline bool winPinned(const PHLWINDOW& w) {
    return w && (static_cast<uint64_t>(w->m_state) & static_cast<uint64_t>(Desktop::View::WINDOW_STATE_PINNED));
}

} // namespace lg
