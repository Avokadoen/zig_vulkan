const std = @import("std");
const Allocator = std.mem.Allocator;

const HostBrickState = @This();

const ray_pipeline_types = @import("../ray_pipeline_types.zig");
const Brick = ray_pipeline_types.Brick;
const BrickIndex = ray_pipeline_types.BrickIndex;
const BrickGridMetadata = ray_pipeline_types.BrickGridMetadata;
const BrickLimits = ray_pipeline_types.BrickLimits;
const Material = ray_pipeline_types.Material;

pub const max_unique_materials = std.math.maxInt(u8);

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
grid_materials: [max_unique_materials]Material,

pub fn init(
    allocator: Allocator,
    grid_metadata: BrickGridMetadata,
    grid_materials: [max_unique_materials]Material,
    config: Config,
    comptime zero_out_mem: bool,
) !HostBrickState {
    const grid_brick_count: usize = @intFromFloat(grid_metadata.dim[0] * grid_metadata.dim[1] * grid_metadata.dim[2]);

    const brick_limits = BrickLimits{
        .max_load_request_count = config.brick_load_request_count,
        .load_request_count = 0,
        .max_unload_request_count = config.brick_unload_request_count,
        .unload_request_count = 0,
        .max_active_bricks = @intCast(grid_brick_count), // TODO: reduce, not supposed to be the full grid!
        .active_bricks = 0,
    };

    const brick_indices = try allocator.alloc(BrickIndex, grid_brick_count);
    errdefer allocator.free(brick_indices);
    if (zero_out_mem) {
        @memset(brick_indices, BrickIndex{
            .status = BrickIndex.Status.unloaded,
            .request_count = 0,
            .index = 0,
        });
    }

    const bricks = try allocator.alloc(Brick, grid_brick_count);
    errdefer allocator.free(bricks);
    if (zero_out_mem) {
        @memset(bricks, Brick{
            .solid_mask = 0,
        });
    }

    const brick_set = try allocator.alloc(u8, try std.math.divCeil(usize, grid_brick_count, 8));
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
        .grid_materials = grid_materials,
    };
}

pub fn deinit(self: HostBrickState) void {
    self.allocator.free(self.brick_set);
    self.allocator.free(self.bricks);
    self.allocator.free(self.brick_indices);
}

/// Temporary debug scene
pub fn setupTestScene(self: *HostBrickState) void {
    {
        const test_brick_all = Brick{
            .solid_mask = ~@as(u512, 0),
        };
        const test_brick_one = Brick{
            .solid_mask = @as(u512, 1),
        };
        // row bitmasks
        const test_brick_two = Brick{
            .solid_mask = @as(u512, 0b11),
        };
        const test_brick_three = Brick{
            .solid_mask = @as(u512, 0b111),
        };
        const test_brick_four = Brick{
            .solid_mask = @as(u512, 0b1111),
        };
        const test_brick_five = Brick{
            .solid_mask = @as(u512, 0b11111),
        };
        const test_brick_six = Brick{
            .solid_mask = @as(u512, 0b111111),
        };
        const test_brick_seven = Brick{
            .solid_mask = @as(u512, 0b1111111),
        };

        const bricks = [_]Brick{
            test_brick_all,
            test_brick_one,
            test_brick_two,
            test_brick_three,
            test_brick_four,
            test_brick_five,
            test_brick_six,
            test_brick_seven,
        };
        @memcpy(self.bricks[0..bricks.len], &bricks);
    }

    {
        const brick_indices = [_]BrickIndex{
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 1 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 2 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 7 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 5 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 0 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 3 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 4 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 6 },
        };
        @memcpy(self.brick_indices[0..brick_indices.len], &brick_indices);
    }

    {
        self.brick_set[0] = 1 << 7 | 1 << 6 | 0 << 5 | 1 << 4 | 1 << 3 | 1 << 2 | 1 << 1 | 1 << 0;
    }
}
