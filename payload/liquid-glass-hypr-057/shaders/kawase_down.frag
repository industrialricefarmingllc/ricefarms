#version 300 es
precision highp float;

// Dual-Kawase downsample step (adapted from Hyprland's blur1, vibrancy and
// color-management stages removed — this feeds glass, not the screen).
// Renders into a HALF-size target sampling the full-size source with plain
// fullscreen UVs (no uv*2 remap: unlike upstream's virtual pyramid sharing
// two same-size buffers, our chain uses physically smaller framebuffers).
// 5 taps (center x4 + 4 diagonals); smooth at any radius by construction —
// the fixed 9-tap gaussian this replaces fragmented into sharp-edged blocks
// once the radius outgrew its tap spread.

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

uniform sampler2D uTex;
uniform float uRadius;
uniform vec2 uHalfpixel; // 0.5 / source dims (per level)

void main() {
    vec2 uv = v_texcoord;
    vec4 sum = texture(uTex, uv) * 4.0;
    sum += texture(uTex, uv - uHalfpixel.xy * uRadius);
    sum += texture(uTex, uv + uHalfpixel.xy * uRadius);
    sum += texture(uTex, uv + vec2(uHalfpixel.x, -uHalfpixel.y) * uRadius);
    sum += texture(uTex, uv - vec2(uHalfpixel.x, -uHalfpixel.y) * uRadius);
    fragColor = sum / 8.0;
}
