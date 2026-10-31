#pragma once

// Real backdrop blend for full-screen layer surfaces.
//
// The ordinary layer path composites the surface with source-over alpha. For
// the Lucid wallpaper wash that only tints the windows; an actual overlay()
// blend needs both the surface pixels and the pixels already in the
// framebuffer. This pass captures the latter into a scratch FBO, then draws
// the surface's own committed texture over it with shaders/blend.frag.
//
// It replaces the layer's normal draw: hkRenderLayer adds this element and
// does not call the original renderLayer for the matched namespace. The
// element's bounding box is the whole output, so it runs whenever the layer
// is damaged (window move, wash animation, workspace slide).

#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/Shader.hpp>
#include <hyprland/src/render/Context.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>

#include <optional>
#include <vector>

namespace lg {
// Compiles the blend shader/VAO once. Called from the hook so a failed
// shader falls back to the layer's ordinary draw instead of hiding it.
bool blendReady();

// Composite `source` over the current framebuffer with the overlay blend.
// Safe to call when the shader or scratch framebuffer is unavailable: it
// simply draws nothing.
void renderBlend(const SP<Render::ITexture>& source, float alpha);
} // namespace lg

class CBlendPassElement : public IPassElement {
  public:
    struct SData {
        SP<Render::ITexture> source;
        float                alpha = 1.F;
    };

    explicit CBlendPassElement(const SData& data);

    std::vector<UP<IPassElement>> draw(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool            needsLiveBlur(Render::CRenderContext& ctx) override { return false; }
    [[nodiscard]] bool            needsPrecomputeBlur(Render::CRenderContext& ctx) override { return false; }
    [[nodiscard]] std::optional<CBox> boundingBox(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool            disableSimplification(Render::CRenderContext& ctx) override { return false; }

    [[nodiscard]] const char* passName() override { return "CBlendPassElement"; }
    [[nodiscard]] ePassElementType type() override { return EK_CUSTOM; }

  private:
    SData m_data;
};
