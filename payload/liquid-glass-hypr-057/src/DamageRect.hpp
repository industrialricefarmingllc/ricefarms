#pragma once

// One scissored draw per damage RECT, never one per damage EXTENTS.
//
// Hyprland repaints the frame only inside the damage region, but every glass
// quad is larger than its visible shape: it carries a translucent drop-shadow
// margin (and a 1px AA edge). Clipping such a quad to the *extents* of the
// damage region blends the halo over pixels the frame never repainted, so
// every repaint darkens them a little more. On screen that reads as
// hard-edged shadow squares: bands inside a neighbouring pane, patches under
// a layer pill that sits in front of a window, and squares along the cursor
// trail. Upstream subdivides damage into pixman rects for the same reason
// (see CHyprOpenGLImpl::renderRoundedShadow), so do the subdivision here.

#include <hyprland/src/render/Context.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprutils/math/Box.hpp>

#include <GLES3/gl32.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <utility>

namespace lg {

// True when this frame's damage fully covers the given fb-px rect (1px inset
// by the caller to absorb damage rounding).
//
// Hyprland repaints only inside the damage region; everything else in the
// framebuffer is still the PREVIOUS frame. For a glass surface that region
// holds the old glass plus the old text, so capturing it bakes a ghost of the
// text under the new text: an oversharpened-looking halo, and fragments where
// only part of the surface was damaged. Captures must therefore never sample
// a partially-repainted rect.
inline bool damageCovers(Render::CRenderContext& ctx, int x0, int y0, int x1, int y1) {
    const int64_t area = (int64_t)(x1 - x0) * (int64_t)(y1 - y0);
    if (area <= 0)
        return true;
    if (ctx.m_data.damage.empty())
        return false;
    int64_t covered = 0;
    ctx.m_data.damage.forEachRect([&](const pixman_box32_t& RECT) {
        const int cx0 = std::max(x0, (int)RECT.x1);
        const int cy0 = std::max(y0, (int)RECT.y1);
        const int cx1 = std::min(x1, (int)RECT.x2);
        const int cy1 = std::min(y1, (int)RECT.y2);
        if (cx1 > cx0 && cy1 > cy0)
            covered += (int64_t)(cx1 - cx0) * (int64_t)(cy1 - cy0);
    });
    // pixman rects are disjoint, so the sum is the covered area.
    return covered >= area;
}

// Calls draw() once per damage rect clipped to `quad` (fb px). With no
// damage it draws once, unclipped, like the old `else` branch.
template <typename Fn>
inline void drawPerDamageRect(Render::CRenderContext& ctx, const CBox& quad, Fn&& draw) {
    if (ctx.m_data.damage.empty()) {
        draw();
        return;
    }

    const int qx0 = (int)std::floor(quad.x);
    const int qy0 = (int)std::floor(quad.y);
    const int qx1 = (int)std::ceil(quad.x + quad.w);
    const int qy1 = (int)std::ceil(quad.y + quad.h);

    ctx.m_data.damage.forEachRect([&](const pixman_box32_t& RECT) {
        const int cx0 = std::max(qx0, (int)RECT.x1);
        const int cy0 = std::max(qy0, (int)RECT.y1);
        const int cx1 = std::min(qx1, (int)RECT.x2);
        const int cy1 = std::min(qy1, (int)RECT.y2);
        if (cx1 <= cx0 || cy1 <= cy0)
            return;
        const pixman_box32_t clip{(int32_t)cx0, (int32_t)cy0, (int32_t)cx1, (int32_t)cy1};
        Render::GL::g_pHyprOpenGL->scissor(ctx, &clip, ctx.m_data.transformDamage);
        draw();
    });
    Render::GL::g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);
}

} // namespace lg
