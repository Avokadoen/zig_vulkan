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
    float t_value;
    vec3 color;
    uint pixel_coord;
};

vec3 RayAt(Ray r, float t) {
    // instruction for: t * dir + origin
    return fma(vec3(t), r.direction, r.origin);
}

vec3 BackgroundColor(Ray r) {
    float t = 0.5 * (r.direction.y + 1.0);
    vec3 background_color = fma(vec3(1.0 - t), vec3(1.0), t * vec3(0.5, 0.7, 1.0));
    return background_color;
}

struct RayBufferCursor {
    // how many rays that was written to the buffer in total
    int max_index;
    // where the last ray write occured
    int cursor;
};

struct HitRecord {
    vec3 point;
    vec3 normal;
    float t;
    uint index; 
};
