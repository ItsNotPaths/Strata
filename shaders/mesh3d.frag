#version 450
//
// 3D preview mesh fragment shader — triplanar albedo from the material
// palette array (view3d palette: one layer per Eval_World.materials entry;
// recipes without a preview texture get their hash tint baked into the
// layer, so sampling is unconditional). Sun diffuse + sky-tinted ambient by
// up-facing; the selection tint rides the fragment UBO so the 2D pane's
// selection reads in 3D without any re-upload.

layout(location = 0) in vec3      v_normal;
layout(location = 1) in flat uint v_mat;
layout(location = 2) in vec3      v_world;

layout(set = 2, binding = 0) uniform sampler2DArray u_palette;

layout(set = 3, binding = 0) uniform FUBO {
    int   highlight_mat; // material id to tint toward selection, -1 = none
    int   layers;        // palette array depth (>= 1)
    float texscale;      // world units per texture tile
    float _pad0;
} fubo;

layout(location = 0) out vec4 o_color;

void main() {
    vec3  n    = normalize(v_normal);
    vec3  L    = normalize(vec3(0.4, 0.6, 0.8));
    float diff = max(dot(n, L), 0.0);

    // triplanar: project along each axis, weight by |n| (sharpened)
    vec3 w = pow(abs(n), vec3(4.0));
    w /= (w.x + w.y + w.z);
    float layer = float(min(int(v_mat), fubo.layers - 1));
    float s = 1.0 / max(fubo.texscale, 1e-3);
    vec3 base =
        texture(u_palette, vec3(v_world.zy * s, layer)).rgb * w.x +
        texture(u_palette, vec3(v_world.xz * s, layer)).rgb * w.y +
        texture(u_palette, vec3(v_world.xy * s, layer)).rgb * w.z;

    if (int(v_mat) == fubo.highlight_mat) {
        base = mix(base, vec3(1.0, 0.62, 0.18), 0.5);
    }

    // ambient leans blue when the surface faces up (open-sky canyons; y-up)
    vec3 ambient = mix(vec3(0.30, 0.29, 0.33), vec3(0.38, 0.42, 0.52), n.y * 0.5 + 0.5);
    o_color = vec4(base * (ambient + vec3(0.72) * diff), 1.0);
}
