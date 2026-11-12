#version 300 es

// Full e-ink pass for one window, drawn by lucid-eink-window after the
// window's own content and before any later window. The source texture is a
// copy of that window's composited rectangle.

precision highp float;
in vec2 v_texcoord;
uniform sampler2D tex;
uniform vec2 uSize;   // window rect in framebuffer px
uniform float uRadius; // window rounding in framebuffer px
out vec4 fragColor;

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

// ---------------------------------------------------------------
// Ebook paper noise
// E-readers (Kindle, KOReader) don't paint a flat white page: they
// lay a *static*, multi-scale speckle over it so the background reads
// as a sheet instead of a backlight. paperTexture()/directionalGrain()
// above only give fibre streaks on bright pixels, which leaves big
// flat areas looking like a light panel. Real paper has four cues:
//   mottle  - uneven pulp, low frequency, biggest visual cue
//   clump   - fibre clumps, 2-3px, the "grain" you see while reading
//   tooth   - per-pixel matte, breaks up banding in smooth fields
//   fleck   - sparse dark inclusions (undissolved pulp)
// Screen-space (gl_FragCoord) and hash-only: no texture lookups, no
// time uniform, so it never crawls when windows redraw.
// ---------------------------------------------------------------
// Value noise: hashed lattice with Hermite interpolation between
// cells. Plain hash(floor(px/56)) would give hard 56px blocks.
float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f); // smoothstep fade, no visible cell edges
    return mix(mix(hash(i),                  hash(i + vec2(1.0, 0.0)), f.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x),
               f.y);
}

// Signed luminance offset. `weight` damps it over ink: noise on dark
// pixels shows up as screen-door dithering on glyph edges rather than
// paper tooth, and legibility matters more than texture there.
float ebookPaper(vec2 px, float weight) {
    // uneven pulp: two octaves, one cell per ~56px and ~17px on screen
    float mottle = valueNoise(px / 56.0) * 0.65 + valueNoise(px / 17.0) * 0.35;

    // fibre clumps: 3px cells so it reads as grain, not per-pixel fuzz
    float clump = hash(floor(px / 3.0));

    // per-pixel tooth: the matte feel at normal viewing distance
    float tooth = hash(px + 91.7);

    float n = (mottle - 0.5) * 0.040
            + (clump  - 0.5) * 0.030
            + (tooth  - 0.5) * 0.019;

    // inclusions: ~0.4% of 2px cells darken, like unbleached specks
    float fleck = step(0.996, hash(floor(px / 2.0) + 137.0));
    n -= fleck * 0.075;

    // Amplitudes above land at ~2/255 RMS on paper (peaks ~3/255);
    // together with the existing grain the page sits near 3/255 RMS.
    // Scale all four together: below ~2/255 total it stops reading as
    // paper, above ~5/255 it becomes TV static at this pixel density.
    return n * weight;
}

// Subtle vignette for paper edge darkening
float vignette(vec2 uv) {
    vec2 center = uv - 0.5;
    float dist = length(center);
    // smoothstep creates a signmoid (S-curve) so the shadow falls off naturally
    return 1.0 - smoothstep(0.4, 1.2, dist) * 0.15;
}

void main() {
    // Keep the window's rounded silhouette: the framebuffer behind the
    // transparent corners belongs to the wallpaper, not to this window.
    if (uRadius > 0.5) {
        vec2 halfSize = uSize * 0.5;
        vec2 q = abs(v_texcoord * uSize - halfSize) - halfSize + uRadius;
        float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - uRadius;
        if (sd > 0.0)
            discard;
    }

    vec4 pixColor = texture(tex, v_texcoord);

    // Luma Conversion
    // not using average (r+g+b)/3 because eyes see green brighter than blue.
    float gray = dot(pixColor.rgb, vec3(0.299, 0.587, 0.114));
    // Keep the untouched luma: the mid-tone weighting below is judged on
    // source brightness, before the e-ink curve saturates light greys.
    float srcLuma = gray;
    
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
    
    // Mid-tone attenuation: half noise strength on greys up to 225/255,
    // ramping back to full only on true white. Judged on source luma
    // because the tone curve above squeezes sRGB 200+ to ~0.99, so a mask
    // keyed on `gray` treats light greys as paper. Applies to the legacy
    // fibre grain as well as the ebook speckle — both ran at full strength
    // through the 200-225 range before this.
    float midTone = smoothstep(0.22, 0.38, srcLuma) * (1.0 - smoothstep(0.88, 1.0, srcLuma));
    float toneWeight = 1.0 - 0.5 * midTone;

    // PAPER GRAIN 
    float paperGrain = (paperTexture(screenPos * 0.3) - 0.5) * 0.035; 
    float dirGrain = (directionalGrain(screenPos * 0.4) - 0.5) * 0.025; // directional grain
    
    float bayerValue = getBayer(screenPos);
    
    // Apply to bright areas (paper), but also slightly to mid-tones for more visible grain
    float textureMask = smoothstep(0.5, 0.95, gray) * toneWeight; // Lower threshold for more coverage
    
    // Apply both grain types
    gray += paperGrain * textureMask;
    gray += dirGrain * textureMask * 0.7; // Directional grain is slightly weaker

    // Ebook paper speckle: runs over the whole page, not just highlights,
    // so flat white and flat ink both read as one sheet. Ink keeps its own
    // 40% damping on top so glyph edges stay crisp.
    float pageWeight = mix(0.4, 1.0, smoothstep(0.55, 0.95, gray)) * toneWeight;
    gray += ebookPaper(screenPos, pageWeight);
    
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

    vec3 finalColor = mix(inkColor, paperColor, gray);

    fragColor = vec4(finalColor, 1.0);
}
