// This file contains an implementaion of "Real-time Ray tracing and Editing of Large Voxel Scenes"
// source: https://dspace.library.uu.nl/handle/1874/315917

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const State = @import("State.zig");
const AtomicCount = State.AtomicCount;
const MaterialAllocator = @import("MaterialAllocator.zig");

pub const Config = struct {
    // Default value is all bricks
    brick_alloc: ?usize = null,
    base_t: f32 = 0.01,
    min_point: [3]f32 = [_]f32{ 0.0, 0.0, 0.0 },
    scale: f32 = 1.0,
    workers_count: usize = 4,
};

const BrickGrid = @This();

allocator: Allocator,
// grid state that is shared with the workers
state: *State,
material_allocator: *MaterialAllocator,

/// Initialize a BrickGrid that can be raytraced
/// @param:
///     - allocator: used to allocate bricks and the grid, also to clean up these in deinit
///     - dim_x:     how many bricks *maps* (or chunks) in x dimension
///     - dim_y:     how many bricks *maps* (or chunks) in y dimension
///     - dim_z:     how many bricks *maps* (or chunks) in z dimension
///     - config:    config options for the brickmap
pub fn init(allocator: Allocator, dim_x: u32, dim_y: u32, dim_z: u32, config: Config) !BrickGrid {
    std.debug.assert(config.workers_count > 0);
    std.debug.assert(dim_x * dim_y * dim_z > 0);

    const brick_count = dim_x * dim_y * dim_z;

    // TODO: configure higher order brick count
    const higher_dim_x = @as(f64, @floatFromInt(dim_x)) * 0.25;
    const higher_dim_y = @as(f64, @floatFromInt(dim_y)) * 0.25;
    const higher_dim_z = @as(f64, @floatFromInt(dim_z)) * 0.25;
    const higher_order_grid = try allocator.alloc(u8, @intFromFloat(@ceil(higher_dim_x * higher_dim_y * higher_dim_z)));
    errdefer allocator.free(higher_order_grid);
    @memset(higher_order_grid, 0);

    // each mask has 32 entries
    const brick_statuses = try allocator.alloc(State.BrickStatusMask, (std.math.divCeil(u32, brick_count, 32) catch unreachable));
    errdefer allocator.free(brick_statuses);
    @memset(brick_statuses, .{ .bits = 0 });

    const brick_indices = try allocator.alloc(State.IndexToBrick, brick_count);
    errdefer allocator.free(brick_indices);
    @memset(brick_indices, 0);

    const brick_alloc = config.brick_alloc orelse brick_count;

    const brick_occupancy = try allocator.alloc(u8, brick_alloc * State.brick_bytes);
    errdefer allocator.free(brick_occupancy);
    @memset(brick_occupancy, 0);

    const brick_start_indices = try allocator.alloc(State.Brick.StartIndex, brick_alloc);
    errdefer allocator.free(brick_start_indices);
    @memset(brick_start_indices, State.Brick.unset_index);

    const packed_material_index_count = (brick_alloc * State.brick_bits) / @sizeOf(State.PackedMaterialIndices);
    const material_indices = try allocator.alloc(State.PackedMaterialIndices, packed_material_index_count);
    errdefer allocator.free(material_indices);
    @memset(material_indices, 0);

    const min_point_base_t = blk: {
        const min_point = config.min_point;
        const base_t = config.base_t;
        var result: [4]f32 = undefined;
        @memcpy(result[0..3], &min_point);
        result[3] = base_t;
        break :blk result;
    };
    const max_point_scale = [4]f32{
        min_point_base_t[0] + @as(f32, @floatFromInt(dim_x)) * config.scale,
        min_point_base_t[1] + @as(f32, @floatFromInt(dim_y)) * config.scale,
        min_point_base_t[2] + @as(f32, @floatFromInt(dim_z)) * config.scale,
        config.scale,
    };

    const work_segment_size = try std.math.divCeil(u32, dim_x, @intCast(config.workers_count));

    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    state.* = .{
        .higher_order_grid_mutex = .{},
        .higher_order_grid = higher_order_grid,
        .brick_statuses = brick_statuses,
        .brick_indices = brick_indices,
        .brick_occupancy = brick_occupancy,
        .brick_start_indices = brick_start_indices,
        .material_indices = material_indices,
        .active_bricks = AtomicCount.init(0),
        .work_segment_size = work_segment_size,
        .device_state = State.Device{
            .voxel_dim_x = dim_x * State.brick_dimension,
            .voxel_dim_y = dim_y * State.brick_dimension,
            .voxel_dim_z = dim_z * State.brick_dimension,
            .dim_x = dim_x,
            .dim_y = dim_y,
            .dim_z = dim_z,
            .higher_dim_x = @intFromFloat(higher_dim_x),
            .higher_dim_y = @intFromFloat(higher_dim_y),
            .higher_dim_z = @intFromFloat(higher_dim_z),
            .min_point_base_t = min_point_base_t,
            .max_point_scale = max_point_scale,
        },
    };

    const material_allocator = try allocator.create(MaterialAllocator);
    errdefer allocator.destroy(material_allocator);
    material_allocator.* = .init(material_indices.len);

    return BrickGrid{
        .allocator = allocator,
        .state = state,
        .material_allocator = material_allocator,
    };
}

/// Clean up host memory, does not account for device
pub fn deinit(self: BrickGrid) void {
    self.allocator.free(self.state.higher_order_grid);
    self.allocator.free(self.state.brick_statuses);
    self.allocator.free(self.state.brick_indices);
    self.allocator.free(self.state.brick_occupancy);
    self.allocator.free(self.state.brick_start_indices);
    self.allocator.free(self.state.material_indices);

    self.allocator.destroy(self.material_allocator);
    self.allocator.destroy(self.state);
}

