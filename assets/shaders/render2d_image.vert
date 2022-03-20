#version 450

layout(location = 0) in vec2 inPosition;

layout(location = 1) out vec2 outTexCoord;

layout(binding = 0) uniform UniformBuffer {
    layout(offset =  0) mat4 view;
    layout(offset = 64) mat4 proj;
} ubo;

layout (push_constant) uniform Constants {
    ivec2 image_size;
} constants;

void main() {
    switch(gl_VertexIndex) {
        case 0:
            outTexCoord = vec2(0.0, 1.0);
            break;
        case 1:
            outTexCoord = vec2(1.0, 1.0);
            break;
        case 2:
            outTexCoord = vec2(0.0, 0.0);
            break;
        case 3: 
            outTexCoord = vec2(1.0, 0.0);
            break;
    }
    gl_Position = (ubo.proj * ubo.view) * vec4(inPosition * constants.image_size, 0, 1);
}
