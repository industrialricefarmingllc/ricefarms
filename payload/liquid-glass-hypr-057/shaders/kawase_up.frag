#version 300 es
precision highp float;

// Dual-Kawase upsample step (adapted from Hyprland's blur2). Renders into a
// DOUBLE-size target sampling the half-size source, accumulating the lower
// level back up. Plain fullscreen UVs (no uv/2 remap — real chain, see
// kawase_down.frag). 8 taps, weights sum to 12.

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

uniform sampler2D uTex;
uniform float uRadius;
uniform vec2 uHalfpixel; // 0.5 / source dims (per level)

void main() {
    vec2 uv = v_texcoord;
    vec4 sum = texture(uTex, uv + vec2(-uHalfpixel.x * 2.0, 0.0) * uRadius);
    sum += texture(uTex, uv + vec2(-uHalfpixel.x,  uHalfpixel.y) * uRadius) * 2.0;
    sum += texture(uTex, uv + vec2(0.0,            uHalfpixel.y * 2.0) * uRadius);
    sum += texture(uTex, uv + vec2( uHalfpixel.x,  uHalfpixel.y) * uRadius) * 2.0;
    sum += texture(uTex, uv + vec2( uHalfpixel.x * 2.0, 0.0) * uRadius);
    sum += texture(uTex, uv + vec2( uHalfpixel.x, -uHalfpixel.y) * uRadius) * 2.0;
    sum += texture(uTex, uv + vec2(0.0,           -uHalfpixel.y * 2.0) * uRadius);
    sum += texture(uTex, uv + vec2(-uHalfpixel.x, -uHalfpixel.y) * uRadius) * 2.0;
    fragColor = sum / 12.0;
}
