#version 450
//
// Marker prop pass (view3d): preview meshes / fallback pins at marker
// positions. Frame uniforms are the shared UBO (slot 0); each draw pushes
// its own model matrix + tint (slot 1) — markers are few, per-draw push
// beats instancing plumbing. Lighting matches mesh3d so props sit in the
// same scene: sun diffuse + up-tinted ambient, computed here per-vertex
// (props are preview geometry; the frag just interpolates).
//
// SDL_gpu Vulkan binding model: vertex uniform buffers live in descriptor set 1.

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_normal;

layout(set = 1, binding = 0) uniform UBO {
    mat4 mvp;
    vec4 cam_pos;
} ubo;

layout(set = 1, binding = 1) uniform PUBO {
    mat4 model;  // translate * rotY(yaw) * scale (uniform scale only)
    vec4 color;  // rgb tint; a = unlit blend (1 = emissive flat color)
} pubo;

layout(location = 0) out vec4 v_color;

void main() {
    vec3 wp = (pubo.model * vec4(a_pos, 1.0)).xyz;
    // uniform-scale + rotation model matrix: rotate normals, skip inverse-transpose
    vec3 n  = normalize(mat3(pubo.model) * a_normal);

    vec3  L    = normalize(vec3(0.4, 0.6, 0.8));
    float diff = max(dot(n, L), 0.0);
    vec3 ambient = mix(vec3(0.30, 0.29, 0.33), vec3(0.38, 0.42, 0.52), n.y * 0.5 + 0.5);
    vec3 lit = pubo.color.rgb * (ambient + vec3(0.72) * diff);

    v_color = vec4(mix(lit, pubo.color.rgb, pubo.color.a), 1.0);
    gl_Position = ubo.mvp * vec4(wp, 1.0);
}
