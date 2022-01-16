// This file contains an implementaion of "Real-time Ray tracing and Editing of Large Voxel Scenes"
// source: https://dspace.library.uu.nl/handle/1874/315917

// TODO: move types?

const Material = @import("gpu_types.zig").Material;

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

const unset_material = std.math.maxInt(u24);

// buffer binding: 8
pub const Brick = packed struct {
    /// maps to a voxel grid of 8x8x8
    solid_mask: i512,
    // index for index
    material_index: u24,
    lod_material_index: u8,
};

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

const default_scale: f32 = 1.0;
const default_base_t: f32 = 0.01;
const default_min_point = [3]f32{ 0.0, 0.0, 0.0 };

pub const Config = struct {
    // Default value is enough to define half of all bricks
    brick_alloc: ?usize = null,
    base_t: ?f32 = null,
    min_point: ?[3]f32 = null,
    // Default is enough to iter paralell the longest axis
    max_ray_iteration: ?u32 = null,
    scale: ?f32 = null,
};

const std = @import("std");
const Allocator = std.mem.Allocator;

const BrickGrid = @This();

allocator: Allocator,

grid: []GridEntry,
bricks: []Brick,

// TODO: buckets to track possible material slices for a brick
//       i.e N 8 buckets, M 16 buckets .. X 512 buckets
material_indices: []u8,

active_bricks: usize,
voxel_dim: [3]u32,
device_state: Device,

/// Initialize a BrickGrid that can be raytraced 
/// @param:
///     - allocator: used to allocate bricks and the grid, also to clean up these in deinit
///     - dim_x:     how many bricks *maps* (or chunks) in x dimension
///     - dim_y:     how many bricks *maps* (or chunks) in y dimension
///     - dim_z:     how many bricks *maps* (or chunks) in z dimension
///     - config:    config options for the brickmap
pub fn init(allocator: Allocator, dim_x: u32, dim_y: u32, dim_z: u32, config: Config) !BrickGrid {
    const grid = try allocator.alloc(GridEntry, dim_x * dim_y * dim_z);
    errdefer allocator.free(grid);
    std.mem.set(GridEntry, grid, .{ .@"type" = .empty, .data = 0 });

    const brick_alloc = config.brick_alloc orelse grid.len;
    const bricks = try allocator.alloc(Brick, brick_alloc);
    errdefer allocator.free(bricks);
    std.mem.set(Brick, bricks, .{ .solid_mask = 0, .material_index = unset_material, .lod_material_index = 0 });

    const material_indices = try allocator.alloc(u8, bricks.len * 512);
    errdefer allocator.free(material_indices);
    std.mem.set(u8, material_indices, 0);

    const min_point_base_t = blk: {
        const min_point = config.min_point orelse default_min_point;
        const base_t = config.base_t orelse default_base_t;
        var result: [4]f32 = undefined;
        for (min_point) |axis, i| {
            result[i] = axis;
        }
        result[3] = base_t;
        break :blk result;
    };
    const max_point_scale = blk: {
        const scale = config.scale orelse default_scale;
        // zig fmt: off
        var result = [4]f32{ 
            min_point_base_t[0] + @intToFloat(f32, dim_x) * scale, 
            min_point_base_t[1] + @intToFloat(f32, dim_y) * scale, 
            min_point_base_t[2] + @intToFloat(f32, dim_z) * scale, 
            scale 
        };
        // zig fmt: on
        break :blk result;
    };

    const max_ray_iteration = blk: {
        if (config.max_ray_iteration) |some| {
            break :blk some;
        }

        var biggest_axis = @maximum(dim_x, dim_y);
        biggest_axis = @maximum(biggest_axis, dim_z);
        break :blk biggest_axis * 8;
    };

    const voxel_dim = [3]u32{ dim_x * 8, dim_y * 8, dim_z * 8 };

    // zig fmt: off
    return BrickGrid{ 
        .allocator = allocator, 
        .grid = grid, 
        .bricks = bricks, 
        .material_indices = material_indices, 
        .active_bricks = 0, 
        .voxel_dim = voxel_dim, 
        .device_state = Device{
            .dim_x = dim_x,
            .dim_y = dim_y,
            .dim_z = dim_z,
            .max_ray_iteration = max_ray_iteration,
            .min_point_base_t = min_point_base_t,
            .max_point_scale = max_point_scale,
        } 
    };
    // zig fmt: on
}

