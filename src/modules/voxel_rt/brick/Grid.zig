// This file contains an implementaion of "Real-time Ray tracing and Editing of Large Voxel Scenes"
// source: https://dspace.library.uu.nl/handle/1874/315917

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const State = @import("State.zig");
const AtomicCount = State.AtomicCount;
const Worker = @import("Worker.zig");

pub const Config = struct {
    // Default value is all bricks
    brick_alloc: ?usize = null,
    base_t: f32 = 0.01,
    min_point: [3]f32 = [_]f32{ 0.0, 0.0, 0.0 },
    scale: f32 = 1.0,
    material_indices_per_brick: usize = 256,
    workers_count: usize = 4,
};

const BrickGrid = @This();

allocator: Allocator,
// grid state that is shared with the workers
state: *State,

worker_threads: []std.Thread,
workers: []Worker,

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

    const higher_dim_x = @intToFloat(f64, dim_x) * 0.25;
    const higher_dim_y = @intToFloat(f64, dim_y) * 0.25;
    const higher_dim_z = @intToFloat(f64, dim_z) * 0.25;
    const higher_order_grid = try allocator.alloc(u8, @floatToInt(usize, higher_dim_x * higher_dim_y * higher_dim_z));
    errdefer allocator.free(higher_order_grid);
    std.mem.set(u8, higher_order_grid, 0);

    // each mask has 32 entries
    const brick_statuses = try allocator.alloc(State.BrickStatusMask, (std.math.divCeil(u32, brick_count, 32) catch unreachable));
    errdefer allocator.free(brick_statuses);
    std.mem.set(State.BrickStatusMask, brick_statuses, .{ .bits = 0 });

    const brick_indices = try allocator.alloc(State.BrickIndex, brick_count);
    errdefer allocator.free(brick_indices);
    std.mem.set(State.BrickIndex, brick_indices, 0);

    const brick_alloc = config.brick_alloc orelse brick_count;
    const bricks = try allocator.alloc(State.Brick, brick_alloc);
    errdefer allocator.free(bricks);
    std.mem.set(State.Brick, bricks, .{ .solid_mask = 0, .index_type = .voxel_start_index, .index = 0 });

    const material_indices = try allocator.alloc(u8, bricks.len * math.min(512, config.material_indices_per_brick));
    errdefer allocator.free(material_indices);
    std.mem.set(u8, material_indices, 0);

    const min_point_base_t = blk: {
        const min_point = config.min_point;
        const base_t = config.base_t;
        var result: [4]f32 = undefined;
        for (min_point) |axis, i| {
            result[i] = axis;
        }
        result[3] = base_t;
        break :blk result;
    };
    const max_point_scale = blk: {
        var result = [4]f32{
            min_point_base_t[0] + @intToFloat(f32, dim_x) * config.scale,
            min_point_base_t[1] + @intToFloat(f32, dim_y) * config.scale,
            min_point_base_t[2] + @intToFloat(f32, dim_z) * config.scale,
            config.scale,
        };
        break :blk result;
    };

    const state = try allocator.create(State);
    errdefer allocator.destroy(state);

    // initialize all delta structures
    // these are used to track changes that should be pushed to GPU
    var higher_order_grid_delta = try allocator.create(State.DeviceDataDelta);
    errdefer allocator.destroy(higher_order_grid_delta);
    higher_order_grid_delta.* = State.DeviceDataDelta.init();

    var brick_statuses_deltas = try allocator.alloc(State.DeviceDataDelta, config.workers_count);
    errdefer allocator.free(brick_statuses_deltas);
    std.mem.set(State.DeviceDataDelta, brick_statuses_deltas, State.DeviceDataDelta.init());

    var brick_indices_deltas = try allocator.alloc(State.DeviceDataDelta, config.workers_count);
    errdefer allocator.free(brick_indices_deltas);
    std.mem.set(State.DeviceDataDelta, brick_indices_deltas, State.DeviceDataDelta.init());

    const bricks_delta = State.DeviceDataDelta.init();

    var material_indices_deltas = try allocator.alloc(State.DeviceDataDelta, config.workers_count);
    errdefer allocator.free(material_indices_deltas);
    std.mem.set(State.DeviceDataDelta, material_indices_deltas, State.DeviceDataDelta.init());

    const work_segment_size = try std.math.divCeil(u32, dim_x, @intCast(u32, config.workers_count));

    state.* = .{
        .higher_order_grid_delta = higher_order_grid_delta,
        .material_indices_deltas = material_indices_deltas,
        .higher_order_grid_mutex = .{},
        .higher_order_grid = higher_order_grid,
        .brick_statuses = brick_statuses,
        .brick_indices = brick_indices,
        .brick_statuses_deltas = brick_statuses_deltas,
        .brick_indices_deltas = brick_indices_deltas,
        .bricks_delta = bricks_delta,
        .bricks = bricks,
        .material_indices = material_indices,
        .active_bricks = AtomicCount.init(0),
        .work_segment_size = work_segment_size,
        .device_state = State.Device{
            .voxel_dim_x = dim_x * 8,
            .voxel_dim_y = dim_y * 8,
            .voxel_dim_z = dim_z * 8,
            .dim_x = dim_x,
            .dim_y = dim_y,
            .dim_z = dim_z,
            .higher_dim_x = @floatToInt(u32, @ceil(higher_dim_x)),
            .higher_dim_y = @floatToInt(u32, @ceil(higher_dim_y)),
            .higher_dim_z = @floatToInt(u32, @ceil(higher_dim_z)),
            .min_point_base_t = min_point_base_t,
            .max_point_scale = max_point_scale,
        },
    };

    var workers = try allocator.alloc(Worker, config.workers_count);
    errdefer allocator.free(workers);

    var worker_threads = try allocator.alloc(std.Thread, config.workers_count);
    errdefer allocator.free(worker_threads);
    for (worker_threads) |*thread, i| {
        workers[i] = try Worker.init(i, config.workers_count, state, allocator, 4096);
        thread.* = try std.Thread.spawn(.{}, Worker.work, .{&workers[i]});
    }

    return BrickGrid{
        .allocator = allocator,
        .state = state,
        .worker_threads = worker_threads,
        .workers = workers,
    };
}

