const std = @import("std");
const Allocator = std.mem.Allocator;

const HostBrickState = @This();

const ray_pipeline_types = @import("../ray_pipeline_types.zig");
const Brick = ray_pipeline_types.Brick;
const BrickIndex = ray_pipeline_types.BrickIndex;
const BrickGridMetadata = ray_pipeline_types.BrickGridMetadata;
const BrickLimits = ray_pipeline_types.BrickLimits;

pub const Config = struct {
    brick_load_request_count: c_uint = 1024,
    brick_unload_request_count: c_uint = 1024,
};

allocator: Allocator,

grid_metadata: BrickGridMetadata,
brick_limits: BrickLimits,
/// NOTE: data is not 100% coherent.
///       unloading indices is done on gpu so host is not signaled or coherent in this case
brick_indices: []BrickIndex,
bricks: []Brick,
brick_set: []u8,

pub fn init(
    allocator: Allocator,
    grid_metadata: BrickGridMetadata,
    config: Config,
    comptime zero_out_mem: bool,
) !HostBrickState {
    const brick_limits = BrickLimits{
        .max_load_request_count = config.brick_load_request_count,
        .load_request_count = 0,
        .max_unload_request_count = config.brick_unload_request_count,
        .unload_request_count = 0,
        .max_active_bricks = @intFromFloat(grid_metadata.dim[0] * grid_metadata.dim[1] * grid_metadata.dim[2]),
        .active_bricks = 0,
    };

    const voxel_count: usize = @intCast(brick_limits.max_active_bricks * 8 * 8 * 8);

    const brick_indices = try allocator.alloc(BrickIndex, voxel_count);
    errdefer allocator.free(brick_indices);
    if (zero_out_mem) {
        @memset(brick_indices, BrickIndex{
            .status = BrickIndex.Status.unloaded,
            .request_count = 0,
            .index = 0,
        });
    }

    const bricks = try allocator.alloc(Brick, voxel_count);
    errdefer allocator.free(bricks);
    if (zero_out_mem) {
        @memset(bricks, Brick{
            .solid_mask = 0,
        });
    }

    const brick_set = try allocator.alloc(u8, voxel_count / 8);
    errdefer allocator.free(brick_set);
    if (zero_out_mem) {
        @memset(brick_set, 0);
    }

    return HostBrickState{
        .allocator = allocator,
        .grid_metadata = grid_metadata,
        .brick_limits = brick_limits,
        .brick_indices = brick_indices,
        .bricks = bricks,
        .brick_set = brick_set,
    };
}

pub fn deinit(self: HostBrickState) void {
    self.allocator.free(self.brick_indices);
    self.allocator.free(self.bricks);
    self.allocator.free(self.brick_set);
}

pub inline fn getActiveBricks(self: HostBrickState) []const Brick {
    std.debug.assert(self.brick_limits.active_bricks >= 0);

    return self.bricks[0..@intCast(self.brick_limits.active_bricks)];
}

pub inline fn getActiveBrickIndices(self: HostBrickState) []const BrickIndex {
    std.debug.assert(self.brick_limits.active_bricks >= 0);

    return self.brick_indices[0..@intCast(self.brick_limits.active_bricks)];
}

// TODO: alignment issue?
pub inline fn getActiveBrickSets(self: HostBrickState) []const u1 {
    std.debug.assert(self.brick_limits.active_bricks >= 0);

    const bit_slice: [*]const u1 = @ptrCast(self.brick_set.ptr);
    return bit_slice[0..@intCast(self.brick_limits.active_bricks)];
}

/// Temporary debug scene
pub fn setupTestScene(self: *HostBrickState) void {
    self.brick_limits.active_bricks = 8;

    {
        const test_brick_none = Brick{
            .solid_mask = @as(u512, 0),
        };
        _ = test_brick_none;
        const test_brick_one = Brick{
            .solid_mask = @as(u512, 1),
        };
        const test_brick_row = Brick{
            .solid_mask = @as(u512, 0b01111111),
        };
        const test_brick_all = Brick{
            .solid_mask = ~@as(u512, 0),
        };

        const bricks = [_]Brick{
            test_brick_one,
            test_brick_all,
            test_brick_row,
            test_brick_one,
            test_brick_one,
            test_brick_one,
            test_brick_all,
            test_brick_one,
        };
        std.debug.assert(self.brick_limits.active_bricks == bricks.len);
        @memcpy(self.bricks[0..bricks.len], &bricks);
    }

    {
        const brick_indices = [_]BrickIndex{
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 0 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 1 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 2 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 3 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 4 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 5 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 6 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 7 },
        };
        std.debug.assert(self.brick_limits.active_bricks == brick_indices.len);
        @memcpy(self.brick_indices[0..brick_indices.len], &brick_indices);
    }

    {
        self.brick_set[0] = 1 << 7 | 1 << 6 | 0 << 5 | 1 << 4 | 1 << 3 | 1 << 2 | 1 << 1 | 1 << 0;
        std.debug.assert(self.brick_limits.active_bricks == 8);
    }
}