/// Clean up host memory, does not account for device
pub fn deinit(self: BrickGrid) void {
    self.allocator.free(self.grid);
    self.allocator.free(self.bricks);
    self.allocator.free(self.material_indices);
}

pub const InsertError = error{ OutOfBoundsX, OutOfBoundsY, OutOfBoundsZ };
pub fn safeInsert(self: *BrickGrid, x: usize, y: usize, z: usize, material_index: u32) InsertError!void {
    if (x < 0 or x >= self.voxel_dim[0]) {
        return InsertError.OutOfBoundsX; // x was out of bounds
    }
    if (y < 0 or y >= self.voxel_dim[1]) {
        return InsertError.OutOfBoundsY; // y was out of bounds
    }
    if (z < 0 or z >= self.voxel_dim[2]) {
        return InsertError.OutOfBoundsZ; // z was out of bounds
    }
    @call(.{ .modifier = .always_inline }, insert, .{ self, x, y, z, material_index });
}

/// Insert a brick at coordinate x y z
/// this function will cause panics if you insert out of bounds, use safeInsert
/// if bound checks are required
pub fn insert(self: *BrickGrid, x: usize, y: usize, z: usize, material_index: u8) void {
    const actual_y = self.device_state.dim_y * 8 - 1 - y;

    const grid_index = self.gridAt(x, actual_y, z);
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
    const nth_bit = brickAt(x, actual_y, z);
    const was_set = brick.solid_mask & @as(i512, 1) << nth_bit;

    // set the color information for the given voxel
    { // shift material position voxels that are after this voxel
        if (brick.material_index == unset_material) {
            brick.material_index = (@intCast(u24, self.active_bricks) - 1);
        }
        const brick_index = brick.material_index * 512;
        const bits_before = countBits(brick.solid_mask, nth_bit);
        const bits_total = countBits(brick.solid_mask, 512);
        var i: u32 = bits_total;
        if (was_set == 0) {
            while (i > bits_before) : (i -= 1) {
                const base_index = brick_index + i;
                self.material_indices[base_index] = self.material_indices[base_index - 1];
            }
        }
        self.material_indices[brick_index + bits_before] = material_index;
    }

    // set voxel to set
    brick.solid_mask |= @as(i512, 1) << nth_bit;

    // store changes
    self.bricks[@intCast(usize, entry.data)] = brick;
    self.grid[grid_index] = entry;
}

inline fn countBits(bits: i512, range_to: u32) u32 {
    var bit = bits;
    var count: i512 = 0;
    var i: u32 = 0;
    while (i < range_to and bit != 0) : (i += 1) {
        count += bit & 1;
        bit = bit >> 1;
    }
    return @intCast(u32, count);
}

// TODO: test
/// get brick index from global index coordinates
inline fn brickAt(x: usize, y: usize, z: usize) u9 {
    const brick_x: usize = @rem(x, 8);
    const brick_y: usize = @rem(y, 8);
    const brick_z: usize = @rem(z, 8);
    return @intCast(u9, brick_x + 8 * (brick_z + 8 * brick_y));
}

// TODO: test
/// get grid index from global index coordinates
inline fn gridAt(self: BrickGrid, x: usize, y: usize, z: usize) usize {
    const grid_x: u32 = @intCast(u32, x / 8);
    const grid_y: u32 = @intCast(u32, y / 8);
    const grid_z: u32 = @intCast(u32, z / 8);
    return @intCast(usize, grid_x + self.device_state.dim_x * (grid_z + self.device_state.dim_z * grid_y));
}
