#version 450

#include "tone_mapping.glsl"

layout (set = 0, binding = 0) uniform sampler2D imageSampler;

layout (location = 0) in vec2 inUV;

layout (location = 0) out vec4 outColor;

layout (push_constant) uniform PushConstant {
    uint enable_tone_mapping;
    uint samples_per_pixel;
} push_constant;

void main()
{
    const vec3 color = texture(imageSampler, inUV).rgb / push_constant.samples_per_pixel;

    if (push_constant.enable_tone_mapping != 0) {
        outColor = vec4(reinhard(color), 1);
    } else {
        outColor = vec4(color, 1);
    }
}
