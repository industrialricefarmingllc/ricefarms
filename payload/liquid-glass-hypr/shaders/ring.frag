#version 300 es
precision highp float;

// ring.frag — liquid glass for Hyprland window borders.
//
// The refraction is the ORIGINAL glass lens, evaluated over the whole window
// pane exactly like a pill (same f_func curve, same shape math): the band
// shows the rim of the pane's field, where the displacement is strongest.
// Only the displayed area differs (band vs pill), never the field itself.
// The curve reuses the pill keys (one material); D alone is border-owned
// (uLD, border_d) because rims want a steeper profile than pill bodies.

in vec2 v_texcoord; // spans the DRAW quad (== captured region)
layout(location = 0) out vec4 fragColor;

uniform sampler2D uBlur;  // half-res capture of the draw quad region

uniform vec4  uInner;     // inner (window) box x,y,w,h, fb px in quad space
uniform vec2  uQuadSize;  // draw quad size, fb px (== captured region)
uniform float uThick;     // scaled border thickness, fb px
uniform float uRound;     // outer corner radius, fb px
uniform vec3  uTint;      // border gradient color 1 (sRGB 0..1)
uniform vec3  uTint2;     // border gradient color 2 (animated fades)
uniform float uLerp;      // gradient 1->2 mix
uniform float uTintMix;   // tint strength (the shared opacity setting)
uniform float uA;         // fade alpha from the border data
uniform float uThrow;     // max lens throw, fb px (<= capture bleed)
uniform vec2  uWinSize;   // window (inner box) size, fb px
uniform float uWinR;      // window corner radius, fb px (windows path)
uniform vec4  uWinRadii;  // inner lens radii tl,tr,br,bl, fb px (pill path)
uniform vec4  uRadii;     // outer radii tl,tr,br,bl, fb px (pill path)
uniform float uUseRadii;  // 0 = single uRound (windows), 1 = vec4 uRadii (layers)
uniform float uFadeTop;   // fade: alpha mult at one end (axis -dir)
uniform float uFadeMid;   // fade: alpha mult at center
uniform float uFadeBottom;// fade: alpha mult at other end (axis +dir)
uniform float uFadeAngle; // fade axis rotation, degrees (0 = vertical)
uniform vec2  uFlare;     // notch flare shoulders (left, right), fb px, 0 = off
uniform float uPush;      // band outward push: 0.5 windows, 0.0 layer pills
uniform float uSquircleF; // shared corner smoothing 0..1 (0 = circular, must match glass.frag + QML)
uniform vec3  uShadowColor; // drop shadow color (matugen hue, like pills)
uniform float uShadowA;   // drop shadow strength (0 = off, e.g. layer rings)
uniform vec2  uShadowOff; // shadow cast offset, fb px
uniform float uShadowBlur;// shadow softness, fb px
uniform vec2  uShape;     // glassWidth, glassHeight (pill keys)
uniform float uLA;
uniform float uLB;
uniform float uLC;
uniform float uLD;        // border-owned D (border_d, default 30)
uniform float uLFPower;
uniform float uGlowW;     // angular glow: pill keys (one material)
uniform float uGlowE0;
uniform float uGlowE1;
uniform float uGlowT;     // bright-cap threshold (0 = old full-lobe look)
uniform float uGlowBias;  // ...except the bias, which is border-owned
uniform float uFrameEnable; // picture-frame relief master switch (0/1)
uniform float uFrameScale;  // motif period scale (1 = default px periods)
uniform float uSeed;        // per-window hash 0..1 (fixed when seed_mode=0)
uniform float uFrieze;      // -1 auto, 0 egg-and-dart, 1 key, 2 guilloche, 3 fluting
uniform float uGilt;        // gilt strength: 0 carved stone .. 1 full gilt
uniform float uRelief;      // emboss strength (refraction + bevel modulation)

const float M_E = 2.718281828459045;

