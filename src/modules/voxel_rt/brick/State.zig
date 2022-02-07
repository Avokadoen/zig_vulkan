const std = @import("std");
const AtomicCount = std.atomic.Atomic(usize);

const BucketStorage = @import("./BucketStorage.zig");

// uniform binding: 2
pub const Device = extern struct {
    dim_x: u32,
    dim_y: u32,
    dim_z: u32,
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

grid: []GridEntry,
bricks: []Brick,

// TODO: ability to configure a size less then all voxels in the grid
bucket_storage: BucketStorage,
// assigned through a bucket
material_indices: []u8,

/// how many bricks are used in the grid, keep in mind that this is used in a multithread context
active_bricks: AtomicCount,

device_state: Device,
