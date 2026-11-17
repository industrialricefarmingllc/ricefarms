#version 300 es
precision highp float;

// Per-window wallpaper wash, drawn after the window content.
//
// Dark mode: raw blurred wallpaper, screen-blended at 5%. Light mode: true
// GPU multiply (GL_MULTIPLY_KHR) at 10% coverage. Both are clipped to the
// window's rounded silhouette here; the caller selects the blend equation.

in vec2 v_texcoord;

uniform sampler2D uWash;   // screen-fixed blurred wallpaper (RGBA)
uniform vec2      uScreen; // framebuffer size
uniform vec2      uBox;    // window size, framebuffer px
uniform vec4      uRadii;  // corner radii tl, tr, br, bl, framebuffer px
uniform vec2      uFlare;  // notch shoulders left/right, framebuffer px
uniform float     uPower;  // rounding power (2 = circular)
uniform float     uSoft;   // 1 = light-mode multiply, 0 = dark screen
uniform float     uDarkOpacity; // dark-mode screen source scale
uniform float     uFade;        // window/workspace fade 0..1

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

float sdBox2(vec2 p, vec2 b) {
    vec2 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// Notch flare: flare box intersect outside-of-disc at the outer-bottom corner.
// Same geometry as the glass shader; the union with the pill fills the
// inverted shoulder that a plain rounded box leaves unwashsed.
float sdFlareOnly(vec2 q, vec2 halfPx, vec2 fl) {
    float sdFl = 1e9;
    // See glass.frag: overlap the pill so the shared edge is not a boundary
    // inside the wash mask (it cut a 1px transparent seam at the shoulder).
    float join = clamp(min(halfPx.x, halfPx.y) * 0.6, 4.0, 40.0);
    if (fl.x > 0.01) {
        float f = fl.x;
        vec2 bc = vec2(-halfPx.x - f * 0.5 + join * 0.5, -halfPx.y + f * 0.5);
        vec2 cc = vec2(-halfPx.x - f, -halfPx.y + f);
        sdFl = min(sdFl, max(sdBox2(q - bc, vec2((f + join) * 0.5, f * 0.5)), f - length(q - cc)));
    }
    if (fl.y > 0.01) {
        float f = fl.y;
        vec2 bc = vec2(halfPx.x + f * 0.5 - join * 0.5, -halfPx.y + f * 0.5);
        vec2 cc = vec2(halfPx.x + f, -halfPx.y + f);
        sdFl = min(sdFl, max(sdBox2(q - bc, vec2((f + join) * 0.5, f * 0.5)), f - length(q - cc)));
    }
    return sdFl;
}

void main() {
    vec2 p = v_texcoord * uBox - uBox * 0.5;
    vec2 pillHalf = vec2((uBox.x - uFlare.x - uFlare.y) * 0.5, uBox.y * 0.5);
    vec2 pillCenter = vec2((uFlare.x - uFlare.y) * 0.5, 0.0);
    vec2 pp = p - pillCenter;
    // Interior fast path: a pixel more than one radius inside the pill's
    // straight-sided box is inside the rounded shape with mask == 1, no
    // matter which corner arc or flare is live. Skip the superellipse pow()
    // there; large windows are mostly this case.
    float maxRad = max(max(uRadii.x, uRadii.y), max(uRadii.z, uRadii.w));
    float sd = -1.0;
    float mask = 1.0;
    if (abs(pp.x) > pillHalf.x - maxRad - 1.0 || abs(pp.y) > pillHalf.y - maxRad - 1.0) {
        sd = sdSquircleBox4(pp, pillHalf, uRadii, uPower);
        if (uFlare.x > 0.01 || uFlare.y > 0.01)
            sd = min(sd, sdFlareOnly(pp, pillHalf, uFlare));
        if (sd > 0.0)
            discard;
        mask = 1.0 - smoothstep(-0.75, 0.0, sd);
    }

    vec2 uv = gl_FragCoord.xy / uScreen;
    vec4 wash = texture(uWash, uv);
    if (uSoft > 0.5) {
        // 10% multiply without an advanced blend equation: the shader emits
        // 1 - a*(1-wash), and the caller multiplies it into the destination.
        // This also keeps the shader free of blend-equation layout qualifiers,
        // which some GLSL ES compilers reject.
        float a = 0.10 * mask * uFade;
        fragColor = vec4(vec3(1.0) - a * (vec3(1.0) - wash.rgb), 1.0);
    } else {
        // Dark mode: screen the raw blurred wallpaper at 5%.
        fragColor = vec4(wash.rgb * uDarkOpacity * uFade, 1.0);
    }
}
