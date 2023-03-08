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
    // TODO: Bitmask instead of single ignore value.
    //       Refactor needed to make material types 1, 2, 3 instead of 0, 1, 2
    uint material_ignore;
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

// TODO: remove
Ray CreateRay(vec3 origin, vec3 direction, uint material_ignore_mask) {
    const float internal_reflection = 1.0;
    return Ray(origin, internal_reflection, normalize(direction), material_ignore_mask, vec3(1), 0);
}

struct HitRecord {
    vec3 point;
    vec3 normal;
    float t;
    uint index; 
};
