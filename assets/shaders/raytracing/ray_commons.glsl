// Constants, TODO, move to another file
const int MAT_LAMBERTIAN = 0;
const int MAT_METAL = 1;
const int MAT_DIELECTRIC = 2;

const uint IGNORE_MAT_LAMBERTIAN = MAT_LAMBERTIAN;
const uint IGNORE_MAT_METAL = MAT_METAL;
const uint IGNORE_MAT_DIELECTRIC = MAT_DIELECTRIC;
const uint IGNORE_MAT_NONE = 3;

struct Ray {
    vec3 origin;
    float internal_reflection;
    vec3 direction;
    float padding;
    vec3 color;
    uint pixel_coord;
};

vec3 RayAt(Ray r, float t) {
    // instruction for: t * dir + origin
    return fma(vec3(t), r.direction, r.origin);
}

struct RayBufferCursor {
    // how many rays that was written to the buffer in total
    int max_index;
    // where the last ray write occured
    int cursor;
};

// must be kept in sync with TraverseRayPipeline.HitRecord
struct HitRecord {
    vec3 point;
    uint normal_4b_and_material_index_28b;
    vec3 ray_direction;
    float ray_internal_reflection;
    vec3 previous_color;
    uint pixel_coord;
};
