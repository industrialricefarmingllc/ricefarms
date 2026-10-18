#pragma once

// Glass replacement for Hyprland window borders.
//
// Upstream draws every window border through CHyprOpenGLImpl::renderBorder
// (2 overloads: single gradient, animated gradient pair), with the window
// box already in monitor-local framebuffer px — the same space our pill
// boxes live in. We hook both overloads, cancel the flat border, and draw a
// glass RING (ring.frag) over the same band instead:
//
//   PRE (at hook time) the band region still shows the real backdrop: lower
//   windows and wallpaper are already drawn (painter's order), and the
//   window's own edge pixels are drawn too (surface precedes its border).
//   So one capture gives us exactly what glass needs.
//
// Pairing: the animated overload fires twice per border (grad1, grad2, same
// box, back to back). The first call captures + draws with both gradient
// colors and the lerp; the second call (same box as the previous one) only
// cancels. The single-gradient overload fires once per border.

#include <hyprland/src/config/shared/complex/ComplexDataTypes.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/decorations/CHyprDropShadowDecoration.hpp>

namespace lg {

using RenderBorder1Fn = void (*)(Render::GL::CHyprOpenGLImpl*, const CBox&, const Config::CGradientValueData&,
                                 Render::GL::CHyprOpenGLImpl::SBorderRenderData);
using RenderBorder2Fn = void (*)(Render::GL::CHyprOpenGLImpl*, const CBox&, const Config::CGradientValueData&,
                                 const Config::CGradientValueData&, float,
                                 Render::GL::CHyprOpenGLImpl::SBorderRenderData);

extern RenderBorder1Fn g_origRenderBorder1;
extern RenderBorder2Fn g_origRenderBorder2;

void hkRenderBorder1(Render::GL::CHyprOpenGLImpl* self, const CBox& box, const Config::CGradientValueData& grad,
                     Render::GL::CHyprOpenGLImpl::SBorderRenderData data);
void hkRenderBorder2(Render::GL::CHyprOpenGLImpl* self, const CBox& box, const Config::CGradientValueData& grad1,
                     const Config::CGradientValueData& grad2, float lerp,
                     Render::GL::CHyprOpenGLImpl::SBorderRenderData data);

// Window drop shadows (CHyprDropShadowDecoration::draw submits the shadow
// pass element; window decorations only, so layer surfaces are unaffected).
// Cancelled while hiding — the user's own decoration:shadow settings are
// never touched, so flipping back restores them exactly.
using DropShadowDrawFn = void (*)(CHyprDropShadowDecoration*, PHLMONITOR, const float&);
extern DropShadowDrawFn g_origDropShadowDraw;
void hkDropShadowDraw(CHyprDropShadowDecoration* self, PHLMONITOR monitor, const float& a);

// Compiles the ring/blur programs on first use. The hooks fall back to the
// original flat border while this is false — a broken shader must never
// mean missing borders.
bool borderGlassReady();

} // namespace lg
