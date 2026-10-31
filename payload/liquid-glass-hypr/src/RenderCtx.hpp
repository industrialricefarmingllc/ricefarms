#pragma once

// Hyprland 0.57 moved the per-frame render state off IHyprRenderer and onto
// Render::CRenderContext. Hooks and pass elements receive that context as an
// argument, but the glass code reaches frame state (damage, current FB,
// renderModif, monitor) from deep helper functions that never took it.
//
// Instead of threading a reference through every helper, each hook/pass entry
// point installs the context for the duration of its call (RAII, so nested
// renders — snapshots, popups, decorations — restore the outer one on exit).
// Compositor rendering is single-threaded, so one pointer is enough.

#include <hyprland/src/render/Context.hpp>

namespace lg {

inline Render::CRenderContext* g_renderCtx = nullptr;

inline Render::CRenderContext& rctx() {
    return *g_renderCtx;
}

struct SRenderCtxScope {
    Render::CRenderContext* prev;

    explicit SRenderCtxScope(Render::CRenderContext& ctx) : prev(g_renderCtx) {
        g_renderCtx = &ctx;
    }

    ~SRenderCtxScope() {
        g_renderCtx = prev;
    }

    SRenderCtxScope(const SRenderCtxScope&)            = delete;
    SRenderCtxScope& operator=(const SRenderCtxScope&) = delete;
};

} // namespace lg

// The state that used to live on g_pHyprRenderer. Every call site below is
// inside a SRenderCtxScope, so these are the current frame's values.
#define LG_RENDER_DATA (::lg::rctx().m_data)
#define LG_SNAPSHOT (::lg::rctx().m_renderingSnapshot)
#define LG_PASS (::lg::rctx().m_pass)
