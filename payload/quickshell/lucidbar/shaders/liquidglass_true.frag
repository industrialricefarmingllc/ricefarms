#version 440
layout(location=0) in vec2 qt_TexCoord0;
layout(location=0) out vec4 fragColor;
layout(std140, binding=0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 baseColor;
    float powerFactor;
    float glassWidth;
    float glassHeight;
    float a;
    float b;
    float c;
    float d;
    float fPower;
    float noiseAmount;
    float blurRadius;
    float blurDownscale;
    float blurIters;
    float glowWeight;
    float glowBias;
    float glowEdge0;
    float glowEdge1;
    float boxWidth;
    float boxHeight;
    float cornerRadius;
    float usePill;
    float glassOpacity;
    float glassX;
    float glassY;
    float screenWidth;
    float screenHeight;
};
layout(binding=1) uniform sampler2D source;
const float M_E = 2.718281828459045;
float sdSuperellipse(vec2 p, float n, float r) {
    vec2 pa = abs(p);
    float num = pow(pa.x, n) + pow(pa.y, n) - pow(r, n);
    float den = n * sqrt(pow(pa.x, 2.0*n - 2.0) + pow(pa.y, 2.0*n - 2.0)) + 0.00001;
    return num / den;
}
float sdRoundedBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return min(max(q.x,q.y),0.0) + length(max(q,0.0)) - r;
}
float f_func(float x) {
    return 1.0 - b * pow(c * M_E, -d * x - a);
}
float rand(vec2 co){
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}
float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1,311.7)))*43758.5453); }
vec4 blur13_1D(sampler2D tex, vec2 uv, vec2 res, vec2 dir, float radius) {
    vec2 off1 = vec2(1.411764705882353) * dir * radius;
    vec2 off2 = vec2(3.2941176470588234) * dir * radius;
    vec2 off3 = vec2(5.176470588235294) * dir * radius;
    vec4 c = vec4(0.0);
    c += texture(tex, uv) * 0.1964825501511404;
    c += texture(tex, uv + (off1 / res)) * 0.2969069646728344;
    c += texture(tex, uv - (off1 / res)) * 0.2969069646728344;
    c += texture(tex, uv + (off2 / res)) * 0.09447039785044732;
    c += texture(tex, uv - (off2 / res)) * 0.09447039785044732;
    c += texture(tex, uv + (off3 / res)) * 0.010381362401148057;
    c += texture(tex, uv - (off3 / res)) * 0.010381362401148057;
    return c;
}
vec4 blur13_2D(sampler2D tex, vec2 uv, vec2 res, float radius) {
    if (radius < 0.01) return texture(tex, uv);
    float r = radius;
    vec2 rs = res;
    float w0 = 0.1964825501511404;
    float w1 = 0.2969069646728344;
    float w2 = 0.09447039785044732;
    float w3 = 0.010381362401148057;
    vec4 h0 = blur13_1D(tex, uv + vec2(0.0, -5.176470588235294 * r) / rs, rs, vec2(1.0, 0.0), r);
    vec4 h1 = blur13_1D(tex, uv + vec2(0.0, -3.2941176470588234 * r) / rs, rs, vec2(1.0, 0.0), r);
    vec4 h2 = blur13_1D(tex, uv + vec2(0.0, -1.411764705882353 * r) / rs, rs, vec2(1.0, 0.0), r);
    vec4 h3 = blur13_1D(tex, uv, rs, vec2(1.0, 0.0), r);
    vec4 h4 = blur13_1D(tex, uv + vec2(0.0, 1.411764705882353 * r) / rs, rs, vec2(1.0, 0.0), r);
    vec4 h5 = blur13_1D(tex, uv + vec2(0.0, 3.2941176470588234 * r) / rs, rs, vec2(1.0, 0.0), r);
    vec4 h6 = blur13_1D(tex, uv + vec2(0.0, 5.176470588235294 * r) / rs, rs, vec2(1.0, 0.0), r);
    return h0 * w3 + h1 * w2 + h2 * w1 + h3 * w0 + h4 * w1 + h5 * w2 + h6 * w3;
}
void main() {
    vec2 uv = qt_TexCoord0;
    float sd;
    float dist;
    // Per-pixel edge normal for the glow (finite differences, set per branch
    // below). Falls back to top-light if the field degenerates.
    vec2 glowN = vec2(0.0, -1.0);
    // True-edge mask driver (0 at the bevel, rising inward), set per branch.
    float glowIn = 0.0;
    if (usePill > 0.5) {
        vec2 p_px = (uv - vec2(0.5)) * vec2(boxWidth, boxHeight);
        vec2 scaleWH2 = vec2(3.5) / vec2(max(glassWidth,0.1), max(glassHeight,0.1));
        p_px *= scaleWH2;
        float r = min(cornerRadius, min(boxWidth, boxHeight)*0.5);
        vec2 halfBox = vec2(boxWidth, boxHeight) * 0.5;
        sd = sdRoundedBox(p_px, halfBox, r);
        dist = clamp(-sd / max(r, 1.0), 0.0, 1.0);
        // True edge field (unscaled): the scaled lens field above drifts off
        // the visible bevel whenever glass size != 3.5. Mask + normal come
        // from here so the glow hugs the bevel. Finite differences, not
        // dFdx (constant per 2x2 quad -> harsh facet blocks).
        vec2 pEdge = (uv - vec2(0.5)) * vec2(boxWidth, boxHeight);
        float sdTrue = sdRoundedBox(pEdge, halfBox, r);
        // Proxy rounded by >= band width: its medial-axis kinks sit outside
        // the band, so no corner diagonals; mask stays on the true edge.
        float bevW = max(r * 0.5, 6.0);
        float pr = max(r, bevW);
        float tgx = sdRoundedBox(pEdge + vec2(1.0, 0.0), halfBox, pr) - sdRoundedBox(pEdge - vec2(1.0, 0.0), halfBox, pr);
        float tgy = sdRoundedBox(pEdge + vec2(0.0, 1.0), halfBox, pr) - sdRoundedBox(pEdge - vec2(0.0, 1.0), halfBox, pr);
        glowN = vec2(tgx, tgy) / max(length(vec2(tgx, tgy)), 1e-4);
        glowIn = clamp(-sdTrue / bevW, 0.0, 1.0);
    } else {
        vec2 p_super = (uv - vec2(0.5)) * 2.0;
        vec2 scaleWH = vec2(3.5) / vec2(max(glassWidth,0.1), max(glassHeight,0.1));
        p_super *= scaleWH;
        float sdS = sdSuperellipse(p_super, powerFactor, 1.0);
        if (sdS > 0.0) discard;
        sd = sdS;
        dist = clamp(-sdS, 0.0, 2.0);
        // Silhouette-true already (discard uses this field): normal + mask
        // stay in its units, ~1.5px epsilon.
        vec2 pSup0 = (uv - vec2(0.5)) * 2.0;
        float sse = 3.0 / max(min(boxWidth, boxHeight), 1.0);
        float sgx = sdSuperellipse(pSup0 + vec2(sse, 0.0), powerFactor, 1.0) - sdSuperellipse(pSup0 - vec2(sse, 0.0), powerFactor, 1.0);
        float sgy = sdSuperellipse(pSup0 + vec2(0.0, sse), powerFactor, 1.0) - sdSuperellipse(pSup0 - vec2(0.0, sse), powerFactor, 1.0);
        glowN = vec2(sgx, sgy) / max(length(vec2(sgx, sgy)), 1e-4);
        // Unit band (zero at -sdS = 0.5, as before); super field has no
        // medial kinks except the masked-out center.
        glowIn = clamp(-sdS * 2.0, 0.0, 1.0);
    }
    float fx = f_func(dist);
    fx = clamp(fx, 0.0, 2.0);
    float refract = pow(max(fx, 0.0001), fPower);
    vec2 p = (uv - vec2(0.5)) * 2.0;
    vec2 refractVec = p * (refract - 1.0) * 0.18;
    // Map glass uv + refraction to full-screen wallpaper uv (like original's sampleP * scale + MidPoint)
    vec2 screenSize = vec2(max(screenWidth,1.0), max(screenHeight,1.0));
    vec2 boxSize = vec2(max(boxWidth,1.0), max(boxHeight,1.0));
    vec2 glassPos = vec2(glassX, glassY);
    vec2 screenUV = (glassPos + uv * boxSize) / screenSize;
    vec2 refractScreen = refractVec * boxSize / screenSize;
    vec2 sampleUV = screenUV + refractScreen;
    // Dithering for blur to hide banding — blue-noise-like jitter per fragment
    // Perturb sampleUV with sub-texel noise before blur sampling
    float down = clamp(blurDownscale, 0.15, 1.0);
    vec2 resEff = screenSize * down;
    // 0.5-texel dither in resEff space
    vec2 dither = vec2(hash(gl_FragCoord.xy * 0.009) - 0.5, hash(gl_FragCoord.xy * 0.011 + vec2(7.0, 13.0)) - 0.5) * 0.6 / resEff;
    sampleUV += dither;
    sampleUV = clamp(sampleUV, vec2(0.001), vec2(0.999));
    vec4 bg;
    float iters = clamp(blurIters, 0.0, 10.0);
    float radius = clamp(blurRadius, 0.0, 10.0);
    if (iters < 0.5 || radius < 0.01) {
        bg = texture(source, sampleUV);
    } else {
        float iterScale = sqrt(max(iters, 1.0));
        float effRadius = radius * iterScale;
        // Proper gaussian blur on full-screen wallpaper at downscaled resolution, then refracted sampling
        bg = blur13_2D(source, sampleUV, resEff, effRadius);
        // Add slight blue-noise dithering after blur to break up 8-bit banding
        float nDither = (hash(gl_FragCoord.xy * 0.007) - 0.5) * 0.015;
        bg.rgb += vec3(nDither);
    }
    if (bg.a < 0.01) {
        bg = baseColor;
    } else {
        // Light themes (matugen #ffffff lowest) would white-out bg at 0.62 — keep true background colors
        float tint = clamp(glassOpacity, 0.0, 1.0);
        bg = mix(bg, vec4(baseColor.rgb, 1.0), tint * 0.28);
        bg.a = 1.0;
    }
    // Original noise after sampling blurred bg
    vec3 n = vec3(rand(gl_FragCoord.xy * 0.009) - 0.5, rand(gl_FragCoord.xy * 0.013 + vec2(17.0, 31.0)) - 0.5, rand(gl_FragCoord.xy * 0.011 + vec2(43.0, 7.0)) - 0.5);
    bg.rgb += n * noiseAmount * 3.5;
    // Bipolar diagonal bevel glow: |sin| gives two identical poles with a
    // true-zero node between them; +PI/4 puts the axis, sign flipped for -45deg on the diagonal.
    // Direction fades to neutral with depth (kdir), mask keeps the slider
    // ramp (defaults peak 0.5 at the rim, zero at the band edge).
    // Layer 1 (multiplicative, kept) + layer 2 (plain white additive, 33%).
    float gdir = abs(sin(atan(glowN.y, glowN.x) - 0.5 - 0.4363323129));
    float kdir = 1.0 - smoothstep(0.0, 1.0, glowIn);
    float g = mix(0.0, gdir, kdir);
    float edgeMask = 1.0 - smoothstep(glowEdge1, glowEdge0, glowIn * 0.5);
    float glow = g * glowWeight * edgeMask + 1.0 + glowBias;
    bg.rgb *= glow;
    bg.rgb += vec3(1.0) * (g * edgeMask) * 0.33;
    float top = smoothstep(0.0, 0.24, dist) * (1.0 - smoothstep(0.0, 0.60, uv.y)) * refract;
    bg.rgb += vec3(1.0) * top * 0.10;
    float rim = smoothstep(0.0, 0.02, dist) - smoothstep(0.02, 0.06, dist);
    bg.rgb += vec3(1.0) * rim * 0.14 * refract;
    float edge = smoothstep(0.0, 0.08, dist) - smoothstep(0.08, 0.16, dist);
    bg.rgb -= vec3(0.08) * edge * (1.0 - refract*0.5);
    bg.rgb = clamp(bg.rgb, 0.0, 1.0);
    bg.a = clamp(glassOpacity, 0.0, 1.0);
    fragColor = bg * qt_Opacity;
}
