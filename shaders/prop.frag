#version 450
// Marker prop pass — vertex-lit color passthrough (prop.vert).

layout(location = 0) in vec4 v_color;
layout(location = 0) out vec4 o_color;

void main() {
    o_color = v_color;
}
