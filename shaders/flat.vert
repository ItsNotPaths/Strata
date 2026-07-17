#version 450
//
// Flat colored geometry — the whole 2D canvas (fills, AA strokes, handles,
// glyphs — all pre-baked triangles with per-vertex color/alpha) and the 3D
// pane's ground grid (line list). The pipelines differ (topology, depth,
// ortho vs perspective mvp); the shader pair is shared.
//
// SDL_gpu Vulkan binding model: vertex uniform buffers live in descriptor set 1.

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec4 a_color;

layout(set = 1, binding = 0) uniform UBO {
    mat4 mvp;
    vec4 cam_pos;
} ubo;

layout(location = 0) out vec4 v_color;

void main() {
    v_color = a_color;
    gl_Position = ubo.mvp * vec4(a_pos, 1.0);
}
