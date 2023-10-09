
TODO:
[x] update host draw pipeline
[x] update host emit pipeline
[x] update host miss pipeline
[x] update host scatter pipeline
[x] update host traverse pipeline
[ ] update host main pipeline
[ ] panic if max sets < 8

[ ] indirect dispatch



split hit record into multiple buffers:
 - Some order should be persistent, but maybe some can be lookup based? (not moved when sorting)
 - look into storageBuffer16BitAccess int16
https://developer.download.nvidia.com/video/gputechconf/gtc/2020/presentations/s21572-a-faster-radix-sort-implementation.pdf
https://web.archive.org/web/20210709113817/http://www.heterogeneouscompute.org/wordpress/wp-content/uploads/2011/06/RadixSort.pdf


# Emit:
struct Ray {
[w] vec3 origin;
[w] float internal_reflection;
[w] vec3 direction;
[w] float t_value;
};
struct RayHit {
[w] uint normal_4b_and_material_index_28b;
};
struct RayActive {
    bool is_active;  
}
struct RayShading {
[w] vec3 color;
[w] uint pixel_coord;
}
struct RayHash {
    uint value;
}

# Traverse:
struct Ray {
[rw]vec3 origin;
    float internal_reflection;
[r] vec3 direction;
[rw]float t_value;
};
struct RayHit {
[rw]uint normal_4b_and_material_index_28b;
};
struct RayActive {
[w] bool is_active;  
}
struct RayShading {
    vec3 color;
    uint pixel_coord;
}
struct RayHash {
    uint value;
}

# ??sort??
struct Ray {
[w] vec3 origin;
[w] float internal_reflection;
[w] vec3 direction;
[w] float t_value;
};
struct RayHit {
[w] uint normal_4b_and_material_index_28b;
};
struct RayActive {
[wr]bool is_active;  
}
struct RayShading {
[w] vec3 color;
[w] uint pixel_coord;
}
struct RayHash {
[w] uint value;
}


# Miss
struct Ray {
    vec3 origin;
    float internal_reflection;
[r] vec3 direction;
    float t_value;
};
struct RayHit {
    uint normal_4b_and_material_index_28b;
};
struct RayActive {
    bool is_active;  
}
struct RayShading {
[rw]vec3 color;
    uint pixel_coord;
}
struct RayHash {
    uint value;
}

# Scatter
struct Ray {
[rw]vec3 origin;
[rw]float internal_reflection;
[rw]vec3 direction;
    float t_value;
};
struct RayHit {
[r] uint normal_4b_and_material_index_28b;
};
struct RayActive {
    bool is_active;  
}
struct RayShading {
[rw]vec3 color;
    uint pixel_coord;
}
struct RayHash {
    uint value;
}

# Hash ray
struct Ray {
[r] vec3 origin;
    float internal_reflection;
[r] vec3 direction;
    float t_value;
};
struct RayHit {
    uint normal_4b_and_material_index_28b;
};
struct RayActive {
    bool is_active;  
}
struct RayShading {
    vec3 color;
    uint pixel_coord;
}
struct RayHash {
[w] uint value;
}


# Sort on Hash
struct Ray {
[rw]vec3 origin;
[rw]float internal_reflection;
[rw]vec3 direction;
[rw]float t_value;
};
struct RayHit {
[rw]uint normal_4b_and_material_index_28b;
};
struct RayActive {
[rw]bool is_active;  
}
struct RayShading {
[rw]vec3 color;
[rw]uint pixel_coord;
}
struct RayHash {
[rw]uint value;
}


# Draw
struct Ray {
    vec3 origin;
    float internal_reflection;
    vec3 direction;
    float t_value;
};
struct RayHit {
    uint normal_4b_and_material_index_28b;
};
struct RayActive {
    bool is_active;  
}
struct RayShading {
[r] vec3 color;
[r] uint pixel_coord;
}
struct RayHash {
    uint value;
}
