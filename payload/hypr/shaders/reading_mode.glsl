#version 320 es

/*
   I love e-ink displays!
   The mathematical philosophy here is using deterministic logic (Bayer matrices, arithmetic hashing) 
   to simulate physical chaos (paper grain, ink bleed). I picked up these concepts in a course 
   and this is easily the best real-world application of them I've found. 
   It works brilliantly-looks like real paper, killed my eye strain, and even reduced the insane 
   reflections from my glossy surface display.

   by @snes19xx, https://github.com/snes19xx
*/


precision highp float;
in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

// Lucid screen corners: a quickshell overlay draws black inverted rounded
// corners on every monitor (see lucidcorners/ScreenCorners.qml). The e-ink
// mapping below would turn that black into ink-gray, so pass those pixels
// through untouched and keep them looking like a physical rounded bezel.
// All monitors are 1600 logical px wide and the overlay is sized in logical
// px (which the compositor scales already normalize across DPIs), so the
// radius as a fraction of the output width is cornerSize / 1600.
// Keep in sync with `cornerSize` there.
const float CORNER_FRAC = 54.0 / 1600.0;
// Superellipse exponent of the bezel cutout: matches the shared squircle
// smoothing at its default f = 0.5 (n = 2 + 4f = 4). If the Lucid slider
// moves far off default, a sub-pixel sliver of the crescent may ink-map;
// reading mode only, cosmetic.
const float CORNER_N = 4.0;

// True when the fragment sits in a corner's black crescent: inside the
// cornerSize square at a screen corner but outside the transparent
// quarter-disk cutout (radius r around (r, r) measured inward from the apex).
// frag/res are in output pixels, GL coords (origin bottom-left) — the test is
// symmetric so it holds for all four corners.
bool inCornerCrescent(vec2 frag, vec2 res, float r) {
    vec2 apex = vec2(frag.x < res.x * 0.5 ? 0.0 : res.x,
                     frag.y < res.y * 0.5 ? 0.0 : res.y);
    vec2 rel = abs(frag - apex);
    if (rel.x >= r || rel.y >= r)
        return false;
    // transparent cutout is a squircle around the square's inner corner
    // (r, r): black where the superellipse field exceeds 1
    vec2 q = vec2((r - rel.x) / r, (r - rel.y) / r);
    return pow(q.x, CORNER_N) + pow(q.y, CORNER_N) >= 1.0;
}

// 4x4 Bayer Matrix
// this grid helps break up smooth gradients into texture so it looks less "digital"
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

// High-performance "Hash12" - No trigonometry
// old hash used sin() which is slow on gpu. this one just mashes bits together.
// (https://www.shadertoy.com/view/4djSRW)
float hash(vec2 p) {
    // fract() keeps only the decimal part for the wave-like dusty pattern
    // .1031 is a special prime number to avoid perfect alignments with pixel grid
    vec3 p3  = fract(vec3(p.xyx) * .1031);
    
    // dot product mixes the x, y, z values so they depend on each other
    p3 += dot(p3, p3.yzx + 33.33);
    
    // return the final entangled decimal. deterministically random (afaik).
    return fract((p3.x + p3.y) * p3.z);
}

// Multi-octave noise for realistic paper fiber texture
float paperTexture(vec2 uv) {
    float n = 0.0;
    n += hash(uv * 0.3) * 0.6;       // Very large fibers
    n += hash(uv * 0.8) * 0.4;       // Large fibers
    n += hash(uv * 2.5) * 0.3;       // Medium detail
    n += hash(uv * 6.0) * 0.2;       // Fine grain
    n += hash(uv * 15.0) * 0.1;      // Very fine grain
    return n / 1.6; // Normalize
}

// Directional paper grain (simulates paper fibers running in one direction)
float directionalGrain(vec2 uv) {
    vec2 direction = vec2(0.7, 0.3); // Fiber direction
    float grain = 0.0;
    grain += hash(uv * 3.0 + direction * 2.0) * 0.5;
    grain += hash(uv * 8.0 + direction * 5.0) * 0.3;
    return grain / 0.8;
}

// Subtle vignette for paper edge darkening
float vignette(vec2 uv) {
    vec2 center = uv - 0.5;
    float dist = length(center);
    // smoothstep creates a signmoid (S-curve) so the shadow falls off naturally
    return 1.0 - smoothstep(0.4, 1.2, dist) * 0.15;
}

void main() {
    vec4 pixColor = texture(tex, v_texcoord);

    // Exempt the fake rounded screen corners: geometry + near-black check
    // (the blackness guard keeps desktop content shaded normally if the
    // overlay ever stops covering these pixels).
    vec2 outRes = vec2(textureSize(tex, 0));
    float cornerR = outRes.x * CORNER_FRAC;
    if (inCornerCrescent(gl_FragCoord.xy, outRes, cornerR)
        && dot(pixColor.rgb, vec3(0.299, 0.587, 0.114)) < 0.05) {
        fragColor = pixColor;
        return;
    }
    
    // Luma Conversion
    // not using average (r+g+b)/3 because eyes see green brighter than blue.
    float gray = dot(pixColor.rgb, vec3(0.299, 0.587, 0.114));
    
    // E-ink characteristic response curve
    // real e-ink isn't linear. this exponent simulates ink clumping.
    gray = pow(gray, 1.2);
    
    // Better contrast with slight S-curve
    // clips pure blacks/whites but keeps the middle smooth.
    gray = smoothstep(0.08, 0.92, gray);
    
    // Mid-tone boost
    float midBoost = smoothstep(0.3, 0.5, gray) * (1.0 - smoothstep(0.5, 0.7, gray));
    gray += midBoost * 0.1;
    
    vec2 screenPos = gl_FragCoord.xy;
    
    // PAPER GRAIN 
    float paperGrain = (paperTexture(screenPos * 0.3) - 0.5) * 0.035; 
    float dirGrain = (directionalGrain(screenPos * 0.4) - 0.5) * 0.025; // directional grain
    
    float bayerValue = getBayer(screenPos);
    
    // Apply to bright areas (paper), but also slightly to mid-tones for more visible grain
    float textureMask = smoothstep(0.5, 0.95, gray); // Lower threshold for more coverage
    
    // Apply both grain types
    gray += paperGrain * textureMask;
    gray += dirGrain * textureMask * 0.7; // Directional grain is slightly weaker
    
    // Increased dithering for more texture
    float ditherStrength = 0.025; // Increased from 0.018
    gray += (bayerValue - 0.5) * ditherStrength * textureMask;
    
    // Vignette for paper edges
    float vig = vignette(v_texcoord);
    gray *= vig;
    
    gray = clamp(gray, 0.0, 1.0);
    
    // E-ink colors with slight warmth variation
    // Paper white lowered by 50/255 to cap max brightness
    vec3 paperColor = vec3(0.94, 0.92, 0.86) - vec3(50.0 / 255.0);
    vec3 inkColor   = vec3(0.10, 0.10, 0.12);
    
    // More noticeable color variation for paper texture
    float colorVariation = hash(screenPos * 0.08) * 0.02; // Increased from 0.01
    paperColor += vec3(colorVariation, colorVariation * 0.5, -colorVariation * 0.2);
    
    // linear interpolation. paints the gray value onto our specific color palette.
    vec3 finalColor = mix(inkColor, paperColor, gray);
    
    fragColor = vec4(finalColor, pixColor.a);
}