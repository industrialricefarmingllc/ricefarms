#version 300 es

// Unit-quad vertex shader for the glass passes. Positions and texcoords both
// span 0..1; `proj` (projectBoxToTarget of the pill box) maps the quad onto
// the pill rect, so v_texcoord spans the pill 0..1. Self-contained on
// purpose: no dependence on Hyprland's internal vertex sources or VAOs.
layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 texcoord;

uniform mat3 proj;
out vec2 v_texcoord;

void main() {
    v_texcoord = texcoord;
    gl_Position = vec4(proj * vec3(pos, 1.0), 1.0);
}
