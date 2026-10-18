#version 300 es
precision highp float;

// Liquid glass pill / superellipse.
//
// Ported from the Quickshell liquidglass_true.frag with two structural
// changes:
//   1. The 49-tap brute-force blur is gone. The background arrives
//      pre-blurred (uBlur, half-res pyramid); this pass does one tap.
//   2. No Qt prelude: v_texcoord spans the pill rect 0..1 (set up by the
//      caller via projectBoxToTarget + scissor, same as Hyprland's own
//      textured quads).
//
// Coordinate spaces: everything below is in framebuffer pixels of the
// capture texture, except vUv which is pill-local 0..1. uBox is the pill
// size in the same pixels as uCapture, so the refraction math is
// resolution-independent, exactly like the QML original.

in vec2 v_texcoord; // spans the DRAW quad (pill + shadow margin, see uPad)

uniform vec4 uPad; // pill subrect inside the draw quad (min.xy, size.xy)
layout(location = 0) out vec4 fragColor;

uniform sampler2D uBlur;  // half-res blurred behind-widget region
uniform sampler2D uSharp; // half-res sharp capture, same region/UVs as uBlur
uniform float uRimBlur;   // 0 regular user-blur, 1 over-rim sharp->r3 ramp
uniform vec2 uCapOrigin;  // pill origin inside capture, in capture UV
uniform vec2 uCapScale;   // pill size / capture size (shared by both textures)
uniform vec3 uBaseColor;
uniform float uPower;   // powerFactor
uniform vec2  uShape;   // glassWidth, glassHeight
uniform float uA;
uniform float uB;
uniform float uC;
uniform float uD;
uniform float uFPower;
uniform float uNoise;
uniform float uCA; // chromatic aberration in the refraction taps (0 = off)
uniform float uDetail; // detail preservation 0..1 (0 = old flat tint mix)
uniform float uLensBand; // 0 full-field lens (pills), 1 band-confined (windows)
uniform float uOverRim; // 0 glass under content, 1 rim-only overdraw (windows)
uniform float uGlowW;
uniform float uGlowB;
uniform float uGlowE0;
uniform float uGlowE1;
uniform float uGlowT; // bright-cap threshold (0 = old full-lobe look)
uniform float uUsePill;
uniform vec4  uRadii; // tl, tr, br, bl corner radii, framebuffer px
uniform vec2  uFlare; // notch flare shoulders (left, right), fb px, 0 = off
uniform float uSquircleF; // shared corner smoothing 0..1 (0 = circular, 0.5 = squircle n=4)
uniform vec2  uBox;   // pill size, framebuffer px
uniform float uOpacity;
uniform float uBevW;  // precomputed bevel band (CPU, saves per-fragment log)
uniform float uEdgePx; // precomputed trio width (CPU, saves per-fragment log)
uniform float uLogCME; // precomputed log(uC*M_E) for f_func exp (CPU)
uniform vec3  uShadowColor;
uniform float uShadowA;
uniform vec2  uShadowOff; // shadow cast offset, framebuffer px (e.g. 0,10)
uniform float uShadowBlur; // softness, framebuffer px

const float M_E = 2.718281828459045;

float sdSuperellipse(vec2 p, float n, float r) {
    vec2 pa = abs(p);
    float num = pow(pa.x, n) + pow(pa.y, n) - pow(r, n);
    float den = n * sqrt(pow(pa.x, 2.0 * n - 2.0) + pow(pa.y, 2.0 * n - 2.0)) + 0.00001;
    return num / den;
}

