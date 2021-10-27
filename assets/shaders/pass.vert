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

layout(binding = 4) buffer InstanstanceRotationBuffer {
    float data[];
} irot;

layout(binding = 5) buffer InstanstanceUVIndexBuffer {
    int data[];
} iuv_index;

layout(binding = 6) buffer UVBuffer {
    vec2 data[];
} uvs;


void main() {
    outTexCoord = uvs.data[iuv_index.data[gl_InstanceIndex] * 4 + gl_VertexIndex % 4];

    float cos_ = cos(irot.data[gl_InstanceIndex]);
    float sin_ = sin(irot.data[gl_InstanceIndex]);
    vec2 scale_pos = inPosition * iscale.data[gl_InstanceIndex];
    vec2 position = vec2(scale_pos.x * cos_ - scale_pos.y * sin_, scale_pos.x * sin_ + scale_pos.y * cos_);
    position = position + ipos.data[gl_InstanceIndex];

    gl_Position = vec4(position, 0.0, 1.0) * (ubo.view * ubo.proj);
}
