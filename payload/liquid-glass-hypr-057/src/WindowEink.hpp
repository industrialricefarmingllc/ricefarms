#pragma once

// Optional true per-window e-ink pass. Appended after the target window's
// content so later windows still draw over it; nothing else is touched.

#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Context.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/Shader.hpp>
#include <hyprland/src/render/WindowRenderPresentation.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprutils/math/Box.hpp>

namespace eink {
void addWindowPass(Render::CRenderContext& ctx, PHLWINDOW window, PHLMONITOR monitor,
    const Render::SWindowRenderPresentation& presentation);
}

struct SEinkDraw {
    CBox  box{0, 0, 0, 0}; // monitor-local framebuffer px
    float radius = 0;
};

class CEinkPassElement : public IPassElement {
  public:
    explicit CEinkPassElement(const SEinkDraw& data) : m_data(data) {}

    std::vector<UP<IPassElement>> draw(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool needsLiveBlur(Render::CRenderContext& ctx) override { return false; }
    [[nodiscard]] bool needsPrecomputeBlur(Render::CRenderContext& ctx) override { return false; }
    [[nodiscard]] std::optional<CBox> boundingBox(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool disableSimplification(Render::CRenderContext& ctx) override { return false; }
    [[nodiscard]] bool undiscardable(Render::CRenderContext& ctx) override { return false; }
    [[nodiscard]] const char* passName() override { return "CEinkPassElement"; }
    [[nodiscard]] ePassElementType type() override { return EK_CUSTOM; }

  private:
    SEinkDraw m_data;
};