float sdRoundBox4(vec2 p, vec2 b, vec4 r) {
    // r = (topLeft, topRight, bottomRight, bottomLeft). Shader space is
    // y-down (top edge has negative p.y), so pick top/bottom rows by sign.
    float rt = (p.x > 0.0) ? r.y : r.x; // top row: TR : TL
    float rb = (p.x > 0.0) ? r.z : r.w; // bottom row: BR : BL
    float rad = (p.y > 0.0) ? rb : rt;
    vec2 q = abs(p) - b + rad;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

// Squircle rounded box: same quadrant-picked radii as sdRoundBox4, but the
// corner arc is a superellipse of exponent n (2 = circle, 4 = classic
// squircle at smoothing f = 0.5 via n = 2 + 4f). Straight edges and
// radius-0 corners take the exact box path, so this reduces exactly to
// sdRoundBox4 at n = 2 (and sdPillBox4 below bypasses it entirely at f = 0
// for bit-identical output including far-field shadow falloff).
float sdSquircleBox4(vec2 p, vec2 b, vec4 r, float n) {
    float rt = (p.x > 0.0) ? r.y : r.x;
    float rb = (p.x > 0.0) ? r.z : r.w;
    float rad = (p.y > 0.0) ? rb : rt;
    vec2 ap = abs(p);
    vec2 c = b - vec2(rad);
    if (rad > 0.01 && ap.x > c.x && ap.y > c.y) {
        if (n <= 2.001)
            return length(ap - c) - rad; // exact circle
        vec2 q = (ap - c) / rad;
        float n2 = 2.0 * n - 2.0;
        float num = pow(q.x, n) + pow(q.y, n) - 1.0;
        float den = n * sqrt(pow(q.x, n2) + pow(q.y, n2)) + 0.0001;
        return num / den * rad;
    }
    vec2 q2 = ap - b + vec2(rad);
    return min(max(q2.x, q2.y), 0.0) + length(max(q2, 0.0)) - rad;
}

// Pill/box SDF honouring the shared smoothing uniform. f = 0 takes the
// legacy circular path untouched.
float sdPillBox4(vec2 p, vec2 b, vec4 r) {
    if (uSquircleF <= 0.0005)
        return sdRoundBox4(p, b, r);
    return sdSquircleBox4(p, b, r, 2.0 + 4.0 * uSquircleF);
}

float sdBox2(vec2 p, vec2 b) {
    vec2 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// Polynomial smooth-min (iquilez): exact min outside the k-band, rounded
// inside. For NORMALS ONLY: rounding the SDF ridge removes the medial-line
// direction flip; values stay on the exact union (see main), so refraction
// never swings.
float sminN(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// Notch flare SDF at an arbitrary pill-space point (same fillet as main:
// flare box INTERSECT outside-of-disc centered on the box outer-bottom
// corner). 1e9 sentinel = flare off -> union no-op.
float sdFlareOnly(vec2 q, vec2 halfPx, vec2 fl) {
    float sdFl = 1e9;
    if (fl.x > 0.01) {
        float f = fl.x;
        vec2 bc = vec2(-halfPx.x - f * 0.5, -halfPx.y + f * 0.5);
        vec2 cc = vec2(-halfPx.x - f, -halfPx.y + f);
        sdFl = min(sdFl, max(sdBox2(q - bc, vec2(f * 0.5)), f - length(q - cc)));
    }
    if (fl.y > 0.01) {
        float f = fl.y;
        vec2 bc = vec2(halfPx.x + f * 0.5, -halfPx.y + f * 0.5);
        vec2 cc = vec2(halfPx.x + f, -halfPx.y + f);
        sdFl = min(sdFl, max(sdBox2(q - bc, vec2(f * 0.5)), f - length(q - cc)));
    }
    return sdFl;
}

// Squircle notch flare: same fillet with the disc replaced by a
// superellipse of exponent n around the same outer-bottom corner (the
// zero-crossing — the visible silhouette — is exact; only far-field
// magnitudes are approximate, which the union/min structure tolerates).
float sdFlareSquOnly(vec2 q, vec2 halfPx, vec2 fl, float n) {
    float sdFl = 1e9;
    if (fl.x > 0.01) {
        float f = fl.x;
        vec2 bc = vec2(-halfPx.x - f * 0.5, -halfPx.y + f * 0.5);
        vec2 cc = vec2(-halfPx.x - f, -halfPx.y + f);
        sdFl = min(sdFl, max(sdBox2(q - bc, vec2(f * 0.5)), -sdSuperellipse(q - cc, n, f)));
    }
    if (fl.y > 0.01) {
        float f = fl.y;
        vec2 bc = vec2(halfPx.x + f * 0.5, -halfPx.y + f * 0.5);
        vec2 cc = vec2(halfPx.x + f, -halfPx.y + f);
        sdFl = min(sdFl, max(sdBox2(q - bc, vec2(f * 0.5)), -sdSuperellipse(q - cc, n, f)));
    }
    return sdFl;
}

// Flare SDF honouring the shared smoothing uniform (legacy arc at f = 0).
float sdFlareU(vec2 q, vec2 halfPx, vec2 fl) {
    if (uSquircleF <= 0.0005)
        return sdFlareOnly(q, halfPx, fl);
    return sdFlareSquOnly(q, halfPx, fl, 2.0 + 4.0 * uSquircleF);
}

float f_func(float x) {
    // Fast path: pow(c*M_E, y) = exp(y*log(c*M_E)); log part is uniform.
    // uLogCME<=0 means old CPU (unset uniform): fall back to pow.
    if (uLogCME > 0.0001)
        return 1.0 - uB * exp((-uD * x - uA) * uLogCME);
    return 1.0 - uB * pow(uC * M_E, -uD * x - uA);
}

float rand(vec2 co) {
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Photoshop-style overlay: 0.5 blend = identity, <0.5 deepens, >0.5 lifts,
// both with the contrast curve intact (unlike add/subtract, which flatten
// toward white/black). Hard step: the two branches meet continuously at
// base 0.5 (both yield the blend value), so no contour appears.
vec3 overlay(vec3 base, vec3 blend) {
    vec3 lo = 2.0 * base * blend;
    vec3 hi = 1.0 - 2.0 * (1.0 - base) * (1.0 - blend);
    return mix(lo, hi, step(vec3(0.5), base));
}

void main() {
    // uv spans the PILL (the draw quad is larger by the shadow margin;
    // uPad maps quad-uv back to pill-uv for all shape math).
    vec2 uv = (v_texcoord - uPad.xy) / uPad.zw;
    // Unscaled SDFs drive edge AA + shadow (pixel units); the scaled copies
    // below drive the refraction look (QML parity).
    vec2 pillPx = (uv - vec2(0.5)) * uBox;
    vec2 halfPx = uBox * 0.5;
    float sdPx;
    float dist;
    // Per-pixel edge normal for the glow (finite differences, set per branch
    // below). Falls back to top-light if the field degenerates.
    vec2 glowN = vec2(0.0, -1.0);
    // True-edge mask driver (0..1 across the bevel band below), set per branch.
    float glowIn = 0.0;
    // Bevel band width: the glow lives within this many px of the true edge
    // (log-curved like the bevel trio, halved). Shared by both shape modes.
    // PERF: precomputed on CPU (uBevW) to save a per-fragment log();
    // fallback computes it here for old CPUs that leave the uniform at 0.
    float bevW = (uBevW > 0.001) ? uBevW
        : max((7.0 + 3.5 * log(1.0 + min(uBox.x, uBox.y) / 30.0)) * 1.5, 4.0);
    if (uUsePill > 0.5) {
        sdPx = sdPillBox4(pillPx, halfPx, uRadii);
        vec2 p_px = pillPx * vec2(3.5) / vec2(max(uShape.x, 0.1), max(uShape.y, 0.1));
        float rMax = max(min(uBox.x, uBox.y) * 0.5, 1.0);
        dist = clamp(-sdPillBox4(p_px, halfPx, uRadii) / rMax, 0.0, 1.0);
        // Bevel-anchored band + proxy-rounded normals (see decl): kinks sit
        // outside the band, direction fades to neutral with depth anyway.
        vec4 pr = max(uRadii, vec4(bevW));
        float tgx = sdPillBox4(pillPx + vec2(1.0, 0.0), halfPx, pr) - sdPillBox4(pillPx - vec2(1.0, 0.0), halfPx, pr);
        float tgy = sdPillBox4(pillPx + vec2(0.0, 1.0), halfPx, pr) - sdPillBox4(pillPx - vec2(0.0, 1.0), halfPx, pr);
        glowN = vec2(tgx, tgy) / max(length(vec2(tgx, tgy)), 1e-4);
        glowIn = clamp(-sdPx / bevW, 0.0, 1.0);
    } else {
        vec2 p_super = (uv - vec2(0.5)) * 2.0;
        sdPx = sdSuperellipse(p_super, uPower, 1.0) * min(halfPx.x, halfPx.y);
        p_super *= vec2(3.5) / vec2(max(uShape.x, 0.1), max(uShape.y, 0.1));
        float sdS = sdSuperellipse(p_super, uPower, 1.0);
        if (sdS > 0.0)
            discard;
        dist = clamp(-sdS, 0.0, 2.0);
        // sdPx here is the unscaled silhouette-true field (px); super field
        // has no medial kinks except the masked-out center, so no proxy.
        float sse = 3.0 / max(min(uBox.x, uBox.y), 1.0);
        vec2 pSup0 = (uv - vec2(0.5)) * 2.0;
        float sgx = sdSuperellipse(pSup0 + vec2(sse, 0.0), uPower, 1.0) - sdSuperellipse(pSup0 - vec2(sse, 0.0), uPower, 1.0);
        float sgy = sdSuperellipse(pSup0 + vec2(0.0, sse), uPower, 1.0) - sdSuperellipse(pSup0 - vec2(0.0, sse), uPower, 1.0);
        glowN = vec2(sgx, sgy) / max(length(vec2(sgx, sgy)), 1e-4);
        glowIn = clamp(-sdPx / bevW, 0.0, 1.0);
    }
    // Notch flare shoulders (bar tabs): concave fillets, NOT convex discs.
    // Proof from the BarFlare path (start (F,F) -> CCW arc -> (0,0) -> line
    // (F,0) -> close): the arc meets the top edge horizontally and the tab
    // side vertically — tangent-smooth at both ends. Only an arc centered on
    // the flare box's OUTER-BOTTOM corner does that; a disc around the tab
    // corner would hit both edges perpendicularly (cusps) and bulge outward.
    // Fillet region = flare box INTERSECT outside-of-disc(center outer-bottom
    // corner), unioned into the silhouette. Same capture and quad as the tab,
    // so the background stays perfectly uniform. 0 size disables (1e9
    // sentinel keeps min()/max() exact no-ops).
    {
        float sdFl = sdFlareU(pillPx, halfPx, uFlare);
        sdPx = min(sdPx, sdFl);
        // Lens field: HARD max, deliberately. A polynomial smooth-min dips
        // below both inputs; near the fillet boundary that drags dist
        // negative, swinging refract 0.74 -> 0.47 — a ~20px warp line along
        // the tie curve (measured with the live A/B/C/D/FPower). The hard
        // union keeps displacement VALUES continuous (only the gradient
        // kinks: harmless for refraction, but directional shading gets its
        // normals from the sminN-rounded union below).
        float rMaxF = max(min(uBox.x, uBox.y) * 0.5, 1.0);
        dist = max(dist, clamp(-sdFl / rMaxF, 0.0, 1.0));
        // Glow normals/mask must see the FINAL silhouette (pill ∪ flares).
        // They were finite-differenced from the pill alone above, so inside
        // the fillets glowIn stayed ~0 and glowN pointed pill-ward — a
        // highlight seam along the tie curve. Re-difference the unioned
        // field when flares are live (proxy radii, same as above). Normals
        // use a ROUNDED union (sminN, k=3px): the hard union's interior
        // medial ridge flips the gradient direction, creasing any
        // directional shading along a line from the joint into the tab.
        // Values (sdPx, dist, masks) stay on the exact union, so refraction
        // and coverage never move — only the light direction relaxes.
        if (uUsePill > 0.5 && (uFlare.x > 0.01 || uFlare.y > 0.01)) {
            vec4 prF = max(uRadii, vec4(bevW));
            float kR = 3.0;
            float sXp = sminN(sdPillBox4(pillPx + vec2(1.0, 0.0), halfPx, prF), sdFlareU(pillPx + vec2(1.0, 0.0), halfPx, uFlare), kR);
            float sXn = sminN(sdPillBox4(pillPx - vec2(1.0, 0.0), halfPx, prF), sdFlareU(pillPx - vec2(1.0, 0.0), halfPx, uFlare), kR);
            float sYp = sminN(sdPillBox4(pillPx + vec2(0.0, 1.0), halfPx, prF), sdFlareU(pillPx + vec2(0.0, 1.0), halfPx, uFlare), kR);
            float sYn = sminN(sdPillBox4(pillPx - vec2(0.0, 1.0), halfPx, prF), sdFlareU(pillPx - vec2(0.0, 1.0), halfPx, uFlare), kR);
            vec2 gF = vec2(sXp - sXn, sYp - sYn);
            glowN = gF / max(length(gF), 1e-4);
            glowIn = clamp(-sdPx / bevW, 0.0, 1.0);
        }
    }
    float pillA = 1.0 - smoothstep(-1.0, 1.0, sdPx);
    // PERF (over-rim): interior pixels have rimA~0 (transparent) but would
    // still pay the full glass ALU below. Early-discard using sdPx alone:
    // rimT3>=8 => rimA==0 (see tail). Saves ~95% of over-rim fragments on
    // large windows (band-only vs fullscreen shading). Under-glass never
    // discards here (full pane visible).
    if (uOverRim > 0.5) {
        float rimT3early = clamp(-sdPx / max(bevW / 3.0, 1e-3), 0.0, 9.0);
        if (rimT3early >= 8.0)
            discard;
    }

    float fx = clamp(f_func(dist), 0.0, 2.0);
    // PERF: pow(x,1)==x fast path (default fPower=1 saves a transcendental).
    float refract = (abs(uFPower - 1.0) < 0.001) ? max(fx, 0.0001) : pow(max(fx, 0.0001), uFPower);
    vec2 p = (uv - vec2(0.5)) * 2.0;
    vec2 refractVec = p * (refract - 1.0) * 0.18;
    // Band-confined lens (windows): refraction lives in the glow band
    // (bevW) so the interior stays clean frosted glass. CA derives from
    // refractVec, so it follows automatically. Pills keep the full field.
    float lensMask = 1.0 - smoothstep(0.0, 1.0, clamp(-sdPx / bevW, 0.0, 1.0));
    refractVec *= mix(1.0, lensMask, uLensBand);

    // Pill-uv + refraction -> capture-uv. One mapping serves both textures
    // because the blur pyramid covers exactly the captured region.
    // (QML: refractVec * boxSize/screenSize; here uCapScale == uBox/uCapture.)
    vec2 sampleUV = uCapOrigin + uv * uCapScale + refractVec * uCapScale;
    sampleUV = clamp(sampleUV, vec2(0.001), vec2(0.999));

    // Sub-texel dither against banding (matches the QML original).
    vec2 resEff = vec2(textureSize(uBlur, 0));
    vec2 dither = vec2(hash(gl_FragCoord.xy * 0.009) - 0.5, hash(gl_FragCoord.xy * 0.011 + vec2(7.0, 13.0)) - 0.5) * 0.6 / max(resEff, vec2(1.0));
    vec2 buv = clamp(sampleUV + dither, vec2(0.001), vec2(0.999));
    vec4 bg = texture(uBlur, buv);
    // Over-rim progressive content blur (window edge overlay only, never the
    // regular pass): sharp at the true edge, ramping to the fixed r=3 /
    // 2-iteration chain at the band end. Normalized by bevW — the same width
    // that confines rimA — so the overlay's own band sets the ramp; no extra
    // width detection needed. uBlur already holds the r3 chain here.
    if (uRimBlur > 0.5) {
        // Over-rim frosted edge runs at 1/6 the bevel band width; the shared
        // bevW stays untouched (lens, glow and pill paths all key off it).
        float rimW = bevW / 6.0;
        float rimT = clamp(-sdPx / rimW, 0.0, 1.0);
        vec3 sharpC = texture(uSharp, buv).rgb;
        // Blend-mode composite (overlay, reusing the trio's overlay()):
        // content keeps its contrast at the extremes (readable) while the
        // frost tints the midtones — instead of normal-alpha cover, which
        // frosted text illegible. Sharp at the true edge, blending in with
        // depth like before. Glow below is untouched by design.
        bg.rgb = mix(sharpC, overlay(sharpC, bg.rgb), smoothstep(0.0, 0.3, rimT));
    }
    // Chromatic aberration: R/B sampled slightly apart along the refraction
    // vector (prism look), each tap itself box-blurred 2px (±1 and ±2 texel
    // ring) so the fringes stay soft. The separation scales with the
    // refraction vector, so it lives at the edges and vanishes at the
    // center — no whole-area hue shift (removed: it tinted flat regions).
    // NOTE: all three channels get the same box-blur below. Averaging only
    // R/B while keeping a sharp center-tap green turns white edges green
    // ((0.5, 1.0, 0.5) wherever dark neighbors dilute R/B), most visible
    // over high-contrast window content in the over-rim band.
    vec2 caVec = refractVec * uCapScale * (0.175 * uCA);
    // PERF: skip the 24-tap CA box when disabled (uCA~0) or when the
    // separation is sub-texel (interior pixels where refract~1). Saves 92%
    // of texture bandwidth there. ca=0 is now truly free (was 24 taps).
    // When skipped, rC/gC/bC track the center tap so the detail term below
    // sees zero contrast (detail==0, no visual change vs old box-at-0).
    float rC = bg.r, gC = bg.g, bC = bg.b;
    bool doCA = (uCA > 0.001) && (dot(caVec, caVec) > 2.5e-7);
    if (doCA) {
    vec2 tx = vec2(1.0 / max(float(textureSize(uBlur, 0).x), 1.0), 0.0);
    vec2 ty = vec2(0.0, 1.0 / max(float(textureSize(uBlur, 0).y), 1.0));
    vec2 rUv = clamp(buv + caVec, vec2(0.001), vec2(0.999));
    vec2 bUv = clamp(buv - caVec, vec2(0.001), vec2(0.999));
    rC = (texture(uBlur, clamp(rUv + tx, vec2(0.001), vec2(0.999))).r + texture(uBlur, clamp(rUv - tx, vec2(0.001), vec2(0.999))).r
                + texture(uBlur, clamp(rUv + ty, vec2(0.001), vec2(0.999))).r + texture(uBlur, clamp(rUv - ty, vec2(0.001), vec2(0.999))).r
                + texture(uBlur, clamp(rUv + tx * 2.0, vec2(0.001), vec2(0.999))).r
                + texture(uBlur, clamp(rUv - tx * 2.0, vec2(0.001), vec2(0.999))).r
                + texture(uBlur, clamp(rUv + ty * 2.0, vec2(0.001), vec2(0.999))).r
                + texture(uBlur, clamp(rUv - ty * 2.0, vec2(0.001), vec2(0.999))).r)
               * 0.125;
    bC = (texture(uBlur, clamp(bUv + tx, vec2(0.001), vec2(0.999))).b + texture(uBlur, clamp(bUv - tx, vec2(0.001), vec2(0.999))).b
                + texture(uBlur, clamp(bUv + ty, vec2(0.001), vec2(0.999))).b + texture(uBlur, clamp(bUv - ty, vec2(0.001), vec2(0.999))).b
                + texture(uBlur, clamp(bUv + tx * 2.0, vec2(0.001), vec2(0.999))).b
                + texture(uBlur, clamp(bUv - tx * 2.0, vec2(0.001), vec2(0.999))).b
                + texture(uBlur, clamp(bUv + ty * 2.0, vec2(0.001), vec2(0.999))).b
                + texture(uBlur, clamp(bUv - ty * 2.0, vec2(0.001), vec2(0.999))).b)
               * 0.125;
    // Green gets the identical box (centered, unshifted: luminance anchor).
    gC = (texture(uBlur, clamp(buv + tx, vec2(0.001), vec2(0.999))).g + texture(uBlur, clamp(buv - tx, vec2(0.001), vec2(0.999))).g
                + texture(uBlur, clamp(buv + ty, vec2(0.001), vec2(0.999))).g + texture(uBlur, clamp(buv - ty, vec2(0.001), vec2(0.999))).g
                + texture(uBlur, clamp(buv + tx * 2.0, vec2(0.001), vec2(0.999))).g
                + texture(uBlur, clamp(buv - tx * 2.0, vec2(0.001), vec2(0.999))).g
                + texture(uBlur, clamp(buv + ty * 2.0, vec2(0.001), vec2(0.999))).g
                + texture(uBlur, clamp(buv - ty * 2.0, vec2(0.001), vec2(0.999))).g)
               * 0.125;
    bg.rgb = vec3(rC, gC, bC);
    // Slight hue shift with the fringes (reds toward orange via green,
    // cyans toward blue by pulling green where blue dominates). Edge-bound
    // like the taps (scaled by uCA), never a whole-area tint.
    bg.g = mix(bg.g, bg.r, 0.10 * uCA);
    bg.g *= 1.0 - 0.10 * uCA * clamp(bg.b - bg.r, 0.0, 1.0);
    }
    float nDither = (hash(gl_FragCoord.xy * 0.007) - 0.5) * 0.015;
    bg.rgb += vec3(nDither);

    if (bg.a < 0.01) {
        bg = vec4(uBaseColor, 1.0);
    } else {
        float tint = clamp(uOpacity, 0.0, 1.0);
        // Detail-preserving tint: where the backdrop carries distinct shapes
        // (high local contrast between the CA box average and the center
        // tap), keep the sharp backdrop and skip the frost instead of
        // washing it out. Content-adaptive, so dark and light modes need no
        // separate handling; the tint color itself already follows matugen.
        float lumC = dot(bg.rgb, vec3(0.299, 0.587, 0.114));
        float lumN = dot(vec3(rC, gC, bC), vec3(0.299, 0.587, 0.114));
        float detail = clamp(abs(lumC - lumN) * 2.5, 0.0, 1.0) * uDetail;
        bg = mix(bg, vec4(uBaseColor, 1.0), tint * 0.28 * (1.0 - detail));
        bg.a = 1.0;
    }

    vec3 n = vec3(0.0);
    // PERF: 3x sin() for film grain — skip entirely when uNoise~0 (prefs
    // default 0). Was 3 transcendentals per fragment for invisible output.
    if (uNoise > 0.0005) {
        n = vec3(rand(gl_FragCoord.xy * 0.009) - 0.5, rand(gl_FragCoord.xy * 0.013 + vec2(17.0, 31.0)) - 0.5,
                 rand(gl_FragCoord.xy * 0.011 + vec2(43.0, 7.0)) - 0.5);
        bg.rgb += n * uNoise * 3.5;
    }

    // Bipolar diagonal bevel glow: |sin| gives two identical poles with a
    // true-zero node between them; +PI/4 puts the axis, sign flipped for -45deg on the diagonal.
    // Direction fades to neutral with depth (kdir), mask keeps the slider
    // ramp (defaults peak 0.5 at the rim, zero at the band edge).
    // Layer 1 (multiplicative, kept) + layer 2 (plain white additive, 33%).
    // PERF: atan+sin per fragment — skip entirely when weight~0 and bias~0
    // (was still shading + additive highlight even with weight 0).
    if (abs(uGlowW) > 0.001 || abs(uGlowB) > 0.001) {
    float graw = abs(sin(atan(glowN.y, glowN.x) - 0.5 - 0.4363323129));
    // Narrow the bright caps so the non-glowing remainder dominates (~3-4x
    // area): soft threshold with peak-preserving rescale, eased so no hard
    // isoline appears at the cut.
    float gcap = clamp((graw - uGlowT) / max(1.0 - uGlowT, 1e-3), 0.0, 1.0);
    gcap = gcap * gcap * (3.0 - 2.0 * gcap);
    float kdir = 1.0 - smoothstep(0.0, 1.0, glowIn);
    float g = mix(0.0, gcap, kdir);
    float edgeMask = 1.0 - smoothstep(uGlowE1, uGlowE0, glowIn * 0.5);
    float glow = g * uGlowW * edgeMask + 1.0 + uGlowB;
    bg.rgb *= glow;
    bg.rgb += vec3(1.0) * (g * edgeMask) * 0.33;
    } // end glow early-out (weight~0 && bias~0: identity, no highlight)

    // Log-curved edge widths: small pills get relatively generous rims that
    // stop growing on large ones. Steep early rise + low ceiling: 35px->~10,
    // 200px->~14, 560px->~17 (a pure log from zero starves small pills).
    // x3 softness on the whole bevel trio (sheen/rim/inner shade): the dark
    // inner shade reads as a contour offset from the edge, so all three
    // widen together to keep the material coherent.
    float rMaxPx = max(min(uBox.x, uBox.y) * 0.5, 1.0);
    // x9.0 softness (was x3.0, then x4.5): the top/rim/edge trio below all
    // derive from this one width, so the whole bevel relaxes together.
    // PERF: precomputed on CPU (uEdgePx) to save a per-fragment log().
    float edgePx = (uEdgePx > 0.001) ? uEdgePx
        : (7.0 + 3.5 * log(1.0 + min(uBox.x, uBox.y) / 30.0)) * 9.0;
    float distPx = dist * rMaxPx;
    // The three static glass components — top-down sheen, outer bevel, inner
    // shade — composited as ONE overlay layer (0.5 = neutral). Same masks and
    // relative strengths as the old add/subtract math; overlay lifts/deepens
    // around the backdrop instead of flattening toward white/black, so the
    // coefficients are doubled (at midtones overlay moves half as far per
    // unit blend: base + t*0.5 at base 0.5).
    float top = smoothstep(0.0, edgePx * 0.8, distPx) * (1.0 - smoothstep(0.0, 0.60, uv.y)) * refract;
    float rim = smoothstep(0.0, edgePx * 0.15, distPx) - smoothstep(edgePx * 0.15, edgePx * 0.5, distPx);
    float edge = smoothstep(0.0, edgePx * 0.5, distPx) - smoothstep(edgePx * 0.5, edgePx * 1.0, distPx);
    float hi = top * 0.20 + rim * 0.10 * refract;
    // DIAGNOSTIC: inner-shade gain at 10% (0.0054 vs 0.054) — if the dark
    // offset contour fades, this band is the culprit; restore after.
    float lo = edge * 0.0054 * (1.0 - refract * 0.5);
    bg.rgb = overlay(bg.rgb, clamp(vec3(0.5) + vec3(hi - lo) * 0.5, 0.0, 1.0));
    bg.rgb = clamp(bg.rgb, 0.0, 1.0);
    // Full opacity means fully opaque: above the default the glass eases to
    // flat base color, reaching zero visible effect at 1.0. At/below the
    // default this is exactly 0, so the current look is pixel-identical.
    float fullness = smoothstep(0.82, 1.0, clamp(uOpacity, 0.0, 1.0));
    bg.rgb = mix(bg.rgb, uBaseColor, fullness);
    // Drop shadow, cast by the same shape (offset down by default). Mixed
    // under the glass so pills float; replaces the QML MultiEffect shadows,
    // which would blob around glyphs once the QML background is transparent.
    //
    // Deliberately CIRCULAR (legacy SDFs), not squircle: the superellipse
    // corner approximation underestimates far-field distance, which
    // compresses the exp falloff outward until it hits the draw-quad edge
    // with visible alpha - a hard cutoff. A 50px+ blur cannot resolve
    // circle-vs-squircle anyway, so the shadow keeps the exact SDF while
    // the silhouette, glow and refraction stay squircle.
    // PERF: skip SDF+exp when shadow effectively off (alpha~0).
    float shA = 0.0;
    float sdS = 1e9;
    if (uShadowA > 0.003) {
    sdS = sdRoundBox4(pillPx - uShadowOff, halfPx, uRadii);
    // Notch fillets cast with the tab (same union, shifted with the offset).
    {
        vec2 sp = pillPx - uShadowOff;
        float sdFlSh = sdFlareOnly(sp, halfPx, uFlare);
        sdS = min(sdS, sdFlSh);
    }
    // (superellipse widgets reuse the pill SDF for shadows — close enough that
    //  no widget uses it today; see README non-goals.)
    shA = exp(-max(sdS, 0.0) / max(uShadowBlur, 1.0)) * uShadowA;
    }
    vec3 col = mix(uShadowColor, bg.rgb, pillA);
    // Full-strength effects inside the pill: the output IS the processed
    // backdrop (blur + refraction + noise), never a blend with the raw
    // framebuffer. Only the TINT carries opacity (uOpacity in the mix
    // above); the opacity slider must never fade the effects themselves.
    // Over-rim mode (drawn on top of the window): no shadow. Alpha is a
    // PLATEAU across the band (edge AA aside): full from the edge to the
    // band end where the progressive blur reaches r3, then cut just past
    // it — so the frosted edge shows, and the interior stays clean content.
    // (An inward-decaying alpha hides the blurred pixels, leaving sharp +
    // CA fringe; a flat pillA leaks blur over the whole window.)
    float rimT2 = clamp(-sdPx / bevW, 0.0, 3.0);
    float rimA = (1.0 - smoothstep(0.0, 1.0, rimT2)) * pillA;
    // Long soft tail back to clean content (no hard inner edge), measured
    // in thirds of the bevel band like the ramp above: full through the
    // band end, feathered out to 8 band-thirds (double reach).
    float rimT3 = clamp(-sdPx / (bevW / 3.0), 0.0, 9.0);
    rimA = mix(rimA, (1.0 - smoothstep(1.0, 8.0, rimT3)) * pillA, uRimBlur);
    // Regular-window border effect runs at 25% overall opacity (over-rim
    // only — pills and under-glass take the unscaled branch).
    float a = mix(clamp(shA * (1.0 - pillA) + pillA, 0.0, 1.0), rimA * 0.25, uOverRim);
    // PERF: discard fully transparent fragments (shadow margin + over-rim
    // interior) to save blending + downstream compositing. No visual change
    // (alpha~0 was invisible anyway).
    if (a <= 0.003)
        discard;
    fragColor = vec4(col, a);
}