/// Clean up host memory, does not account for device
pub fn deinit(self: BrickGrid) void {
    // signal each worker to finish
    for (self.workers) |*worker| {
        // signal shutdown
        worker.*.shutdown.store(true, .SeqCst);
        // signal worker to wake up from idle state
        worker.wake_event.signal();
    }
    // wait for each worker thread to finish
    for (self.worker_threads) |thread| {
        thread.join();
    }

    self.allocator.free(self.state.higher_order_grid);
    self.allocator.free(self.state.brick_statuses);
    self.allocator.free(self.state.brick_indices);
    self.allocator.free(self.state.bricks);
    self.allocator.free(self.state.material_indices);

    self.allocator.destroy(self.state.higher_order_grid_delta);
    self.allocator.free(self.state.brick_statuses_deltas);
    self.allocator.free(self.state.brick_indices_deltas);
    self.allocator.free(self.state.material_indices_deltas);

    self.allocator.free(self.worker_threads);
    self.allocator.free(self.workers);

    self.allocator.destroy(self.state);
}

/// Force workers to sleep.
/// Can be useful if spurvious changes to the grid cause thread contention
pub fn sleepWorkers(self: *BrickGrid) void {
    for (self.workers) |*worker| {
        worker.*.sleep.store(true, .SeqCst);
    }
}

/// Wake workers after forcing sleep.
pub fn wakeWorkers(self: *BrickGrid) void {
    for (self.workers) |*worker| {
        worker.*.sleep.store(false, .SeqCst);
        worker.*.wake_event.signal();
    }
}

/// Asynchrounsly (thread safe) insert a brick at coordinate x y z
/// this function will cause panics if you insert out of bounds
/// currently no way of checking if insert completes
pub fn insert(self: *BrickGrid, x: usize, y: usize, z: usize, material_index: u8) void {
    // find a workers that should be assigned insert
    const worker_index = blk: {
        const grid_x = x / 8;
        break :blk grid_x / self.state.work_segment_size;
    };

    self.workers[worker_index].registerJob(Worker.Job{ .insert = .{
        .x = x,
        .y = y,
        .z = z,
        .material_index = material_index,
    } });
}
