#version 450
//
// 3D preview mesh — the dual-contoured world chunks (engine/mesh.odin).
// Vertex = pos + normal + material id (upload-side conversion of the 28-byte
// engine Mesh_Vertex; SDL_gpu has no lone-USHORT attribute format, so mat
// rides as a u32). Texturing waits for the texgen palette at M4 — the
// fragment shader hashes the id into a stable tint.
//
// SDL_gpu Vulkan binding model: vertex uniform buffers live in descriptor set 1.

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_normal;
layout(location = 2) in uint a_mat;

layout(set = 1, binding = 0) uniform UBO {
    mat4 mvp;
    vec4 cam_pos;
} ubo;

layout(location = 0) out vec3      v_normal;
layout(location = 1) out flat uint v_mat;
layout(location = 2) out vec3      v_world;

void main() {
    v_normal = a_normal;
    v_mat    = a_mat;
    v_world  = a_pos;
    gl_Position = ubo.mvp * vec4(a_pos, 1.0);
}
