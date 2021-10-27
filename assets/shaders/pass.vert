#version 450

// TODO: vec3 for affine transforms
layout(location = 0) in vec2 inPosition;

layout(location = 1) out vec2 outTexCoord;

// TODO: set 0
layout(binding = 0) uniform UniformBuffer {
    layout(offset =  0) mat4 view;
    layout(offset = 64) mat4 proj;
} ubo;

layout(binding = 2) buffer InstanstancePositionBuffer {
    vec2 data[];
} ipos;

layout(binding = 3) buffer InstanstanceScaleBuffer {
    vec2 data[];
} iscale;

layout(binding = 4) buffer InstanstanceUVIndexBuffer {
    int data[];
} iuv_index;

layout(binding = 5) buffer InstanstanceUVBuffer {
    vec2 data[];
} iuv;

void main() {
    outTexCoord = iuv.data[iuv_index.data[gl_InstanceIndex] * 4 + gl_VertexIndex % 4];
    vec2 position = inPosition * iscale.data[gl_InstanceIndex] + ipos.data[gl_InstanceIndex];
    gl_Position = vec4(position, 0.0, 1.0) * (ubo.view * ubo.proj);
}
