#version 450

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inTexCoord;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec2 outTexCoord;

layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
} ubo;

void main() {
    outTexCoord = inTexCoord;
    fragColor = vec3(1.0, 0.0, 1.0);
    
    gl_Position = vec4(inPosition, 0.0, 1.0) * ubo.proj * ubo.view * ubo.model;
}