// perform a insert in the grid
pub fn insert(self: *BrickGrid, x: usize, y: usize, z: usize, material_index: u8) void {
    std.debug.assert(x < self.state.device_state.voxel_dim_x);
    std.debug.assert(y < self.state.device_state.voxel_dim_y);
    std.debug.assert(z < self.state.device_state.voxel_dim_z);

    // Flip Y for more intutive coordinates
    const flipped_y = self.state.device_state.voxel_dim_y - 1 - y;

    const grid_index = gridAt(self.state.*.device_state, x, flipped_y, z);
    const brick_status_index = grid_index / 32;
    const brick_status_offset: u5 = @intCast(grid_index % 32);
    const brick_status = self.state.brick_statuses[brick_status_index].read(brick_status_offset);
    const brick_index = blk: {
        if (brick_status == .loaded) {
            break :blk self.state.brick_indices[grid_index];
        }

        // if entry is empty we need to populate the entry first
        const higher_grid_index = higherGridAt(self.state.*.device_state, x, flipped_y, z);
        self.state.higher_order_grid_mutex.lock();
        self.state.*.higher_order_grid[higher_grid_index] += 1;
        self.state.higher_order_grid_mutex.unlock();
        self.state.higher_order_grid_delta.registerDelta(higher_grid_index);

        // atomically fetch previous brick count and then add 1 to count
        break :blk self.state.*.active_bricks.fetchAdd(1, .monotonic);
    };

    const occupancy_from = brick_index * State.brick_bytes;
    const occupancy_to = brick_index * State.brick_bytes + State.brick_bytes;
    const brick_occupancy = self.state.brick_occupancy[occupancy_from..occupancy_to];
    var brick_material_index = &self.state.brick_start_indices[brick_index];

    // set the voxel to exist
    const nth_bit = voxelAt(x, flipped_y, z);

    // set the color information for the given voxel
    {
        // set the brick's material index if unset
        if (brick_material_index.* == State.Brick.unset_index) {
            // We store 4 material indices per word (1 byte per material)
            const material_entry = self.material_allocator.nextEntry();
            brick_material_index.value = @intCast(material_entry);
            brick_material_index.type = .voxel_start_index;

            // store brick material start index
            self.state.bricks_start_indices_delta.registerDelta(brick_index);
        }

        std.debug.assert(brick_material_index.type == .voxel_start_index);
        std.debug.assert(brick_material_index.value == std.mem.alignForward(u31, brick_material_index.value, 16));

        const new_voxel_material_index = brick_material_index.value * 4 + nth_bit;
        const material_indices_unpacked = std.mem.sliceAsBytes(self.state.*.material_indices);
        material_indices_unpacked[new_voxel_material_index] = material_index;

        // material indices are packed in 32bit on GPU and 8bit on CPU
        // we divide by four to store the correct *GPU* index.
        // Example: index 8 point to *byte* 8 on host, 8 points to *word* 8 on gpu.
        self.state.material_indices_delta.registerDelta(new_voxel_material_index / 4);
    }

    // set voxel
    const mask_index = nth_bit / @bitSizeOf(u8);
    const mask_bit: u3 = @intCast(@rem(nth_bit, @bitSizeOf(u8)));
    brick_occupancy[mask_index] |= @as(u8, 1) << mask_bit;

    // store brick changes
    self.state.bricks_occupancy_delta.registerDelta(occupancy_from + mask_index);

    // set the brick as loaded
    self.state.brick_statuses[brick_status_index].write(.loaded, brick_status_offset);
    self.state.brick_statuses_delta.registerDelta(brick_status_index);

    // register brick index
    self.state.brick_indices[grid_index] = brick_index;
    self.state.brick_indices_delta.registerDelta(grid_index);
}

// TODO: test
/// get brick index from global index coordinates
fn voxelAt(x: usize, y: usize, z: usize) State.BrickMapLog2 {
    const brick_x: usize = @rem(x, State.brick_dimension);
    const brick_y: usize = @rem(y, State.brick_dimension);
    const brick_z: usize = @rem(z, State.brick_dimension);
    return @intCast(brick_x + State.brick_dimension * (brick_z + State.brick_dimension * brick_y));
}

/// get grid index from global index coordinates
fn gridAt(device_state: State.Device, x: usize, y: usize, z: usize) usize {
    const grid_x: u32 = @intCast(x / State.brick_dimension);
    const grid_y: u32 = @intCast(y / State.brick_dimension);
    const grid_z: u32 = @intCast(z / State.brick_dimension);
    return @intCast(grid_x + device_state.dim_x * (grid_z + device_state.dim_z * grid_y));
}

/// get higher grid index from global index coordinates
fn higherGridAt(device_state: State.Device, x: usize, y: usize, z: usize) usize {
    // TODO: allow configuration of higher order grid
    const higher_order_size = State.brick_dimension * 4; // 4 bricks per higher order
    const higher_grid_x: u32 = @intCast(x / higher_order_size);
    const higher_grid_y: u32 = @intCast(y / higher_order_size);
    const higher_grid_z: u32 = @intCast(z / higher_order_size);
    return @intCast(higher_grid_x + device_state.higher_dim_x * (higher_grid_z + device_state.higher_dim_z * higher_grid_y));
}

/// count the set bits up to range_to (exclusive)
fn countBits(bits: [State.brick_bytes]u8, range_to: u32) u32 {
    var bit: State.BrickMap = @bitCast(bits);
    var count: State.BrickMap = 0;
    var i: u32 = 0;
    while (i < range_to and bit != 0) : (i += 1) {
        count += bit & 1;
        bit = bit >> 1;
    }
    return @intCast(count);
}
