#version 300 es
precision highp float;

// Real backdrop blend for a full-screen layer surface.
//
// The layer is normally composited with source-over alpha, so a "wash" can
// only tint what is behind it. Here the compositor captures the framebuffer
// behind the surface first (uBackdrop), samples the surface's own committed
// texture (uSource), and writes the W3C soft-light result into the current
// framebuffer. uSource is premultiplied (Wayland/Qt convention), so it is
// divided back out before the blend; uAlpha carries the layer fade.

in vec2 v_texcoord;

uniform sampler2D uBackdrop;
uniform sampler2D uSource;
uniform float     uAlpha;
uniform vec2      uSourceScale;
uniform vec2      uSourceOffset;

layout(location = 0) out vec4 fragColor;

vec3 softLight(vec3 base, vec3 blend) {
    vec3 d = mix(((16.0 * base - 16.0) * base + 4.0) * base,
                 sqrt(base),
                 step(vec3(0.25), base));
    return mix(base - (1.0 - 2.0 * blend) * base * (1.0 - base),
               base + (2.0 * blend - 1.0) * (d - base),
               step(vec3(0.5), blend));
}

void main() {
    vec4 back = texture(uBackdrop, v_texcoord);
    vec4 src  = texture(uSource, v_texcoord * uSourceScale + uSourceOffset);

    // The surface is premultiplied; recover the straight wash colour. The
    // baked PNG alpha is the mix weight (currently 80%).
    vec3  wash = src.rgb / max(src.a, 1e-4);
    float a    = clamp(src.a * uAlpha, 0.0, 1.0);

    fragColor = vec4(mix(back.rgb, softLight(back.rgb, wash), a), 1.0);
}
