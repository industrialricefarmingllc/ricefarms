#version 300 es
precision highp float;

// Bright-pass bokeh scatter (camera-lens out-of-focus discs). Runs once at
// the end of the Kawase chain (half res), compositing round highlight discs
// over the smooth base. Off by default (uBokeh 0 = passthrough cost only).
// 17 taps: center + 2 golden-angle rings x 8. Disc radius follows the blur
// radius so bokeh grows with blur; threshold + soft knee keep it to
// highlights. Round by construction — the blocky fragments the old gaussian
// left at high intensities can't appear here (no wide sparse kernel).

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

uniform sampler2D uTex;
uniform float uRadius;    // base spread, L0 texels (same effR as Kawase)
uniform vec2 uHalfpixel;  // 0.5 / source dims
uniform float uBokeh;     // 0..1 strength (0 disables visually)

const float GOLDEN = 2.3999632; // golden angle: even round coverage

float knee(float x) {
    return smoothstep(0.45, 0.75, x);
}

void main() {
    vec2 uv = v_texcoord;
    vec4 base = texture(uTex, uv);
    float discR = max(uRadius * (1.0 + 2.0 * uBokeh), 0.75);
    vec2 px = uHalfpixel * 2.0; // 1 texel in uv

    // Threshold-weighted scatter: taps are the disc (golden-angle round by
    // construction), so no per-tap edge term — weights come from brightness.
    vec3 acc = base.rgb * knee(dot(base.rgb, vec3(0.3333)));
    float wsum = knee(dot(base.rgb, vec3(0.3333)));
    for (int i = 0; i < 16; i++) {
        float fi = float(i);
        float ang = fi * GOLDEN;
        float rr = (mod(fi, 2.0) < 1.0 ? 0.55 : 1.0) * discR;
        vec2 off = vec2(cos(ang), sin(ang)) * rr * px;
        vec3 s = texture(uTex, uv + off).rgb;
        float w = knee(dot(s, vec3(0.3333)));
        acc += s * w;
        wsum += w;
    }
    vec3 disc = acc / max(wsum, 1e-4);
    float m = clamp(wsum / 9.0, 0.0, 1.0) * uBokeh;
    vec3 col = mix(base.rgb, disc, m * 0.85);
    fragColor = vec4(col, base.a);
}
