#version 450

// Primitive shader to pass compute shader texture to framebuffer

layout(location = 1) in vec2 inTexCoord;

layout(binding = 1) uniform sampler2D texSampler;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(texSampler, inTexCoord);
}
