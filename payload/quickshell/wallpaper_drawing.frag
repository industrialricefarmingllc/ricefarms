// Wallpaper drawing reveal.
//
// Port of skwd-wall's beta.29 "drawing" transition: the old picture becomes
// paper, an ink sketch of the new one draws itself in, and then a liquid pour
// floods the frame with the new photo. It is the cover for a wallpaper apply,
// started as soon as the new picture is available.
//
// Everything expensive is precomputed once per apply by wallpaper_sketch.frag
// (density and stroke order in one texture). This pass is the minimum:
//
//   paper/build/home  1 fetch (sketch data) + 1 during the 8 % paper fade
//   pour              2 fetches (sketch data + bent photo), 3 for the last 9 %
//
// The cost model is dominated by presenting a full-screen layer at all, not by
// these samples; that is why the caller also caps the frame rate.
//
// Compile after editing:
//   /usr/lib/qt6/bin/qsb --qt6 -o wallpaper_drawing.frag.qsb wallpaper_drawing.frag
#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 itemSize;
    vec2 drawFocus;
    float stage;
    vec4 paper;
    vec4 ink;
};

layout(binding = 1) uniform sampler2D wallpaperTex;
layout(binding = 2) uniform sampler2D fromTex;
layout(binding = 3) uniform sampler2D sketchTex;

const float PI = 3.14159265;
// Same split as skwd's drawing shader: fade to paper, build the sketch, then
// pour. The wall's timings are fractions of the transition.
const float PAPER_START = 0.08;
const float BUILD_END = 0.64;

float aspect() { return itemSize.x / itemSize.y; }

vec3 photo(vec2 uv) {
    return texture(wallpaperTex, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
}

vec3 previous(vec2 uv) {
    return texture(fromTex, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
}

// r = ink density, g = stroke order.
vec4 sketchData(vec2 uv) {
    return texture(sketchTex, clamp(uv, vec2(0.0), vec2(1.0)));
}

vec2 metric(vec2 p) { return p * vec2(aspect(), 1.0); }

float reach() {
    vec2 f = drawFocus;
    return max(max(length(metric(f)), length(metric(vec2(1.0, 0.0) - f))),
               max(length(metric(vec2(0.0, 1.0) - f)), length(metric(vec2(1.0) - f))));
}

// The pour: an organic glass front spreading from `focus`, bending the photo
// at the rim and leaving the fully drawn sketch behind it.
vec3 liquid(float t) {
    vec2 uv = qt_TexCoord0;
    vec2 p = metric(uv - drawFocus);
    float d = length(p);
    float angle = atan(p.y, p.x);
    float maxRadius = reach();
    float organic = (sin(angle * 3.0 + 0.5) + sin(angle * 5.0 - 1.1) * 0.38)
        * 0.035 * sin(t * PI);
    float radius = (t * 1.25 - 0.07) * maxRadius;
    float sdf = d - radius - organic;
    float width = 0.035 * maxRadius;
    float inside = 1.0 - smoothstep(-width * 0.2, width * 0.25, sdf);
    vec2 n = p / max(d, 0.0001) / vec2(aspect(), 1.0);
    float rim = exp(-pow(sdf / max(width, 0.001), 2.0)) * sin(t * PI);
    vec3 drawn = mix(paper.rgb, ink.rgb, sketchData(uv + n * rim * 0.006).r);
    vec3 result = mix(drawn, photo(uv - n * rim * 0.018), inside);
    result = result * (1.0 - rim * 0.06);
    // Only the last 9 % of the pour blends to the untouched photo, so the
    // extra fetch is paid only there.
    float complete = smoothstep(0.91, 1.0, t);
    if (complete > 0.0)
        result = mix(result, photo(uv), complete);
    return result;
}

vec4 shade(vec3 colour) {
    float alpha = clamp(qt_Opacity, 0.0, 1.0);
    return vec4(colour * alpha, alpha);
}

void main() {
    vec2 uv = qt_TexCoord0;
    float t = stage;
    if (t <= 0.0) {
        fragColor = shade(previous(uv));
        return;
    }
    if (t >= 1.0) {
        fragColor = shade(photo(uv));
        return;
    }
    if (t < BUILD_END) {
        float paperMix = smoothstep(0.0, PAPER_START, t);
        float phase = clamp((t - PAPER_START) / (BUILD_END - PAPER_START), 0.0, 1.0);
        vec4 s = sketchData(uv);
        float lead = s.g * 0.94;
        float amount = s.r * smoothstep(lead, lead + 0.055, phase);
        vec3 colour = mix(paper.rgb, ink.rgb, clamp(amount, 0.0, 1.0));
        if (paperMix < 1.0)
            colour = mix(previous(uv), colour, paperMix);
        fragColor = shade(colour);
        return;
    }
    float pour = clamp((t - BUILD_END) / (1.0 - BUILD_END), 0.0, 1.0);
    fragColor = shade(liquid(pour));
}
