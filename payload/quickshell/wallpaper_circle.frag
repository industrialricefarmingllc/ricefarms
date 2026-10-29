// Wallpaper iris: draw a screen-sized wallpaper texture only inside a moving
// circle. The source is a ShaderEffectSource of the Image; the circle is in
// item pixels, so the QML side can animate cx/cy/radius directly.
#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 itemSize;
    vec2 center;
    float radius;
};
layout(binding = 1) uniform sampler2D wallpaperTex;

void main() {
    vec2 p = qt_TexCoord0 * itemSize;
    float d = distance(p, center);
    float a = 1.0 - smoothstep(max(0.0, radius - 1.0), radius + 1.0, d);
    if (a <= 0.001)
        discard;
    vec4 c = texture(wallpaperTex, qt_TexCoord0);
    fragColor = vec4(c.rgb * a, a * c.a) * qt_Opacity;
}
