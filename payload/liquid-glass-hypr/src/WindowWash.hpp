#pragma once

// Per-window wallpaper wash.
//
// Replaces the old full-screen QML overlay layer. For each window, after its
// content has been rendered, the plugin captures that window's pixels and
// soft-light blends the screen-fixed blurred wallpaper over them. Geometry
// comes straight from the compositor (CWindow), so the wash tracks moves,
// resizes and workspace slides exactly; there is no IPC stream and no
// full-screen blend pass that could re-blend its own previous output.
//
// The texture is ~/.cache/quickshell/wallpaper-softlight.path (RGBA, already
// carrying the 80% wash alpha). It is reloaded when the path or PNG changes.

#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/Shader.hpp>
#include <hyprland/src/render/Context.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/output/Monitor.hpp>

#include <optional>

struct SWindowWashDraw {
    CBox  box{0, 0, 0, 0}; // monitor-local framebuffer px
    float radius = 0;      // framebuffer px
    float power  = 2;      // corner exponent
    float alpha  = 1;      // window/workspace fade
};

namespace lg {
// Load/reload the baked wash texture from the Quickshell cache path.
SP<Render::ITexture> washTexture();

// Sample a window's live geometry; nullopt when it should not be washed.
std::optional<SWindowWashDraw> windowWashSnapshot(PHLWINDOW window, PHLMONITOR monitor);

// Capture the window's current pixels and draw the soft-light wash.
void windowWashDraw(const SWindowWashDraw& draw, const SP<Render::ITexture>& wash);
} // namespace lg

class CWindowWashPassElement : public IPassElement {
  public:
    struct SData {
        SWindowWashDraw      draw;
        SP<Render::ITexture> wash;
    };

    explicit CWindowWashPassElement(const SData& data);

    std::vector<UP<IPassElement>> draw(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool            needsLiveBlur(Render::CRenderContext& ctx) override { return false; }
    [[nodiscard]] bool            needsPrecomputeBlur(Render::CRenderContext& ctx) override { return false; }
    [[nodiscard]] std::optional<CBox> boundingBox(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool            disableSimplification(Render::CRenderContext& ctx) override { return false; }

    [[nodiscard]] const char* passName() override { return "CWindowWashPassElement"; }
    [[nodiscard]] ePassElementType type() override { return EK_CUSTOM; }

  private:
    SData m_data;
};
