// Constants, TODO, move to another file
const int MAT_LAMBERTIAN = 0;
const int MAT_METAL = 1;
const int MAT_DIELECTRIC = 2;

const uint IGNORE_MAT_LAMBERTIAN = MAT_LAMBERTIAN;
const uint IGNORE_MAT_METAL = MAT_METAL;
const uint IGNORE_MAT_DIELECTRIC = MAT_DIELECTRIC;
const uint IGNORE_MAT_NONE = 3;

// must be kept in sync with TraverseRayPipeline.Ray
struct Ray {
    vec3 origin;
    float t_value;
    vec3 direction;
};

vec3 RayAt(Ray r, float t) {
    // instruction for: t * dir + origin
    return fma(vec3(t), r.direction, r.origin);
}

// Must be synced with src\modules\voxel_rt\ray_pipeline_types.zig
struct HitLimits {
    // How many hit records were emitted by the emit stage for the current frame
    uint emitted_hit_count;
    // How many hit records that are processed by the traverse stage
    uint in_hit_count;
    // How many hits was registered during traverse stage
    uint out_hit_count;
    // How many misses was registered during traverse stage
    uint out_miss_count;
};

// TODO: split in multiple buffers
// must be kept in sync with TraverseRayPipeline.HitRecord
struct HitRecord {
    vec3 point;
    uint normal_4b_and_material_index_28b;
    vec3 previous_ray_direction;
    float previous_ray_internal_reflection;
    vec3 previous_color;
    uint pixel_coord;
    float t_value;
    bool is_active;
    uint padding1;
    uint padding0;
};

const vec3 normal_map[] = vec3[](
    vec3( 1,  0,  0),
    vec3( 0,  1,  0),
    vec3( 0,  0,  1),
    vec3(-1,  0,  0),
    vec3( 0, -1,  0),
    vec3( 0,  0, -1)
);
