#version 450
//
// Flat colored geometry fragment shader — passthrough of the baked per-vertex
// color (AA strokes carry their falloff in the alpha channel).

layout(location = 0) in vec4 v_color;

layout(location = 0) out vec4 o_color;

void main() {
    o_color = v_color;
}
