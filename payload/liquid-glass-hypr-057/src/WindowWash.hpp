#pragma once

// Minimal 0.57 wallpaper wash: soft-light a screen-fixed blurred-wallpaper
// texture over each opaque window after its content is rendered.

#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/Shader.hpp>
#include <hyprland/src/render/WindowRenderPresentation.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>

#include <optional>

struct SWindowWashDraw {
    CBox  box{0, 0, 0, 0}; // monitor-local framebuffer px
    float radius = 0;
    float power  = 2;
    float alpha  = 1;
};

namespace lg {
SP<Render::ITexture> washTexture();

std::optional<SWindowWashDraw>
windowWashSnapshot(PHLWINDOW window, PHLMONITOR monitor, const Render::SWindowRenderPresentation& presentation);

void windowWashDraw(const SWindowWashDraw& draw, const SP<Render::ITexture>& wash, Render::CRenderContext& ctx);
} // namespace lg

class CWindowWashPassElement : public IPassElement {
  public:
    struct SData {
        SWindowWashDraw      draw;
        SP<Render::ITexture> wash;
    };

    explicit CWindowWashPassElement(const SData& data);

    std::vector<UP<IPassElement>> draw(Render::CRenderContext& ctx) override;
    bool                          needsLiveBlur(Render::CRenderContext& ctx) override { return false; }
    bool                          needsPrecomputeBlur(Render::CRenderContext& ctx) override { return false; }
    std::optional<CBox>           boundingBox(Render::CRenderContext& ctx) override;
    bool                          disableSimplification(Render::CRenderContext& ctx) override { return false; }
    const char*                   passName() override { return "CWindowWashPassElement"; }
    ePassElementType              type() override { return EK_CUSTOM; }

  private:
    SData m_data;
};
