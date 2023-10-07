
TODO:
[x] update host draw pipeline
[x] update host emit pipeline
[x] update host miss pipeline
[x] update host scatter pipeline
[x] update host traverse pipeline
[ ] update host main pipeline


split hit record into multiple buffers:
Some order should be persistent, but maybe some can be lookup based? (not moved when sorting)

# Emit:
struct Ray {
[x] vec3 point;
[x] float internal_reflection;
[x] vec3 ray_direction;
[x] float t_value;
};
struct RayHit {
0   uint normal_4b_and_material_index_28b;
    bool is_active;  
};
struct RayShading {
0   vec3 previous_color;
[x] uint pixel_coord;
}
struct RayHash {
    uint value;
}

# Traverse:
struct Ray {
[x] vec3 point;
    float internal_reflection;
[x] vec3 ray_direction;
[x] float t_value;
};
struct RayHit {
[x] uint normal_4b_and_material_index_28b;
[x] bool is_active;  
};
struct RayShading {
    vec3 previous_color;
    uint pixel_coord;
}
struct RayHash {
    uint value;
}

# ??sort??
struct Ray {
    vec3 point;
    float internal_reflection;
    vec3 ray_direction;
    float t_value;
};
struct RayHit {
    uint normal_4b_and_material_index_28b;
[x] bool is_active;  
};
struct RayShading {
    vec3 previous_color;
    uint pixel_coord;
}
struct RayHash {
    uint value;
}


# Miss
struct Ray {
    vec3 point;
    float internal_reflection;
    vec3 ray_direction;
    float t_value;
};
struct RayHit {
    uint normal_4b_and_material_index_28b;
    bool is_active;  
};
struct RayShading {
[x] vec3 previous_color;
    uint pixel_coord;
}
struct RayHash {
    uint value;
}

# Scatter
struct Ray {
[x] vec3 point;
[x] float internal_reflection;
[x] vec3 ray_direction;
    float t_value;
};
struct RayHit {
[x] uint normal_4b_and_material_index_28b;
    bool is_active;  
};
struct RayShading {
[x] vec3 previous_color;
    uint pixel_coord;
}
struct RayHash {
    uint value;
}

# Hash ray
struct Ray {
[x] vec3 point;
    float internal_reflection;
[x] vec3 ray_direction;
    float t_value;
};
struct RayHit {
    uint normal_4b_and_material_index_28b;
    bool is_active;  
};
struct RayShading {
    vec3 previous_color;
    uint pixel_coord;
}
struct RayHash {
[x] uint value;
}


# Sort on Hash
struct Ray {
    vec3 point;
    float internal_reflection;
    vec3 ray_direction;
    float t_value;
};
struct RayHit {
    uint normal_4b_and_material_index_28b;
    bool is_active;  
};
struct RayShading {
    vec3 previous_color;
    uint pixel_coord;
}
struct RayHash {
[x] uint value;
}


# Draw
struct Ray {
    vec3 point;
    float internal_reflection;
    vec3 ray_direction;
    float t_value;
};
struct RayHit {
    uint normal_4b_and_material_index_28b;
    bool is_active;  
};
struct RayShading {
[x] vec3 previous_color;
[x] uint pixel_coord;
}
struct RayHash {
    uint value;
}
