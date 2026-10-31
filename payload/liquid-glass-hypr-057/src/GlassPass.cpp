#include "GlassPass.hpp"

#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/render/Context.hpp>
#include <hyprland/src/render/Renderer.hpp>

CGlassPassElement::CGlassPassElement(const SData& data) : m_data(data) {}

std::vector<UP<IPassElement>> CGlassPassElement::draw(Render::CRenderContext& ctx) {
    if (m_data.layer && m_data.layer->get())
        m_data.layer->render(ctx, ctx.m_data.pMonitor.lock());
    return {};
}

std::optional<CBox> CGlassPassElement::boundingBox(Render::CRenderContext& ctx) {
    if (m_data.layer) {
        if (auto b = m_data.layer->glassBounds())
            return b;
    }
    const auto monitor = ctx.m_data.pMonitor.lock();
    if (!monitor)
        return std::nullopt;
    const float scale = monitor->m_scale > 0.0f ? monitor->m_scale : 1.0f;
    return CBox{0.0, 0.0, (double)((int)(monitor->m_transformedSize.x / scale)),
                (double)((int)(monitor->m_transformedSize.y / scale))};
}

bool CGlassPassElement::needsLiveBlur(Render::CRenderContext& ctx) {
    return false;
}

bool CGlassPassElement::needsPrecomputeBlur(Render::CRenderContext& ctx) {
    return false;
}

bool CGlassPassElement::disableSimplification(Render::CRenderContext& ctx) {
    return false;
}
