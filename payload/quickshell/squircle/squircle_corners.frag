// Fullscreen inverted squircle corners (Qt 6 ShaderEffect, qsb-baked).
//
// Draws cornerColor OUTSIDE the superellipse arc inside each SxS screen
// corner square (S = cornerSize px), transparent everywhere else. The arc
// in each square is centered on the square corner nearest the screen
// center. At exponent 2 the arc is exactly the old circular bezel.
// See squircle_rect.frag header for the .qsb build note.

#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 color;
    vec2 itemSize;
    float cornerSize;
    float exponent;
};

// Superellipse field of rel (px inside the SxS square) measured from the
// square's inner corner: flipX/flipY select which square corner that is.
// Returns v < 0 outside the square.
float cornerField(vec2 rel, float flipX, float flipY) {
    if (rel.x < 0.0 || rel.y < 0.0 || rel.x > cornerSize || rel.y > cornerSize)
        return -1.0;
    float qx = mix(cornerSize - rel.x, rel.x, flipX) / cornerSize;
    float qy = mix(cornerSize - rel.y, rel.y, flipY) / cornerSize;
    return pow(qx, exponent) + pow(qy, exponent);
}

void main() {
    vec2 px = qt_TexCoord0 * itemSize;
    float v = -1.0;
    // TL: inner corner is the square's bottom-right (no flip).
    v = max(v, cornerField(px - vec2(0.0, 0.0), 0.0, 0.0));
    // TR: inner corner is the square's bottom-left (flip x).
    v = max(v, cornerField(px - vec2(itemSize.x - cornerSize, 0.0), 1.0, 0.0));
    // BL: inner corner is the square's top-right (flip y).
    v = max(v, cornerField(px - vec2(0.0, itemSize.y - cornerSize), 0.0, 1.0));
    // BR: inner corner is the square's top-left (flip both).
    v = max(v, cornerField(px - vec2(itemSize.x - cornerSize, itemSize.y - cornerSize), 1.0, 1.0));
    if (v < 0.0)
        discard;
    // Pixel-accurate edge. The old band was a constant width in *field*
    // space (w = 1.5 * exponent / cornerSize), which widens with the
    // exponent: at n = 5.2 / cornerSize 54 that is a ~5px transition, which
    // reads as a soft, blurry bezel. Dividing the field by its screen-space
    // derivative turns it into a distance in pixels, so the transition stays
    // one pixel wide at any exponent or corner size.
    float fw = max(fwidth(v), 1e-6);
    float a = smoothstep(-0.5, 0.5, (v - 1.0) / fw);
    if (a <= 0.001)
        discard;
    fragColor = vec4(color.rgb * a * color.a, a * color.a) * qt_Opacity;
}
