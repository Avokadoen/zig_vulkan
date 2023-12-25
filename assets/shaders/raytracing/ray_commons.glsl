// Constants, TODO, move to another file
const int MAT_LAMBERTIAN = 0;
const int MAT_METAL = 1;
const int MAT_DIELECTRIC = 2;

const uint IGNORE_MAT_LAMBERTIAN = MAT_LAMBERTIAN;
const uint IGNORE_MAT_METAL = MAT_METAL;
const uint IGNORE_MAT_DIELECTRIC = MAT_DIELECTRIC;
const uint IGNORE_MAT_NONE = 3;

// See glsl 4.40 spec chapter 4.7.1 for info on infinity
// https://www.khronos.org/registry/OpenGL/specs/gl/GLSLangSpec.4.40.pdf
const float infinity = 0.001 / 0;
const float pi = 3.14159265358; // 3.1415926535897932385
const float faccuracy = 0.000001;

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

// Must be kept in sync with  src/modules/voxel_rt/ray_pipeline_types.zig
struct BrickLimits {
    // Written by host 
    uint max_load_request_count;
    // How many bricks have been requested so far
    uint load_request_count;
    // Written by host 
    uint max_unload_request_count;
    // How many bricks have been requested so far
    uint unload_request_count;
    // How many active bricks can we have
    uint max_active_bricks;
    // How many active bricks do we have
    int active_bricks;
};

// Must be kept in sync with src/modules/voxel_rt/ray_pipeline_types.zig BrickIndex.Status
const uint BRICK_STATUS_UNLOADED = 0;
const uint BRICK_STATUS_LOADING = 1;
const uint BRICK_STATUS_UNLOADING = 2;
const uint BRICK_STATUS_LOADED = 3;

// Must be kept in sync with src/modules/voxel_rt/ray_pipeline_types.zig BrickIndex
const int BRICK_STATUS_BITS = 2;
const int BRICK_STATUS_OFFSET = 0;
const int BRICK_REQUEST_COUNT_BITS = 8;
const int BRICK_REQUEST_COUNT_OFFSET = BRICK_STATUS_BITS + BRICK_STATUS_OFFSET;
const int BRICK_INDEX_BITS = 22;
const int BRICK_INDEX_OFFSET = BRICK_REQUEST_COUNT_BITS + BRICK_REQUEST_COUNT_OFFSET;

const int BRICK_REQUEST_COUNT_MAX_VALUE = (1 << BRICK_REQUEST_COUNT_BITS) - 1;

struct Brick {
    // 512 bit voxel set mask
    uint solid_mask[16];
};

// Must be kept in sync with src/modules/voxel_rt/ray_pipeline_types.zig Ray
struct Ray {
    vec3 origin;
    float internal_reflection;
    vec3 direction;
    float t_value; // TOOD: move it's own buffer and track total_t_value as well
};
// Must be kept in sync with src/modules/voxel_rt/ray_pipeline_types.zig RayHit
struct RayHit {
    // 3 bits for normal index MSB
    // 9 bits for voxel index 
    // 20 bits for brick index LSB
    uint normal_index_3b_voxel_index_9b_brick_index_20b;
};
const uint NORMAL_BITS_OFFSET = 29;

// Must be kept in sync with src/modules/voxel_rt/ray_pipeline_types.zig RayShading
struct RayShading {
    vec3 color;
    uint pixel_coord;
};
// Must be kept in sync with src/modules/voxel_rt/ray_pipeline_types.zig RayHash
struct RayHash {
    uint value;
};

const uint AXIS_X_LEFT_INDEX = 0;
const uint AXIS_X_RIGHT_INDEX = 3;
const uint AXIS_Y_DOWN_INDEX = 1;
const uint AXIS_Y_UP_INDEX = 4;
const uint AXIS_Z_FRONT_INDEX = 2;
const uint AXIS_Z_BACK_INDEX = 5;

vec3 RayAt(Ray r, float t) {
    // instruction for: t * dir + origin
    return fma(vec3(t), r.direction, r.origin);
}

// Must be kept in sync with src/modules/voxel_rt/ray_pipeline_types.zig Material
const uint MAT_T_LAMBERTIAN = 0;
const uint MAT_T_METAL = 1;
const uint MAT_T_DIELECTRIC = 2;
struct Material {
    vec3 albedo;
    uint type;
    /// Lambertian: ignored
    /// Metal:      fizz value
    /// Dielectric: interal reflection value
    float type_value;
};
Material Vec4ToMaterial(vec4 vec) {
    const vec2 unpack = unpackHalf2x16(floatBitsToUint(vec.a));
    const uint type = floatBitsToUint(unpack.x);
    const float type_value = unpack.y;

    return Material(
        vec.xyz,
        type,
        type_value
    );
}
