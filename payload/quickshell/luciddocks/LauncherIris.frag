#version 440

// Launcher iris mask with a rim light. The plugin's rim-only pass explicitly
// skips masked surfaces (its ring shader has no circular-mask mode), so the
// reveal circle carries its own edge light and hands off to the plugin rim
// once the settled pill is published.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 center;
    float radius;
    float aspect;
    vec4 rimColor;
    float rimStrength;
    float rimWidth;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec2 d = vec2(qt_TexCoord0.x - center.x,
                  (qt_TexCoord0.y - center.y) * aspect);
    float dist = length(d);
    float aa = max(fwidth(dist), 0.00001);
    float alpha = 1.0 - smoothstep(max(0.0, radius - aa), radius + aa, dist);
    vec4 col = texture(source, qt_TexCoord0) * qt_Opacity * alpha;

    if (rimStrength > 0.0) {
        float inner = max(radius - rimWidth, 0.0);
        float ring = smoothstep(inner - aa, inner + aa, dist)
                   * (1.0 - smoothstep(radius - aa, radius + aa, dist));
        // Light from the top-left, like the plugin's rim_angle=135.
        vec2 dir = d / max(dist, 1e-5);
        float light = 0.62 + 0.38 * dot(dir, normalize(vec2(-0.7071, -0.7071)));
        float a = clamp(ring * rimStrength * light * rimColor.a, 0.0, 1.0);
        // Premultiplied source-over.
        col = vec4(rimColor.rgb * a, a) + col * (1.0 - a);
    }

    fragColor = col;
}
