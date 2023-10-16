#version 450

// SOURCE: https://poniesandlight.co.uk/reflect/bitonic_merge_sort/

#extension GL_EXT_debug_printf : disable
// debugPrintfEXT("hello world %f", 1.0);

#include "../raytracing/ray_commons.glsl"

layout(local_size_x_id = 0, local_size_y = 1, local_size_z = 1) in;

layout (std430, set = 0, binding = 0) readonly buffer HitLimitsBuffer {
    HitLimits limits;
};
layout (std430, set = 1, binding = 0) buffer RayBuffer {
    Ray rays[];
};
layout (std430, set = 2, binding = 0) buffer RayHitBuffer {
    RayHit ray_hits[];
};
layout (std430, set = 3, binding = 0) buffer RayActiveBuffer {
    RayActive ray_actives[];
};
layout (std430, set = 4, binding = 0) buffer RayShadingBuffer {
    RayShading ray_shadings[];
};

void main() {
	uint global_hit_index = gl_GlobalInvocationID.x * 2;

    const uint sort_elem_count = limits.out_hit_count + limits.out_miss_count;
    if (global_hit_index + 1 >= sort_elem_count) {
        return;
    }

    for(uint iter = 0; iter < sort_elem_count - 1; iter++) {

        const uint iter_index = global_hit_index + iter % 2;
        if (iter_index + 1 >= sort_elem_count) {
            continue;
        }

        barrier();
        const bool do_swap = hit_records[iter_index].is_active == false && hit_records[iter_index + 1].is_active == true;

        if (do_swap) {
            const HitRecord temp = hit_records[iter_index];
            hit_records[iter_index] = hit_records[iter_index + 1];
            hit_records[iter_index + 1] = temp;
        }
    }
}
