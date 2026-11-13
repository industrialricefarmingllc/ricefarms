#pragma once

// Adaptive wallpaper wash for windows and Lucid shell layers.
//
// Windows: screen-fixed blurred-wallpaper texture, blended MIN/MAX against the
// window content (10% strength baked into the texture).
// Layers: the same texture over the pills published by Quickshell's
// GlassLayout bridge, so bar/dock/OSD/launcher cards get the same effect.

#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/Shader.hpp>
#include <hyprland/src/render/WindowRenderPresentation.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>

#include <array>
#include <optional>
#include <vector>

struct SWindowWashDraw {
    CBox                 box{0, 0, 0, 0}; // monitor-local framebuffer px
    std::array<float, 4> radii{0, 0, 0, 0}; // tl, tr, br, bl
    std::array<float, 2> flare{0, 0};       // notch shoulders, left/right
    float                power = 2;
    float                alpha = 1;
};

namespace lg {
SP<Render::ITexture> washTexture();

std::optional<SWindowWashDraw>
windowWashSnapshot(PHLWINDOW window, PHLMONITOR monitor, const Render::SWindowRenderPresentation& presentation);

std::vector<SWindowWashDraw> layerWashSnapshots(PHLLS surface, PHLMONITOR monitor);

// Wash is queued during the scene pass and applied to the output framebuffer
// after Hyprland's final copy, so the scene/work buffer used for glass
// backdrops never contains the wash.
void queueWindowWash(PHLWINDOW window, PHLMONITOR monitor, const Render::SWindowRenderPresentation& presentation);
void queueLayerWash(PHLLS surface, PHLMONITOR monitor);
void drawQueuedWash(PHLMONITOR monitor, const SP<Render::IFramebuffer>& target, const CRegion& damage, bool transformDamage);
void clearQueuedWash(PHLMONITOR monitor);

// Screencopy reads the mirror framebuffer Hyprland fills from the work buffer,
// before the final screen shader and before the wash above. While a
// monitor/region capture is active, refresh it from the finished output so the
// saved image is what the screen shows.
void mirrorFromOutput(PHLMONITOR monitor, const SP<Render::IFramebuffer>& output, const CRegion& damage, bool transformDamage);

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
