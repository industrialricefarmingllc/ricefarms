// Backdrop behind the depth mesh. It only shows through disocclusion gaps at
// the frame edge, so it does not need the nine-tap defocus of the mesh pass;
// sampling the source once removes a full-screen blur pass per frame.
VARYING vec2 backgroundUv;

void MAIN() {
    vec3 color = texture(backgroundTexture, backgroundUv).rgb;
    FRAGCOLOR = vec4(color * fade, fade);
}
