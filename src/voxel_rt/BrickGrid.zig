// This file contains an implementaion of "Real-time Ray tracing and Editing of Large Voxel Scenes"
// source: https://dspace.library.uu.nl/handle/1874/315917

// TODO: move types?

// pub const Unloaded = packed struct {
//     lod_color: u24,
//     flags: u6,
// };

// buffer binding: 7
pub const GridEntry = packed struct {
    pub const Type = enum(u2) {
        empty = 0,
        loaded,
        unloaded,
    };
    @"type": Type,
    data: u30,
};

// buffer binding: 8
pub const Brick = packed struct {
    /// maps to a voxel grid of 8x8x8
    solid_mask: u512,
    material_index: u24,
    lod_material_index: u8,
};

// uniform binding: 2
pub const Device = extern struct {
    dim_x: u32,
    dim_y: u32,
    dim_z: u32,
    scale: f32,
    min_point: [4]f32,
};

const default_min_point = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
const default_scale = 1.0;

pub const Config = struct {
    // Will be enough to define half of all bricks if not specified
    brick_alloc: ?usize = null,
    min_point: ?[4]f32 = null,
    scale: ?f32 = null,
};

const std = @import("std");
const Allocator = std.mem.Allocator;

const BrickGrid = @This();

allocator: Allocator,

grid: []GridEntry,
bricks: []Brick,
active_bricks: usize,
device_state: Device,

/// Initialize a BrickGrid that can be raytraced 
/// @param:
///     - allocator:    used to allocate bricks and the grid, also to clean up these in deinit
///     - dim_x:        how many bricks *maps* in x dimension
///     - dim_y:        how many bricks *maps* in y dimension
///     - dim_z:        how many bricks *maps* in z dimension
///     - brick_alloc:  how many bricks *maps* should be allocated on the host and device
pub fn init(allocator: Allocator, dim_x: u32, dim_y: u32, dim_z: u32, config: Config) !BrickGrid {
    const grid = try allocator.alloc(GridEntry, dim_x * dim_y * dim_z);
    std.mem.set(GridEntry, grid, .{ .@"type" = .empty, .data = 0 });

    const brick_alloc = config.brick_alloc orelse (try std.math.divCeil(usize, grid.len, 2));
    const bricks = try allocator.alloc(Brick, brick_alloc);
    std.mem.set(Brick, bricks, .{ .solid_mask = 0, .material_index = 0, .lod_material_index = 0 });

    return BrickGrid{ .allocator = allocator, .grid = grid, .bricks = bricks, .active_bricks = 0, .device_state = Device{
        .dim_x = dim_x,
        .dim_y = dim_y,
        .dim_z = dim_z,
        .scale = config.scale orelse default_scale,
        .min_point = config.min_point orelse default_min_point,
    } };
}

/// Clean up host memory, does not account for device
pub fn deinit(self: BrickGrid) void {
    self.allocator.free(self.grid);
    self.allocator.free(self.bricks);
}

/// Insert a brick at coordinate x y z
pub fn insert(self: *BrickGrid, x: usize, y: usize, z: usize, material_index: u32) void {
    _ = material_index;

    const grid_index = self.gridAt(x, y, z);
    var entry = self.grid[grid_index];

    // if entry is empty we need to populate the entry first
    if (entry.@"type" == .empty) {
        entry = GridEntry{
            // TODO: loaded, or unloaded ??
            .@"type" = .loaded,
            .data = @intCast(u30, self.active_bricks),
        };
        self.active_bricks += 1;
    }

    var brick = self.bricks[@intCast(usize, entry.data)];

    // set the voxel to exist
    const nth_bit = brickAt(x, y, z);
    brick.solid_mask |= @as(u512, 1) << nth_bit;

    // set the color information for the given voxel
    // TODO: color/material index stuff ...

    // store changes
    self.bricks[@intCast(usize, entry.data)] = brick;
    self.grid[grid_index] = entry;
}

// TODO: test
/// get brick index from global index coordinates
inline fn brickAt(x: usize, y: usize, z: usize) u9 {
    const grid_x: usize = @rem(x, 8);
    const grid_y: usize = @rem(y, 8);
    const grid_z: usize = @rem(z, 8);
    return @intCast(u9, grid_x + 8 * (grid_y + 8 * grid_z));
}

// TODO: test
/// get grid index from global index coordinates
inline fn gridAt(self: BrickGrid, x: usize, y: usize, z: usize) usize {
    const grid_x: u32 = @intCast(u32, x / 8);
    const grid_y: u32 = @intCast(u32, y / 8);
    const grid_z: u32 = @intCast(u32, z / 8);
    return @intCast(usize, grid_x + self.device_state.dim_x * (grid_y + self.device_state.dim_y * grid_z));
}