float sdRoundBox(vec2 p, vec2 halfSize, float r) {
    vec2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
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

// Superellipse SDF (same as glass.frag): the squircle corner arc.
// n = 2 is exactly the circle; n = 2 + 4*f, so f = 0.5 is the classic n = 4.
float sdSuperellipse(vec2 p, float n, float r) {
    vec2 pa = abs(p);
    float num = pow(pa.x, n) + pow(pa.y, n) - pow(r, n);
    float den = n * sqrt(pow(pa.x, 2.0 * n - 2.0) + pow(pa.y, 2.0 * n - 2.0)) + 0.00001;
    return num / den;
}

// Squircle rounded box: same quadrant-picked radii as sdRoundBox4, corner
// arc is a superellipse of exponent n. Reduces exactly to sdRoundBox4 at
// n = 2; radius-0 corners take the exact box path.
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

// Layer-pill box SDF honouring uSquircleF (must match glass.frag's
// sdPillBox4 exactly, or the 1px ring sits off the glass edge leaving a
// backdrop hairline — most visible along the notch fillets). Windows
// (uUseRadii == 0) stay circular: Hyprland rounding is circular.
float sdPillBox4(vec2 p, vec2 b, vec4 r) {
    if (uSquircleF <= 0.0005)
        return sdRoundBox4(p, b, r);
    return sdSquircleBox4(p, b, r, 2.0 + 4.0 * uSquircleF);
}

// Same overlay as glass.frag (0.5 = neutral): the bevel/shade/sheen trio
// below must composite identically to the pills' or the two will never
// read as one material.
vec3 overlay(vec3 base, vec3 blend) {
    vec3 lo = 2.0 * base * blend;
    vec3 hi = 1.0 - 2.0 * (1.0 - base) * (1.0 - blend);
    return mix(lo, hi, step(vec3(0.5), base));
}

// --- neoclassical picture-frame relief -------------------------------------
// Heightfield h(s,t): s = fb px along the edge, t = 0 outer -> 1 inner.
// Fully procedural (no assets): stacked courses across the band, corner
// rosettes at the mitres (classic frame joinery: straight rails + corner
// blocks, so running frets never stretch around corners). All steps
// fwidth-AA'd to stay clean at any monitor scale.
float frHash(float n) { return fract(sin(n) * 43758.5453); }

float sdBox2(vec2 p, vec2 b) {
    vec2 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// Polynomial smooth-min for NORMALS ONLY (see glass.frag): exact min
// outside the k-band, so the interior medial ridge of a hard union stops
// flipping the glow direction along a visible line.
float sminN(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// Lens-field SDF at a window-space point, for the per-pixel glow normal.
// Reads the same uniforms as main so the differences stay in window space.
// Layer path honours uSquircleF (must match the glass body lens field).
float sdLensAt(vec2 wpx) {
    vec2 sp = wpx * vec2(3.5) / vec2(max(uShape.x, 0.1), max(uShape.y, 0.1));
    return (uUseRadii > 0.5) ? sdPillBox4(sp, uWinSize * 0.5, uWinRadii)
                             : sdRoundBox(sp, uWinSize * 0.5, uWinR);
}

// Notch flare fillet in window space (fb px, exact): same concave fillet as
// glass.frag (flare box INTERSECT outside-of-disc about the box outer-bottom
// corner), relative to the inner (window) box. 1e9 = off -> union no-op.
// Squircle-aware: with uSquircleF live the disc becomes the same
// superellipse the glass body uses, or the ring's fillet sits up to ~19%
// off the glass fillet at the diagonal — a backdrop wedge between them.
float sdFlareWin(vec2 wpx, vec2 winSize, vec2 fl) {
    vec2 halfW = winSize * 0.5;
    float sdFl = 1e9;
    float n = 2.0 + 4.0 * uSquircleF;
    bool squ = uSquircleF > 0.0005;
    if (fl.x > 0.01) {
        float f = fl.x;
        vec2 bc = vec2(-halfW.x - f * 0.5, -halfW.y + f * 0.5);
        vec2 cc = vec2(-halfW.x - f, -halfW.y + f);
        float disc = squ ? -sdSuperellipse(wpx - cc, n, f) : (f - length(wpx - cc));
        sdFl = min(sdFl, max(sdBox2(wpx - bc, vec2(f * 0.5)), disc));
    }
    if (fl.y > 0.01) {
        float f = fl.y;
        vec2 bc = vec2(halfW.x + f * 0.5, -halfW.y + f * 0.5);
        vec2 cc = vec2(halfW.x + f, -halfW.y + f);
        float disc = squ ? -sdSuperellipse(wpx - cc, n, f) : (f - length(wpx - cc));
        sdFl = min(sdFl, max(sdBox2(wpx - bc, vec2(f * 0.5)), disc));
    }
    return sdFl;
}

// Lens-space union of the pill lens and the flare (for glow normals/dist):
// the Win-space flare SDF scaled into lens units (exact for the default
// isotropic 3.5 shape keys, close otherwise). Flare off -> sdLensAt exactly.
float sdLensUnionAt(vec2 wpx) {
    float base = sdLensAt(wpx);
    if (uFlare.x <= 0.01 && uFlare.y <= 0.01)
        return base;
    float lensScale = 3.5 / max((uShape.x + uShape.y) * 0.5, 0.1);
    return min(base, sdFlareWin(wpx, uWinSize, uFlare) * lensScale);
}

// Rounded lens union for glow normals: same field through sminN so the
// medial ridge between pill and fillet relaxes instead of flipping the
// light direction along the joint. Flare off -> sdLensAt exactly.
float sdLensRoundAt(vec2 wpx, float k) {
    float base = sdLensAt(wpx);
    if (uFlare.x <= 0.01 && uFlare.y <= 0.01)
        return base;
    float lensScale = 3.5 / max((uShape.x + uShape.y) * 0.5, 0.1);
    return sminN(base, sdFlareWin(wpx, uWinSize, uFlare) * lensScale, k);
}

// Perimeter coordinate for the running motifs + corner rosette frame.
// Straight runs use the nearest-edge coordinate (exact on rails); the
// rosette mask covers the corner arcs/discs and hides the mitre seams.
void frameST(vec2 p, out float s, out vec2 nOut, out vec2 tanV,
             out float cornerM, out vec2 fcc, out float frMid) {
    vec2 o0 = uInner.xy - vec2(uThick);
    vec2 o1 = uInner.xy + uInner.zw + vec2(uThick);
    vec2 mid = (o0 + o1) * 0.5;
    float dL = p.x - o0.x, dR = o1.x - p.x;
    float dT = p.y - o0.y, dB = o1.y - p.y;
    bool horiz = (min(dT, dB) < min(dL, dR));
    if (horiz) {
        nOut = (dT < dB) ? vec2(0.0, -1.0) : vec2(0.0, 1.0);
        tanV = vec2(1.0, 0.0);
        s = p.x;
    } else {
        nOut = (dL < dR) ? vec2(-1.0, 0.0) : vec2(1.0, 0.0);
        tanV = vec2(0.0, 1.0);
        s = p.y;
    }
    float R = max(uRound, 1.0);
    vec2 cc = vec2((p.x < mid.x) ? o0.x + R : o1.x - R,
                   (p.y < mid.y) ? o0.y + R : o1.y - R);
    float rMid = max(R - uThick * 0.5, 1.0);
    float rRos = uThick * 1.45 + 2.0;
    float ringM = 1.0 - smoothstep(rRos * 0.65, rRos, abs(length(p - cc) - rMid));
    // Square corners (R ~ 0): fan rosette at the corner point instead.
    vec2 cp = vec2((p.x < mid.x) ? o0.x : o1.x, (p.y < mid.y) ? o0.y : o1.y);
    float discM = 1.0 - smoothstep(rRos * 0.65, rRos, length(p - cp));
    float sq = step(R, uThick * 0.75);
    cornerM = clamp(mix(ringM, discM, sq), 0.0, 1.0);
    fcc = mix(cc, cp, sq);
    frMid = mix(rMid, 0.0, sq);
}

float courseW(float t, float t0, float t1) {
    return clamp((t - t0) / max(t1 - t0, 1e-4), 0.0, 1.0);
}

// Running relief body: moulding profile + MAIN course (0 egg-and-dart,
// 1 greek key, 2 guilloche, 3 fluting) + bead-and-reel + dentils. Courses
// are fractions of t so the stack fits any band thickness; periods derive
// from uThick so cells keep honest (near-square) proportions at any border
// width or monitor scale. Deliberately bold: gallery bands carve, not whisper.
float runBody(float s, float t, float seed, float frieze, float sc, float thick) {
    float aaS = 1.4;
    // Base moulding profile: outer ovolo swell, deep scotia, tall sight-edge.
    float h = 0.28
        + 0.30 * smoothstep(0.0, 0.10, t) * (1.0 - smoothstep(0.10, 0.18, t))
        + 0.42 * smoothstep(0.86, 0.97, t);
    h -= 0.26 * smoothstep(0.60, 0.66, t) * (1.0 - smoothstep(0.66, 0.72, t));
    // MAIN course, t in [0.10,0.60]: half the band, room to breathe.
    {
        float v = courseW(t, 0.10, 0.60);
        float inBand = smoothstep(0.0, 0.10, v) * (1.0 - smoothstep(0.90, 1.0, v));
        float mh = 0.0;
        if (frieze < 0.5) {
            float P = max(thick * 0.95, 8.0) * sc;
            float u = fract(s / P + seed * 3.0);
            float aa = aaS / P;
            vec2 e = vec2((u - 0.5) / 0.30, (v - 0.52) / 0.34);
            mh = 0.85 * (1.0 - smoothstep(0.80 - aa * 3.0, 0.80 + aa * 3.0, length(e)));
            float db = min(u, 1.0 - u) * P;
            mh += 0.65 * ((1.0 - smoothstep(1.4 - aaS, 1.4 + aaS, db))
                * smoothstep(0.04, 0.22, v) * (1.0 - smoothstep(0.72, 0.95, v)));
        } else if (frieze < 1.5) {
            float P = max(thick * 1.5, 14.0) * sc;
            vec2 ku = vec2(fract(s / P + seed), v);
            float aa = aaS / P;
            float w = 0.12;
            float dm = sdBox2(ku - vec2(0.5, 0.86), vec2(0.40, w));
            dm = min(dm, sdBox2(ku - vec2(0.16, 0.48), vec2(w, 0.40)));
            dm = min(dm, sdBox2(ku - vec2(0.44, 0.12), vec2(0.40, w)));
            dm = min(dm, sdBox2(ku - vec2(0.70, 0.46), vec2(w, 0.36)));
            dm = min(dm, sdBox2(ku - vec2(0.52, 0.66), vec2(0.20, w)));
            mh = 0.80 * (1.0 - smoothstep(-aa * 2.0, aa * 2.0, dm));
        } else if (frieze < 2.5) {
            float P = max(thick * 1.6, 14.0) * sc;
            float ph = s * 6.2831853 / P + seed * 17.0;
            float g1 = sin(ph + v * 4.6);
            float g2 = sin(ph - v * 4.6 + 3.1415927);
            mh = 0.80 * smoothstep(0.45, 0.9, abs(g1 * g2) * 2.0);
        } else {
            float P = max(thick * 0.55, 6.0) * sc;
            mh = 0.80 * (0.5 + 0.5 * sin(s * 6.2831853 / P + seed * 9.0));
        }
        h += inBand * mh;
    }
    // Bead-and-reel divider, t in [0.61,0.70].
    {
        float P = max(thick * 0.60, 6.0) * sc;
        float cell = floor(s / P + seed * 7.0);
        float u = fract(s / P + seed * 7.0);
        float aa = aaS / P;
        float v = courseW(t, 0.61, 0.70);
        float inBand = smoothstep(0.0, 0.2, v) * (1.0 - smoothstep(0.8, 1.0, v));
        float bead = 1.0 - smoothstep(0.30 - aa * 2.0, 0.30 + aa * 2.0,
            length(vec2((u - 0.5) * 1.6, (v - 0.5) * 1.1)));
        float reel = 1.0 - smoothstep(0.16 - aa, 0.16 + aa,
            length(vec2((u - 0.5) * 2.6, (v - 0.5) * 0.9)));
        h += inBand * mix(0.60 * reel, 0.70 * bead, step(0.5, frHash(cell * 1.7 + seed)));
    }
    // Dentils, t in [0.71,0.90]: chunky square rhythm.
    {
        float P = max(thick * 0.45, 5.0) * sc;
        float u = fract(s / P + seed * 5.0);
        float aa = aaS / P + 1e-4;
        float v = courseW(t, 0.71, 0.90);
        float inBand = smoothstep(0.0, 0.15, v) * (1.0 - smoothstep(0.85, 1.0, v));
        h += inBand * (0.70 * (1.0 - smoothstep(0.52 - aa, 0.52 + aa, u)));
    }
    return clamp(h, 0.0, 1.8);
}

// Corner rosette / palmette fan: radial petals on the mid-band arc.
float rosette(vec2 p, vec2 cc, float rMid, float wHalf, float seed) {
    vec2 q = p - cc;
    float r = length(q);
    float ang = atan(q.y, q.x);
    float bandM = 1.0 - smoothstep(wHalf * 0.6, wHalf, abs(r - rMid));
    float petals = 0.5 + 0.5 * sin(ang * 8.0 + seed * 20.0);
    float bead = 1.0 - smoothstep(1.0, 2.5, abs(r - rMid));
    return bandM * (0.35 + 0.45 * petals) + bead * 0.5;
}

void main() {
    vec2 p = v_texcoord * uQuadSize;

    vec2 outerSize = uInner.zw + 2.0 * uThick;
    vec2 center = uInner.xy + uInner.zw * 0.5;
    // Layer pills honour uSquircleF (must match the glass body exactly);
    // windows stay circular (Hyprland rounding is circular).
    float sd = (uUseRadii > 0.5) ? sdPillBox4(p - center, outerSize * 0.5, uRadii)
                                 : sdRoundBox(p - center, outerSize * 0.5, uRound);

    // Outward push: windows sit the band on their own edge pixels (0.5 splits
    // the difference); layer pills have only backdrop underneath, so any push
    // leaves a visible backdrop hairline between glass and ring (uPush=0).
    float push = uPush;
    // Frame select + SILHOUETTE: the carving reshapes the band itself like
    // a real picture-frame moulding — rolling outer edge, dentil-stepped
    // inner edge. Cheap perimeter waves here; the full relief shades below.
    float frSel = (uFrieze < -0.5) ? floor(frHash(uSeed * 7.13) * 3.999)
                                   : clamp(uFrieze, 0.0, 3.0);
    if (uThick < 14.0) frSel = 3.0; // thin-band LOD: fluting only
    float fsc = max(uFrameScale, 0.25);
    float frameOn = (uFrameEnable > 0.5 && uThick >= 6.0) ? 1.0 : 0.0;
    float fs = 0.0; vec2 fn = vec2(0.0); vec2 ft = vec2(1.0, 0.0);
    float fcm = 0.0; vec2 fcc = vec2(0.0); float frMid = 0.0;
    if (frameOn > 0.5) {
        frameST(p, fs, fn, ft, fcm, fcc, frMid);
        float pMain = (frSel < 0.5) ? max(uThick * 0.95, 8.0)
                    : (frSel < 1.5) ? max(uThick * 1.5, 14.0)
                    : (frSel < 2.5) ? max(uThick * 1.6, 14.0)
                    : max(uThick * 0.55, 6.0);
        pMain *= fsc;
        float ow = 0.5 + 0.5 * sin(fs * 6.2831853 / pMain + uSeed * 18.85);
        float pDent = max(uThick * 0.45, 5.0) * fsc;
        float iw = smoothstep(0.40, 0.60, fract(fs / pDent + uSeed * 5.0));
        float sAmp = 1.1 + 1.2 * clamp(uRelief, 0.0, 2.0);
        float d0 = clamp((push - sd) / max(uThick, 1e-3), 0.0, 1.0);
        float silh = mix((ow - 0.5) * 2.0 * sAmp, (iw - 0.5) * 2.4 * sAmp, d0);
        sd -= silh * (1.0 - clamp(fcm, 0.0, 1.0)); // rosettes own the corners
    }
    // Notch flare shoulders (bar tabs): concave fillets (see glass.frag for
    // the tangency proof), unioned into the ring SDF so the 1px frame
    // follows the whole notch silhouette uniformly — one shape, one frame,
    // no start points, no missing segments. Flares off -> 1e9 -> no-op.
    // Squircle-aware (same superellipse as the glass body): a circular
    // ring fillet sits up to ~19% off a squirclish glass fillet at the
    // diagonal, opening a backdrop wedge between glass edge and frame —
    // the visible seam between notch and inverted corner.
    {
        float sdFlR = 1e9;
        float nR = 2.0 + 4.0 * uSquircleF;
        bool squR = uSquircleF > 0.0005;
        if (uFlare.x > 0.01) {
            float f = uFlare.x;
            vec2 bc = vec2(uInner.x - f * 0.5, uInner.y + f * 0.5);
            vec2 cc = vec2(uInner.x - f, uInner.y + f);
            float disc = squR ? -sdSuperellipse(p - cc, nR, f) : (f - length(p - cc));
            sdFlR = min(sdFlR, max(sdBox2(p - bc, vec2(f * 0.5)), disc));
        }
        if (uFlare.y > 0.01) {
            float f = uFlare.y;
            vec2 bc = vec2(uInner.x + uInner.z + f * 0.5, uInner.y + f * 0.5);
            vec2 cc = vec2(uInner.x + uInner.z + f, uInner.y + f);
            float disc = squR ? -sdSuperellipse(p - cc, nR, f) : (f - length(p - cc));
            sdFlR = min(sdFlR, max(sdBox2(p - bc, vec2(f * 0.5)), disc));
        }
        sd = min(sd, sdFlR);
    }
    float aa = fwidth(sd) * 0.5 + 1e-4;
    float inOuter = 1.0 - smoothstep(push - aa, push + aa, sd);
    float inInner = smoothstep(-uThick + push - aa, -uThick + push + aa, sd);
    float band = inOuter * inInner;

    // Fade axis (shared by ring + shadow): rotated top -> mid -> bottom.
    vec2 wuv = (p - uInner.xy) / uWinSize;
    float fang = radians(uFadeAngle);
    vec2 fdir = vec2(sin(fang), cos(fang));
    vec2 fpx = (wuv - vec2(0.5)) * uWinSize;
    float fmax = max(0.5 * (abs(uWinSize.x * fdir.x) + abs(uWinSize.y * fdir.y)), 1e-4);
    float wy = clamp(dot(fpx, fdir) / fmax * 0.5 + 0.5, 0.0, 1.0);
    float vf = (wy < 0.5) ? mix(clamp(uFadeTop, 0.0, 1.0), clamp(uFadeMid, 0.0, 1.0), wy * 2.0)
                          : mix(clamp(uFadeMid, 0.0, 1.0), clamp(uFadeBottom, 0.0, 1.0), (wy - 0.5) * 2.0);

    // Drop shadow (same material as pills): exp falloff outside the outer
    // shape, cast by uShadowOff. Masked to outside-only so it never darkens
    // the window interior. uShadowA = 0 disables (layer rings: the glass
    // pass already shadows the pill).
    // PERF: skip SDF+exp when shadow effectively off (alpha~0).
    float shA = 0.0;
    if (clamp(uShadowA, 0.0, 1.0) > 0.003) {
    float sdSh = (uUseRadii > 0.5) ? sdPillBox4(p - center - uShadowOff, outerSize * 0.5, uRadii)
                                   : sdRoundBox(p - center - uShadowOff, outerSize * 0.5, uRound);
    shA = exp(-max(sdSh, 0.0) / max(uShadowBlur, 1.0)) * clamp(uShadowA, 0.0, 1.0);
    shA *= smoothstep(push - aa, push + aa, sd);
    }
    if (band <= 0.001) {
        if (shA <= 0.003)
            discard;
        fragColor = vec4(uShadowColor, shA * vf);
        return;
    }

    // Original lens over the whole pane: window-uv through f_func, displaced
    // like a pill, throw capped to the capture bleed. The draw quad IS the
    // capture region, so quad-px / quad-size == capture uv.
    vec2 winPx = (wuv - vec2(0.5)) * uWinSize;
    vec2 sp = winPx * vec2(3.5) / vec2(max(uShape.x, 0.1), max(uShape.y, 0.1));
    float rMax = max(min(uWinSize.x, uWinSize.y) * 0.5, 1.0);
    float sdLens = (uUseRadii > 0.5) ? sdPillBox4(sp, uWinSize * 0.5, uWinRadii)
                                     : sdRoundBox(sp, uWinSize * 0.5, uWinR);
    float dist = clamp(-sdLens / rMax, 0.0, 1.0);
    // Per-pixel lens-field normal (finite differences — derivatives facet).
    // The lens field is smooth and outward throughout the band, unlike the
    // band SDF (flips mid-band) or the center offset (singular).
    // Flare-aware when shoulders are live: the pill-only lens reads dist 0
    // and pill-ward normals inside the fillets, stepping the refraction and
    // the glow direction along the tie curve (the visible joint seam).
    // Flare off -> sdLensUnionAt is sdLensAt exactly, pixel-identical.
    // Normals go through the ROUNDED union: the hard union's medial ridge
    // would still flip the light direction along a line into the tab.
    // PERF: normals (4x SDF) only feed the glow below — skip when glow off.
    vec2 glowN = vec2(0.0, -1.0);
    bool doGlow = (abs(uGlowW) > 0.001 || abs(uGlowBias) > 0.001);
    if (doGlow) {
    float lgx = sdLensRoundAt(winPx + vec2(1.0, 0.0), 3.0) - sdLensRoundAt(winPx - vec2(1.0, 0.0), 3.0);
    float lgy = sdLensRoundAt(winPx + vec2(0.0, 1.0), 3.0) - sdLensRoundAt(winPx - vec2(0.0, 1.0), 3.0);
    glowN = vec2(lgx, lgy) / max(length(vec2(lgx, lgy)), 1e-4);
    }
    if (uFlare.x > 0.01 || uFlare.y > 0.01) {
        float sdFlW = sdFlareWin(winPx, uWinSize, uFlare);
        dist = max(dist, clamp(-sdFlW / rMax, 0.0, 1.0));
    }
    float fx = clamp(1.0 - uLB * pow(uLC * M_E, -uLD * dist - uLA), 0.0, 2.0);
    float refract = pow(max(fx, 0.0001), uLFPower);
    vec2 rvec = (wuv - vec2(0.5)) * 2.0 * (refract - 1.0) * 0.18;
    vec2 dispPx = rvec * uWinSize;
    float m = length(dispPx);
    if (m > uThrow)
        dispPx *= uThrow / max(m, 1e-4);
    vec2 sampleUV = clamp((p + dispPx) / uQuadSize, vec2(0.001), vec2(0.999));
    vec3 refr = texture(uBlur, sampleUV).rgb;

    // Pill-identical tint semantics (mix only, 0.28 factor).
    vec3 tint = mix(uTint, uTint2, clamp(uLerp, 0.0, 1.0));
    vec3 col = mix(refr, tint, clamp(uTintMix, 0.0, 1.0) * 0.28);

    // Glow is computed below, after d, so its mask hugs the frame bevel.

    // The pill overlay trio compressed onto the band: d runs 0 at the outer
    // boundary to 1 at the inner (both shifted by push, so the split travels
    // with the band). Same components, same blend, same order as the pills.
    float d = clamp((push - sd) / max(uThick, 1e-3), 0.0, 1.0);
    // Bipolar diagonal frame glow: strongest at the outer rim, riding with
    // the bevel trio (d = 0 outer -> 1 inner), directional via the
    // lens-field normal. Two identical poles, true-zero nodes.
    // Layer 1 (multiplicative, kept) + layer 2 (plain white additive, 33%).
    // PERF: skip atan+sin entirely when glow off (doGlow from normals above).
    if (doGlow) {
    float graw = abs(sin(atan(glowN.y, glowN.x) - 0.5 - 0.4363323129));
    // Same bright-cap narrowing as glass.frag (one material): soft
    // threshold, peak-preserving, eased cut.
    float gcap = clamp((graw - uGlowT) / max(1.0 - uGlowT, 1e-3), 0.0, 1.0);
    gcap = gcap * gcap * (3.0 - 2.0 * gcap);
    float kdir = 1.0 - smoothstep(0.0, 1.0, d);
    float g = mix(0.0, gcap, kdir);
    float edgeMask = (1.0 - smoothstep(0.0, 1.0, d)) * 0.5;
    float glow = g * uGlowW * edgeMask + 1.0 + uGlowBias;
    col *= glow;
    col += vec3(1.0) * (g * edgeMask) * 0.33;
    } // end glow early-out
    float bevel = 1.0 - smoothstep(0.15, 0.55, d);
    float shade = smoothstep(0.45, 0.85, d);
    vec2 rad = (wuv - vec2(0.5)) * 2.0;
    vec2 rn = rad / max(length(rad), 1e-4);
    float sheen = clamp(-rn.y * 0.5 + 0.5, 0.0, 1.0);
    sheen *= sheen;
    float hi = bevel * 0.30 + sheen * 0.25;
    // DIAGNOSTIC: same 10% treatment as glass.frag (0.02 vs 0.20).
    float lo = shade * 0.02;
    // Neoclassical frame relief: the heightfield steers the refraction
    // throw, deepens the bevel trio and gilts the crests. Band pixels only,
    // skipped entirely when disabled or on thin bands (e.g. 1px layers).
    // (Perimeter frame fs/fn/ft + frieze pick frSel come from the silhouette
    // block above, so edge waves and shading stay in phase.)
    if (frameOn > 0.5) {
        float hb = runBody(fs, d, uSeed, frSel, fsc, uThick);
        float hRos = clamp(rosette(p, fcc, frMid, uThick * 0.30 + 1.0, uSeed), 0.0, 1.8);
        float h0 = mix(hb, hRos, clamp(fcm, 0.0, 1.0));
        // Relief gradient steers refraction (re-clamped to the bleed below).
        // Rosette gradient is intentionally omitted: corners shade via the
        // bevel/gilt terms, keeping this to two extra height evals.
        float fe = 1.5;
        float fhx = runBody(fs + fe, d, uSeed, frSel, fsc, uThick) - hb;
        float fht = runBody(fs, clamp(d + fe / max(uThick, 1.0), 0.0, 1.0), uSeed, frSel, fsc, uThick) - hb;
        dispPx += (ft * fhx + fn * fht) * (5.0 * uRelief);
        float m2 = length(dispPx);
        if (m2 > uThrow) dispPx *= uThrow / max(m2, 1e-4);
        vec2 sampleUV2 = clamp((p + dispPx) / uQuadSize, vec2(0.001), vec2(0.999));
        refr = texture(uBlur, sampleUV2).rgb;
        col = mix(refr, tint, clamp(uTintMix, 0.0, 1.0) * 0.28);
        col *= glow; // resample discards the glow above: re-apply, same order
        col += vec3(1.0) * (g * edgeMask) * 0.33; // additive layer, same
        // Bevel follows relief; recesses deepen.
        hi += h0 * 0.45 * uRelief;
        lo += (1.0 - smoothstep(0.0, 0.9, h0)) * 0.15 * uRelief;
        // Gilt crests on active (saturated-tint) windows, carved stone when
        // inactive; palette (gold/bronze/marble) varies per window seed.
        float satT = length(tint - vec3(dot(tint, vec3(0.3333))));
        float activeM = clamp(satT * 2.4, 0.0, 1.0);
        float crest = smoothstep(0.50, 0.95, h0);
        float pal = floor(frHash(uSeed * 3.71 + 1.3) * 2.999);
        vec3 gold = (pal < 0.5) ? vec3(0.95, 0.74, 0.42)
                  : (pal < 1.5) ? vec3(0.80, 0.55, 0.30) : vec3(0.88, 0.86, 0.80);
        vec3 giltCol = col * (gold * 1.15) + gold * 0.08;
        vec3 stoneCol = col * vec3(0.92, 0.92, 0.95);
        vec3 frameCol = mix(stoneCol, giltCol, clamp(uGilt * (0.35 + 0.65 * activeM), 0.0, 1.0));
        col = mix(col, frameCol, crest * 0.7);
    }
    col = overlay(col, clamp(vec3(0.5) + vec3(hi - lo) * 0.5, 0.0, 1.0));

    // Full opacity means fully opaque (solid border color, no glass left),
    // same anchor as the pills: identical look at/below the default.
    float fullness = smoothstep(0.82, 1.0, clamp(uTintMix, 0.0, 1.0));
    col = mix(col, tint, fullness);

    // Ring alpha carries the shared rotated fade (vf computed above).
    // 1/1/1 = no fade. Only alpha fades — refraction/tint stay.
    fragColor = vec4(col, band * uA * vf);
}
