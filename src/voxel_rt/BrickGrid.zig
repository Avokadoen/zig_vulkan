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
    solid_mask: i512,
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
active_bricks: usize,
device_state: Device,

/// Initialize a BrickGrid that can be raytraced 
/// @param:
///     - allocator:    used to allocate bricks and the grid, also to clean up these in deinit
///     - dim_x:        how many bricks *maps* (or chunks) in x dimension
///     - dim_y:        how many bricks *maps* (or chunks) in y dimension
///     - dim_z:        how many bricks *maps* (or chunks) in z dimension
///     - brick_alloc:  how many bricks *maps* should be allocated on the host and device
pub fn init(allocator: Allocator, dim_x: u32, dim_y: u32, dim_z: u32, config: Config) !BrickGrid {
    const grid = try allocator.alloc(GridEntry, dim_x * dim_y * dim_z);
    std.mem.set(GridEntry, grid, .{ .@"type" = .empty, .data = 0 });

    const brick_alloc = config.brick_alloc orelse (try std.math.divCeil(usize, grid.len, 2));
    const bricks = try allocator.alloc(Brick, brick_alloc);
    std.mem.set(Brick, bricks, .{ .solid_mask = 0, .material_index = 0, .lod_material_index = 0 });

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

    return BrickGrid{ .allocator = allocator, .grid = grid, .bricks = bricks, .active_bricks = 0, .device_state = Device{
        .dim_x = dim_x,
        .dim_y = dim_y,
        .dim_z = dim_z,
        .max_ray_iteration = max_ray_iteration,
        .min_point_base_t = min_point_base_t,
        .max_point_scale = max_point_scale,
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
    brick.solid_mask |= @as(i512, 1) << nth_bit;

    // set the color information for the given voxel
    // TODO: color/material index stuff ...

    // store changes
    self.bricks[@intCast(usize, entry.data)] = brick;
    self.grid[grid_index] = entry;
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

// TODO: remove/move any code under this comment

const Vec3 = @Vector(3, f32);
const IVec3 = @Vector(3, i32);

fn isInGrid(self: BrickGrid, point: IVec3) bool {
    return point[0] >= 0 and point[0] < self.device_state.dim_x and point[1] >= 0 and point[1] < self.device_state.dim_y and point[2] >= 0 and point[2] < self.device_state.dim_z;
}

fn posToIndex(self: BrickGrid, pos: IVec3) usize {
    return @intCast(usize, @intCast(u32, pos[0]) + self.device_state.dim_x * (@intCast(u32, pos[2]) + self.device_state.dim_z * @intCast(u32, pos[1])));
}

fn defineStepAndAxis(
    dir: Vec3,
    fposition: Vec3,
    position: IVec3,
    delta: Vec3,
    pos_step: *IVec3,
    axis_t: *Vec3,
    axis_value: usize,
) void {
    const a = axis_value;
    if (dir[a] < 0) {
        pos_step.*[a] = -1;
        axis_t.*[a] = (fposition[a] - @intToFloat(f32, position[a])) * delta[a];
    } else {
        pos_step.*[a] = 1;
        axis_t.*[a] = (@intToFloat(f32, position[a]) + 1 - fposition[a]) * delta[a];
    }
}

/// Traverses the brick grid and calculates any potential hit with the grid
pub fn brickHit(self: BrickGrid, fposition: Vec3, r_direction: Vec3) void {
    // Perform 3DDDA, source: https://lodev.org/cgtutor/raycasting.html
    // initialize values
    var position: IVec3 = [3]i32{ @floatToInt(i32, fposition[0]), @floatToInt(i32, fposition[1]), @floatToInt(i32, fposition[2]) };
    const delta = @fabs(@splat(3, @as(f32, 1.0)) / r_direction);
    var pos_step: IVec3 = undefined;
    var axis_t: Vec3 = undefined;
    {
        // define x
        defineStepAndAxis(r_direction, fposition, position, delta, &pos_step, &axis_t, 0);
        // define y
        defineStepAndAxis(r_direction, fposition, position, delta, &pos_step, &axis_t, 1);
        // define z
        defineStepAndAxis(r_direction, fposition, position, delta, &pos_step, &axis_t, 2);
    }

    std.debug.print("starting search\n", .{});
    // DDA loop
    while (self.isInGrid(position)) {
        const index = self.posToIndex(position);
        const entry = self.grid[index];
        if (entry.@"type" != .empty) {
            std.debug.print("found a brick at {d} {d} {d}\n", .{ position[0], position[1], position[2] });
            break;
        }

        var axis: usize = undefined;
        if (axis_t[0] < axis_t[1] and axis_t[0] < axis_t[2]) {
            axis = 0;
        } else if (axis_t[1] < axis_t[2]) {
            axis = 1;
        } else {
            axis = 2;
        }
        position[axis] += pos_step[axis];
        axis_t[axis] += delta[axis];
        std.debug.print("new position {d} {d} {d}\n", .{ position[0], position[1], position[2] });
    }
    std.debug.print("ending search\n", .{});
}
