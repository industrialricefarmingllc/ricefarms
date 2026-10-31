#version 440

// Antialiased circular mask for the launcher: the per-app icon discs and the
// launcher's own circular reveal both bind center/radius/aspect and run this.
// The original shader discarded every fragment outside the circle, which left
// a hard, stair-stepped edge; here the edge is feathered over one screen pixel
// (fwidth) so it resolves smoothly at any scale.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 center;
    float radius;
    float aspect;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec2 d = vec2(qt_TexCoord0.x - center.x,
                  (qt_TexCoord0.y - center.y) * aspect);
    float dist = length(d);
    float aa = max(fwidth(dist), 0.00001);
    float alpha = 1.0 - smoothstep(max(0.0, radius - aa), radius + aa, dist);
    fragColor = texture(source, qt_TexCoord0) * qt_Opacity * alpha;
}
