// Constants, TODO, move to another file
const int MAT_LAMBERTIAN = 0;
const int MAT_METAL = 1;
const int MAT_DIELECTRIC = 2;

const uint IGNORE_MAT_LAMBERTIAN = MAT_LAMBERTIAN;
const uint IGNORE_MAT_METAL = MAT_METAL;
const uint IGNORE_MAT_DIELECTRIC = MAT_DIELECTRIC;
const uint IGNORE_MAT_NONE = 3;

// Must be kept in sync with  src/modules/voxel_rt/ray_pipeline_types.zig
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

// Must be kept in sync with src/modules/voxel_rt/ray_pipeline_types.zig Ray
struct Ray {
    vec3 origin;
    float internal_reflection;
    vec3 direction;
    float t_value;
};
// Must be kept in sync with src/modules/voxel_rt/ray_pipeline_types.zig RayHit
struct RayHit {
    uint normal_4b_and_material_index_28b;
};
// Must be kept in sync with src/modules/voxel_rt/ray_pipeline_types.zig RayActive
struct RayActive {
    bool is_active;  
};
// Must be kept in sync with src/modules/voxel_rt/ray_pipeline_types.zig RayShading
struct RayShading {
    vec3 color;
    uint pixel_coord;
};
// Must be kept in sync with src/modules/voxel_rt/ray_pipeline_types.zig RayHash
struct RayHash {
    uint value;
};

const vec3 normal_map[] = vec3[](
    vec3( 1,  0,  0),
    vec3( 0,  1,  0),
    vec3( 0,  0,  1),
    vec3(-1,  0,  0),
    vec3( 0, -1,  0),
    vec3( 0,  0, -1)
);


vec3 RayAt(Ray r, float t) {
    // instruction for: t * dir + origin
    return fma(vec3(t), r.direction, r.origin);
}
