#pragma once

// Single render-pass element per glassed layer surface. Runs before the
// surface itself draws: sample, blur, glass into the backdrop, then the
// original renderLayer draws text/icons crisply on top.

#include "Glass.hpp"

#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprutils/math/Box.hpp>

#include <memory>
#include <optional>
#include <vector>

class CGlassPassElement : public IPassElement {
  public:
    struct SData {
        std::shared_ptr<CGlassLayer> layer;
    };

    explicit CGlassPassElement(const SData& data);

    std::vector<UP<IPassElement>> draw(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool            needsLiveBlur(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool            needsPrecomputeBlur(Render::CRenderContext& ctx) override;
    [[nodiscard]] std::optional<CBox> boundingBox(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool            disableSimplification(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool            undiscardable(Render::CRenderContext& ctx) override { return true; }

    [[nodiscard]] const char* passName() override { return "CGlassPassElement"; }
    [[nodiscard]] ePassElementType type() override { return EK_CUSTOM; }

  private:
    SData m_data;
};
