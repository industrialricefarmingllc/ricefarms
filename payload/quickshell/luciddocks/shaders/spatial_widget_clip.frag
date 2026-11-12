#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D source;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 viewport;
    vec4 rect;
    vec4 inner;  // card rect in quad-local px (the quad is grown by the pad)
    float hover; // 1 = card hidden behind the subject, 0 = card fully forward
} u;
void main() {
    vec2 local = qt_TexCoord0 * u.rect.zw;
    vec2 uv = (u.rect.xy + local) / u.viewport;
    vec4 c = texture(source, uv);
    // The quad is grown by the glass shadow margin so the subject covers the
    // shadow halo. On hover only the card itself may come forward: keep the
    // margin fully covered, otherwise the revealed backdrop (the glass shadow
    // and the darker main mesh) darkens a card+pad-sized area of the scene.
    float inCard = step(u.inner.x, local.x) * step(local.x, u.inner.x + u.inner.z)
                 * step(u.inner.y, local.y) * step(local.y, u.inner.y + u.inner.w);
    fragColor = c * u.qt_Opacity * mix(1.0, u.hover, inCard);
}
