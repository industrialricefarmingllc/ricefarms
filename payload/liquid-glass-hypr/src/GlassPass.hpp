#pragma once

// Single render-pass element per glassed layer surface. Runs before the
// surface itself draws: sample, blur, glass into the backdrop, then the
// original renderLayer draws text/icons crisply on top.
//
// needsLiveBlur() forces a full backdrop render first, so the glass samples
// fresh pixels every frame it draws — that flag is the 60fps guarantee.

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

    std::vector<UP<IPassElement>> draw() override;
    [[nodiscard]] bool                needsLiveBlur() override;
    [[nodiscard]] bool                needsPrecomputeBlur() override;
    [[nodiscard]] std::optional<CBox> boundingBox() override;
    [[nodiscard]] bool                disableSimplification() override;
    // Layers stay undiscardable (true): tune/bounds detection lives inside
    // render(), which only runs when the element draws — discarding would
    // miss prefs edits with no other damage (stale glass until next damage).
    // Cost is only element traversal: per-pill damage gates in render() still
    // skip all blit/blur/draw work on static frames, so the GPU sleeps.
    // Windows differ (snapshot damages from the hook), so they are
    // discardable — see WindowGlass.hpp.
    [[nodiscard]] bool                undiscardable() override { return true; }

    [[nodiscard]] const char* passName() override { return "CGlassPassElement"; }
    [[nodiscard]] ePassElementType type() override { return EK_CUSTOM; }

  private:
    SData m_data;
};
