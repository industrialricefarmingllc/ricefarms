#version 300 es
precision highp float;

// Per-window wallpaper wash, drawn after the window content.
//
// The compositor captures the freshly rendered window pixels (uBase) and
// this shader mixes the screen-fixed blurred-wallpaper texture (uWash) over
// them with the W3C soft-light formula. The rounded silhouette comes from the
// window's own rounding, so the wash never spills past the window edge.
//
// Both textures are sampled in screen space (gl_FragCoord / uScreen), which
// keeps the wash aligned through moves, resizes and workspace slides without
// any IPC geometry bridge.

in vec2 v_texcoord;

uniform sampler2D uBase;   // window content, full-monitor capture
uniform sampler2D uWash;   // screen-fixed blurred wallpaper (RGBA)
uniform vec2      uScreen; // framebuffer size
uniform vec2      uBox;    // window size, framebuffer px
uniform float     uRadius; // corner radius, framebuffer px
uniform float     uPower;  // rounding power (2 = circular)
uniform float     uAlpha;  // window/workspace fade
uniform float     uLight;  // 1 = light theme (darken), 0 = dark theme (lighten)

layout(location = 0) out vec4 fragColor;

// Shared squircle box SDF (same shape as squircle_box.glsl).
float sdSquircleBox4(vec2 p, vec2 b, vec4 r, float n) {
    float rt = (p.x > 0.0) ? r.y : r.x;
    float rb = (p.x > 0.0) ? r.z : r.w;
    float rad = (p.y > 0.0) ? rb : rt;
    vec2 ap = abs(p);
    vec2 c = b - vec2(rad);
    if (rad > 0.01 && ap.x > c.x && ap.y > c.y) {
        if (n <= 2.001)
            return length(ap - c) - rad;
        vec2 q = (ap - c) / rad;
        float n2 = 2.0 * n - 2.0;
        float num = pow(q.x, n) + pow(q.y, n) - 1.0;
        float den = n * sqrt(pow(q.x, n2) + pow(q.y, n2)) + 0.0001;
        return num / den * rad;
    }
    vec2 q2 = ap - b + vec2(rad);
    return min(max(q2.x, q2.y), 0.0) + length(max(q2, 0.0)) - rad;
}

void main() {
    vec2 p = v_texcoord * uBox - uBox * 0.5;
    float sd = sdSquircleBox4(p, uBox * 0.5, vec4(uRadius), uPower);
    if (sd > 0.5)
        discard;

    float mask = 1.0 - smoothstep(-0.5, 0.5, sd);
    vec2 uv = gl_FragCoord.xy / uScreen;
    vec4 base = texture(uBase, uv);
    vec4 wash = texture(uWash, uv);
    // Dark mode: brighten with the wash. Light mode: darken with it.
    vec3 mixed = uLight > 0.5 ? min(base.rgb, wash.rgb) : max(base.rgb, wash.rgb);
    fragColor = vec4(mix(base.rgb, mixed, wash.a * uAlpha * mask), 1.0);
}
