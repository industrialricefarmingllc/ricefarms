// Static half of the wallpaper drawing reveal.
//
// Bakes two scalars per pixel once per apply: the ink density (red) and the
// stroke order (green). The animated pass reconstructs the sketch from those
// two channels with a single texture fetch, so it never re-runs this work per
// frame.
//
// The drawing is XDoG line art (single continuous strokes, no hollow cores).
// On top of it sits the paper pass from ~/.config/hypr/shaders/reading_mode.glsl
// (paper fibres, directional grain, ebook speckle, 4x4 Bayer dither,
// vignette). The tone curve of that shader is deliberately not applied: it is
// meant to map a full colour screen, and would replace the sketch with an
// e-ink rendition of the photo. Here the e-ink pass only textures the page.
//
// The drawing palette in WallpaperReveal.qml matches that shader:
//   paper = vec3(0.94, 0.92, 0.86) - 50/255
//   ink   = vec3(0.10, 0.10, 0.12)
//
// Compile after editing:
//   /usr/lib/qt6/bin/qsb --qt6 -o wallpaper_sketch.frag.qsb wallpaper_sketch.frag
#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 itemSize;
    vec2 screenSize;
};

layout(binding = 1) uniform sampler2D wallpaperTex;

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec3 photo(vec2 uv) {
    return texture(wallpaperTex, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
}

// ---- XDoG line work ------------------------------------------------------

float gaussLuma(vec2 uv, float sigma) {
    float sum = 0.0;
    float weight = 0.0;
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            float d2 = float(x * x + y * y);
            float w = exp(-d2 / (2.0 * sigma * sigma));
            sum += luma(photo(uv + vec2(float(x), float(y)) / itemSize)) * w;
            weight += w;
        }
    }
    return sum / weight;
}

// ---- e-ink paper pass (ported, no tone curve) ----------------------------

float einkHash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float einkValueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(einkHash(i), einkHash(i + vec2(1.0, 0.0)), f.x),
               mix(einkHash(i + vec2(0.0, 1.0)), einkHash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float getBayer(vec2 pos) {
    int x = int(mod(pos.x, 4.0));
    int y = int(mod(pos.y, 4.0));
    const mat4 bayer = mat4(
        0.0, 12.0,  3.0, 15.0,
        8.0,  4.0, 11.0,  7.0,
        2.0, 14.0,  1.0, 13.0,
        10.0,  6.0,  9.0,  5.0
    );
    return bayer[x][y] / 16.0;
}

float paperTexture(vec2 uv) {
    float n = 0.0;
    n += einkHash(uv * 0.3) * 0.6;
    n += einkHash(uv * 0.8) * 0.4;
    n += einkHash(uv * 2.5) * 0.3;
    n += einkHash(uv * 6.0) * 0.2;
    n += einkHash(uv * 15.0) * 0.1;
    return n / 1.6;
}

float directionalGrain(vec2 uv) {
    vec2 direction = vec2(0.7, 0.3);
    float grain = 0.0;
    grain += einkHash(uv * 3.0 + direction * 2.0) * 0.5;
    grain += einkHash(uv * 8.0 + direction * 5.0) * 0.3;
    return grain / 0.8;
}

float ebookPaper(vec2 px, float weight) {
    float mottle = einkValueNoise(px / 56.0) * 0.65 + einkValueNoise(px / 17.0) * 0.35;
    float clump = einkHash(floor(px / 3.0));
    float tooth = einkHash(px + 91.7);
    float n = (mottle - 0.5) * 0.040
            + (clump - 0.5) * 0.030
            + (tooth - 0.5) * 0.019;
    float fleck = step(0.996, einkHash(floor(px / 2.0) + 137.0));
    n -= fleck * 0.075;
    return n * weight;
}

float vignette(vec2 uv) {
    vec2 center = uv - 0.5;
    float dist = length(center);
    return 1.0 - smoothstep(0.4, 1.2, dist) * 0.15;
}

// Paper-ness of the page, textured by the e-ink pass. `density` is the sketch
// itself; the grain only perturbs the paper and the ink edges.
float page(vec2 density, vec2 uv, vec2 px) {
    float gray = 1.0 - density.r;
    float srcLuma = gray;

    float midTone = smoothstep(0.22, 0.38, srcLuma) * (1.0 - smoothstep(0.88, 1.0, srcLuma));
    float toneWeight = 1.0 - 0.5 * midTone;

    float paperGrain = (paperTexture(px * 0.3) - 0.5) * 0.035;
    float dirGrain = (directionalGrain(px * 0.4) - 0.5) * 0.025;
    float bayerValue = getBayer(px);

    float textureMask = smoothstep(0.5, 0.95, gray) * toneWeight;
    gray += paperGrain * textureMask;
    gray += dirGrain * textureMask * 0.7;

    // Less paper speckle over ink, so the lines stay solid instead of
    // breaking into a dither.
    float pageWeight = mix(0.2, 1.0, smoothstep(0.55, 0.95, gray)) * toneWeight;
    gray += ebookPaper(px, pageWeight);

    gray += (bayerValue - 0.5) * 0.025 * textureMask;
    gray *= vignette(uv);
    return clamp(gray, 0.0, 1.0);
}

// ---- stroke order --------------------------------------------------------

float orderHash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float orderNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(orderHash(i), orderHash(i + vec2(1.0, 0.0)), f.x),
               mix(orderHash(i + vec2(0.0, 1.0)), orderHash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void main() {
    vec2 uv = qt_TexCoord0;
    // Paper grain and the Bayer dither are defined in output pixels in the
    // e-ink shader, so use the screen size rather than the smaller bake.
    vec2 px = uv * screenSize;

    float g = luma(photo(uv));
    // Line scale follows the output height, so the stroke has the same
    // apparent width on a 1080p and a 4K panel.
    float sigma = itemSize.y * 0.0016;
    float diff = gaussLuma(uv, sigma) - 0.97 * gaussLuma(uv, sigma * 1.6);
    // Higher slope and a slightly lower threshold: faint edges either read as
    // a line or stay paper instead of turning into grey haze, and the gamma
    // pulls the half-strength responses down to solid ink.
    float edge = diff >= 0.010 ? 1.0 : 1.0 + tanh(46.0 * (diff - 0.010));
    float line = pow(clamp(1.0 - edge, 0.0, 1.0), 0.80);
    float tone = smoothstep(0.55, 0.95, 1.0 - g) * 0.30;
    vec2 sketch = vec2(clamp(max(line, tone), 0.0, 1.0), 0.0);

    float density = 1.0 - page(sketch, uv, px);

    // Where the pencil reaches this part of the picture: many small clusters
    // carry the order, so the drawing arrives in visible dashes; a slow
    // diagonal sweep keeps it moving across the frame.
    vec2 q = uv * vec2(itemSize.x / itemSize.y, 1.0);
    float sweep = (uv.x * 0.7 + uv.y * 0.7) / 1.4;
    float order = clamp(0.72 * orderNoise(q * 55.0)
                        + 0.28 * sweep
                        + 0.06 * (orderNoise(q * 220.0) - 0.5), 0.0, 1.0);
    fragColor = vec4(density, order, 0.0, 1.0);
}
