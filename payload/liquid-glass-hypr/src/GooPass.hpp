#pragma once

// Screen-space goo: a fullscreen directional smear + perpendicular wobble,
// queued as a custom pass element at RENDER_POST_WINDOWS — i.e. after all
// workspace windows (and the wallpaper / bottom layers) have drawn, but
// before the top/overlay layers and the cursor. Windows melt into each other
// mid-transition; the shell stays crisp and the cursor stays sharp.
//
// This is the screen-space half of the ainalem goo reference: the SVG filter
// (blur + alpha threshold) can't threshold an opaque composite, so instead of
// posterizing the wallpaper we smear along the motion axis with a peak
// envelope at mid-transition — motion-liquid rather than metaball-liquid.
// Geometry (stretch/squash/blob/wobble) carries the shape morph; this pass
// sells the fusion. Envelope-gated to ~zero cost outside transitions, and
// fully off at goo_strength = 0.

#include "GooMorph.hpp"
#include "GooTransition.hpp"

#include <hyprland/src/render/pass/PassElement.hpp>

namespace goo {

// Queued per frame at POST_WINDOWS while a transition runs. Recomputes its
// own progress in draw() (queue time != execute time) and no-ops outside the
// envelope, so stale elements are harmless.
class CGooPassElement : public IPassElement {
  public:
    CGooPassElement(TransitionManager* mgr, MONITORID mon, int side, bool vertical, std::vector<SMorphTip> tips);
    virtual ~CGooPassElement() = default;

    std::vector<UP<IPassElement>> draw() override;
    bool                          needsLiveBlur() override { return false; }
    bool                          needsPrecomputeBlur() override { return false; }
    const char*                   passName() override { return "GOO"; }
    ePassElementType              type() override { return EK_CUSTOM; }
    bool                          undiscardable() override { return true; }
    std::optional<CBox>           boundingBox() override;

  private:
    TransitionManager* m_mgr = nullptr;
    MONITORID          m_mon = MONITOR_INVALID;
    int                m_side = 1;
    bool               m_vertical = false;
    std::vector<SMorphTip> m_tips;
};

// Droplet tip: pulls each outgoing window's leading edge into a pointed,
// slightly concave tip aimed at the screen edge — the CodePen droplet. Unlike
// the fullscreen goo smear, this draws ONLY inside the tip triangles (the
// window interior is discarded untouched), so it can't ghost: every pixel it
// touches is inside its own boundingBox and covered by damage.
//
// Staged motion: the tip grows to the screen edge first (t ~0.45); once it
// touches, it stays pinned while the window body slides out from under it,
// thinning and fading like a detaching droplet.
class CGooTipElement : public IPassElement {
  public:
    CGooTipElement(TransitionManager* mgr, MONITORID mon, int side, bool vertical, std::vector<SMorphTip> tips);
    virtual ~CGooTipElement() = default;

    std::vector<UP<IPassElement>> draw() override;
    bool                          needsLiveBlur() override { return false; }
    bool                          needsPrecomputeBlur() override { return false; }
    const char*                   passName() override { return "GOOTIP"; }
    ePassElementType              type() override { return EK_CUSTOM; }
    bool                          undiscardable() override { return true; }
    std::optional<CBox>           boundingBox() override;

  private:
    TransitionManager*      m_mgr = nullptr;
    MONITORID               m_mon = MONITOR_INVALID;
    int                     m_side = 1;
    bool                    m_vertical = false;
    std::vector<SMorphTip> m_tips;
};

} // namespace goo
