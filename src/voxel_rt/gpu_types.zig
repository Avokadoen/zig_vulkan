const zlm = @import("zlm");

pub const NodeType = enum(u32) {
    empty = 0,
    parent,
    leaf,
};

// storage buffer, binding: 0
pub const Node = extern struct {
    value: u32,
    @"type": NodeType,
};

// storage buffer, binding: 1
pub const Material = extern struct { @"type": i32, attributee_index: i32, albedo_index: i32 };

// storage buffer, binding: 2
pub const Albedo = extern struct { value: zlm.Vec3 };

// storage buffer, binding: 3
pub const Metal = extern struct {
    fuzz: f32,
};

// storage buffer, binding: 4
pub const Dielectric = extern struct {
    ir: f32,
};

// storage buffer, binding: 5
pub const OctreeFloats = extern struct {
    min_point: zlm.Vec4,
    scale: f32,
    inv_scale: f32,
    inv_cell_count: f32,
};

// storage buffer, binding: 6
pub const OctreeInts = extern struct {
    max_depth: i32,
    max_iter: i32,
    cell_count: i32,
};

// uniform Camera
pub const Camera = extern struct {
    image_width: i32,
    image_height: i32,

    horizontal: zlm.Vec3,
    vertical: zlm.Vec3,

    lower_left_corner: zlm.Vec3,
    origin: zlm.Vec3,

    samples_per_pixel: i32,
    max_bounce: i32,
};
