#version 450

#define MAX_TEXTURES 248
#define MAX_INSTANCES 4096

// TODO: rename, this the sprite shader

layout(location = 0) in vec2 inPosition;

layout(location = 1) out vec2 outTexCoord;

// TODO: mat3, not 4!
// shared uniform data
layout(binding = 0) uniform UniformBufferObject {
    mat4 view;
    mat4 proj;
} ubo;

layout(set = 0, binding = 1) buffer InstanstanceBufferObject {
    vec2 pos[MAX_INSTANCES];
    int uv_index[MAX_INSTANCES];
} ibo;


layout(set = 1, binding = 2) buffer UvBuffferObject {
    vec2 uvs[MAX_TEXTURES];
} uvs;

void main() {
    int uv_index = ibo.uv_index[gl_InstanceIndex] + gl_VertexIndex;
    outTexCoord = uvs.uvs[uv_index];

    gl_Position = vec4(inPosition + ibo.pos[gl_InstanceIndex], 0.0, 1.0) * (ubo.proj * ubo.view);
}
