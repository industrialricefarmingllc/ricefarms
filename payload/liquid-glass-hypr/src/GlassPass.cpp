#include "RenderCtx.hpp"
#include "GlassPass.hpp"

#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/render/Renderer.hpp>

CGlassPassElement::CGlassPassElement(const SData& data) : m_data(data) {}

std::vector<UP<IPassElement>> CGlassPassElement::draw(Render::CRenderContext& ctx) {
    lg::SRenderCtxScope scope(ctx);
    if (m_data.layer && m_data.layer->get())
        m_data.layer->render(LG_RENDER_DATA.pMonitor.lock());
    return {};
}

std::optional<CBox> CGlassPassElement::boundingBox(Render::CRenderContext& ctx) {
    lg::SRenderCtxScope scope(ctx);
    // Narrow to last frame's pill union (+shadow pad) so damage-culling can
    // skip idle frames. Fullscreen until the first render (cold start), then
    // tight. One frame of lag on morphs is covered by the padding.
    if (m_data.layer) {
        if (auto b = m_data.layer->glassBounds())
            return b;
    }
    const auto monitor = LG_RENDER_DATA.pMonitor.lock();
    if (!monitor)
        return std::nullopt;
    const float scale = monitor->m_scale > 0.0f ? monitor->m_scale : 1.0f;
    CBox box{0.0, 0.0, (double)((int)(monitor->m_transformedSize.x / scale)), (double)((int)(monitor->m_transformedSize.y / scale))};
    return box;
}

bool CGlassPassElement::needsLiveBlur(Render::CRenderContext& ctx) {
    // False: we run our own blur pyramid from the current framebuffer and
    // never sample the compositor's blur framebuffer. True would inflate
    // every frame's damage by the compositor blur radius and veto occlusion
    // inside our bounds for nothing.
    return false;
}

bool CGlassPassElement::needsPrecomputeBlur(Render::CRenderContext& ctx) {
    return false;
}

bool CGlassPassElement::disableSimplification(Render::CRenderContext& ctx) {
    // False: with a tight boundingBox() and undiscardable(), the pass can
    // cull and discard normally. True vetoed all occlusion culling
    // process-wide whenever any glass surface was mapped.
    return false;
}
