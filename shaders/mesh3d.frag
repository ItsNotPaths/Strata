#version 450
//
// 3D preview mesh fragment shader — hashed per-material tint (stable across
// sessions, same recipe as dymeta's id-debug view), sun diffuse + sky-tinted
// ambient by up-facing. Real triplanar texturing from the texgen palette
// replaces the hash at M4; the selection tint rides the fragment UBO so the
// 2D pane's selection reads in 3D without any re-upload.

layout(location = 0) in vec3      v_normal;
layout(location = 1) in flat uint v_mat;
layout(location = 2) in vec3      v_world;

layout(set = 3, binding = 0) uniform FUBO {
    int highlight_mat; // material id to tint toward selection, -1 = none
    int _pad0;
    int _pad1;
    int _pad2;
} fubo;

layout(location = 0) out vec4 o_color;

vec3 mat_color(uint m) {
    float fm = float(m);
    float r = fract(sin(fm * 12.9898) * 43758.5453);
    float g = fract(sin(fm * 78.2330) * 43758.5453);
    float b = fract(sin(fm * 37.7190) * 43758.5453);
    return 0.35 + 0.6 * vec3(r, g, b);
}

void main() {
    vec3  n    = normalize(v_normal);
    vec3  L    = normalize(vec3(0.4, 0.6, 0.8));
    float diff = max(dot(n, L), 0.0);

    vec3 base = mat_color(v_mat);
    if (int(v_mat) == fubo.highlight_mat) {
        base = mix(base, vec3(1.0, 0.62, 0.18), 0.5);
    }

    // ambient leans blue when the surface faces up (open-sky canyons)
    vec3 ambient = mix(vec3(0.30, 0.29, 0.33), vec3(0.38, 0.42, 0.52), n.z * 0.5 + 0.5);
    o_color = vec4(base * (ambient + vec3(0.72) * diff), 1.0);
}
