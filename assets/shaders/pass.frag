#version 450

// Primitive shader to pass compute shader texture to framebuffer

layout(location = 0) in vec3 fragColor;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = vec4(fragColor, 1.0);
}
