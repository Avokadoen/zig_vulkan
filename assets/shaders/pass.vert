#version 450

layout(location = 0) in vec2 inPosition;

layout(location = 0) out vec3 fragColor;

layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
} ubo;

void main() {
    gl_Position = ubo.proj * ubo.view * ubo.model * vec4(inPosition, 0.0, 1.0);
    // TODO: map texture
    fragColor = vec3(1.0, 0.0, 1.0);
}
