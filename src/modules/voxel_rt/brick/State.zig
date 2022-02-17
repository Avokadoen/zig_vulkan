const std = @import("std");
const AtomicCount = std.atomic.Atomic(usize);
const Mutex = std.Thread.Mutex;

const BucketStorage = @import("./BucketStorage.zig");

// uniform binding: 2
pub const Device = extern struct {
    dim_x: u32,
    dim_y: u32,
    dim_z: u32,
    higher_dim_x: u32,
    higher_dim_y: u32,
    higher_dim_z: u32,
    padding: u32,
    max_ray_iteration: u32,
    // holds the min point, and the base t advance
    // base t advance dictate the minimum stretch of distance a ray can go for each iteration
    // at 0.1 it will move atleast 10% of a given voxel
    min_point_base_t: [4]f32,
    // holds the max_point, and the brick scale
    max_point_scale: [4]f32,
};

// pub const Unloaded = packed struct {
//     lod_color: u24,
//     flags: u6,
// };

// TODO: move types?
pub const GridEntry = packed struct {
    pub const Type = enum(u2) {
        empty = 0,
        loaded,
        unloaded,
    };
    @"type": Type,
    data: u30,
};

pub const Brick = packed struct {
    /// maps to a voxel grid of 8x8x8
    solid_mask: i512,
    material_index: u32,
    lod_material_index: u32,
};

const State = @This();

higher_order_grid_mutex: Mutex,
/// used to accelerate ray traversal over large empty distances 
/// a entry is used to check if any brick in a 4x4x4 segment should be checked for hits or if nothing is set
higher_order_grid: []u8,

grid: []GridEntry,
bricks: []Brick,

// assigned through a bucket
material_indices: []u8,

/// how many bricks are used in the grid, keep in mind that this is used in a multithread context
active_bricks: AtomicCount,

device_state: Device,
