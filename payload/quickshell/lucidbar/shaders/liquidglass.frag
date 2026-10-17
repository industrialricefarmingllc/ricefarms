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
};
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
        // no discard — mask handles pill shape, keeps highlight correct
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
    // Glass blur now actually softens refraction like original BlurPass (blurIters 0..10, radius 0..10)
    // was: refract *= mix(1.0, 1.0 - blurDownscale*0.15, ...) * (1+blurRadius*0.02...)
    // now: stronger, visible reduction of highlight intensity and spread
    float blurFactor = clamp(blurIters / 10.0, 0.0, 1.0) * clamp(blurRadius / 10.0, 0.0, 1.0);
    refract *= mix(1.0, 0.45, blurFactor * 0.9);
    refract *= 1.0 - blurDownscale * 0.08 * blurFactor;
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
    vec4 col = baseColor;
    float a0 = max(col.a, 0.0001);
    vec3 baseRgb = col.rgb / a0;
    // True to original: noise added after sampling blurred bg, visible grain
    // was *1.2 subtle on opaque baseColor, now *6.0 and dithered for visibility
    vec3 n = vec3(rand(gl_FragCoord.xy * 0.71) - 0.5, rand(gl_FragCoord.xy * 1.33 + vec2(17.0, 31.0)) - 0.5, rand(gl_FragCoord.xy * 0.97 + vec2(43.0, 7.0)) - 0.5);
    baseRgb += n * noiseAmount * 6.0;
    baseRgb *= glow;
    baseRgb += vec3(1.0) * (g * edgeMask) * 0.33;
    float top = smoothstep(0.0, 0.24, dist) * (1.0 - smoothstep(0.0, 0.60, uv.y)) * refract;
    baseRgb += vec3(1.0) * top * 0.45;
    float rim = smoothstep(0.0, 0.02, dist) - smoothstep(0.02, 0.06, dist);
    baseRgb += vec3(1.0) * rim * 0.70 * refract;
    float edge = smoothstep(0.0, 0.08, dist) - smoothstep(0.08, 0.16, dist);
    baseRgb -= vec3(0.08) * edge * (1.0 - refract*0.5);
    col.rgb = clamp(baseRgb * a0, 0.0, 1.0);
    fragColor = col * qt_Opacity;
}
