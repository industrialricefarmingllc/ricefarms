// Qt Quick 3D CustomMaterial snippet; compiled by the renderer at run time.
VARYING vec2 subjectUv;

void MAIN()
{
    vec3 captured = texture(sourceTexture, subjectUv).rgb;
    float alpha = texture(matteTexture, subjectUv).r;
    vec3 premultiplied = captured * alpha;
    if (fgOnly > 0.5) {
        // This pass is the cutout that sits above the widget layer. Its soft
        // matte band must not blend with whatever glass the widget published
        // underneath: that reads as a glass rim and slightly brightens the
        // card area. Fuse the subject with the reconstructed background
        // (exactly what the main surface shows there) and make coverage
        // opaque from the middle of the matte outward, so the cutout replaces
        // those pixels instead of tinting them.
        vec3 oldBackground = texture(backgroundTexture, subjectUv).rgb;
        vec3 fused = captured * alpha + oldBackground * (1.0 - alpha);
        float cover = smoothstep(0.25, 0.50, alpha);
        FRAGCOLOR = vec4(fused * cover * fade, cover * fade);
        return;
    }
    if (alpha > 0.08 && alpha < 0.98) {
        vec3 oldBackground = texture(backgroundTexture, subjectUv).rgb;
        vec3 recovered = clamp(captured - oldBackground * (1.0 - alpha),
                               vec3(0.0), vec3(alpha));
        float maximumChange = 0.18 * alpha;
        recovered = clamp(recovered, premultiplied - vec3(maximumChange),
                          premultiplied + vec3(maximumChange));
        float edgeWeight = smoothstep(0.08, 0.30, alpha)
                         * (1.0 - smoothstep(0.82, 0.98, alpha));
        premultiplied = mix(premultiplied, recovered, 0.75 * edgeWeight);
    }
    FRAGCOLOR = vec4(premultiplied * fade, alpha * fade);
}
