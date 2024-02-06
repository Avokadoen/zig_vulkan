const std = @import("std");
const Allocator = std.mem.Allocator;

const HostBrickState = @This();

const ray_pipeline_types = @import("../ray_pipeline_types.zig");
const Brick = ray_pipeline_types.Brick;
const BrickIndex = ray_pipeline_types.BrickIndex;
const BrickGridMetadata = ray_pipeline_types.BrickGridMetadata;
const BrickLimits = ray_pipeline_types.BrickLimits;
const Material = ray_pipeline_types.Material;

pub const material_index = u8;
pub const max_unique_materials = std.math.maxInt(material_index);

pub const DefinedMaterial = enum(u32) {
    dirt,
    water,
    glass,
    bronze,

    pub fn getValues() [material_count]ray_pipeline_types.Material {
        // This will cause compile time error if we return any undefined value which is good :)
        comptime {
            var materials: [material_count]ray_pipeline_types.Material = undefined;

            materials[@intFromEnum(DefinedMaterial.dirt)] = Material.lambertian([3]f32{ 0.490, 0.26667, 0.06667 });
            materials[@intFromEnum(DefinedMaterial.water)] = Material.dielectric([3]f32{ 0.117, 0.45, 0.85 }, 1.333);
            materials[@intFromEnum(DefinedMaterial.glass)] = Material.dielectric([3]f32{ 0.6, 0.63, 0.6 }, 1.52);
            materials[@intFromEnum(DefinedMaterial.bronze)] = Material.metal([3]f32{ 0.804, 0.498, 0.196 }, 0.45);

            return materials;
        }
    }
};

pub const material_count = @typeInfo(DefinedMaterial).Enum.fields.len;

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
voxel_material_indices: []material_index,
brick_set: []u8,
brick_dimensions: [3]u32,

inchoherent_bricks: std.AutoArrayHashMap(u32, void),

pub fn init(
    allocator: Allocator,
    grid_metadata: BrickGridMetadata,
    config: Config,
    comptime zero_out_mem: bool,
) !HostBrickState {
    std.debug.assert(config.brick_load_request_count != 0);
    std.debug.assert(config.brick_unload_request_count != 0);

    const brick_dimensions = [3]u32{
        @intFromFloat(@round(grid_metadata.dim[0])),
        @intFromFloat(@round(grid_metadata.dim[1])),
        @intFromFloat(@round(grid_metadata.dim[2])),
    };
    const grid_brick_count: usize = @intCast(brick_dimensions[0] * brick_dimensions[1] * brick_dimensions[2]);
    std.debug.assert(grid_brick_count <= ray_pipeline_types.RayHit.max_global_brick_index);

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

    // TODO: oof too much memory :(
    const voxel_material_indices = try allocator.alloc(material_index, grid_brick_count * 8 * 8 * 8);
    errdefer allocator.free(voxel_material_indices);
    if (zero_out_mem) {
        @memset(voxel_material_indices, 0);
    }

    const brick_set = try allocator.alloc(u8, try std.math.divCeil(usize, grid_brick_count, 8));
    errdefer allocator.free(brick_set);
    if (zero_out_mem) {
        @memset(brick_set, 0);
    }

    var inchoherent_bricks = std.AutoArrayHashMap(u32, void).init(allocator);
    errdefer inchoherent_bricks.deinit();

    try inchoherent_bricks.ensureTotalCapacity(config.brick_load_request_count);

    return HostBrickState{
        .allocator = allocator,
        .grid_metadata = grid_metadata,
        .brick_limits = brick_limits,
        .brick_indices = brick_indices,
        .bricks = bricks,
        .voxel_material_indices = voxel_material_indices,
        .brick_set = brick_set,
        .brick_dimensions = brick_dimensions,
        .inchoherent_bricks = inchoherent_bricks,
    };
}

pub fn deinit(self: *HostBrickState) void {
    self.allocator.free(self.brick_set);
    self.allocator.free(self.voxel_material_indices);
    self.allocator.free(self.bricks);
    self.allocator.free(self.brick_indices);

    self.inchoherent_bricks.deinit();
}

// TODO: Propagate changes to voxels in camera view, update brick set if needed
pub fn setVoxel(self: *HostBrickState, pos: [3]u32, material: DefinedMaterial) !void {
    const flipped_y = (self.brick_dimensions[1] * 8) - (pos[1] + 1);

    const brick_pos = [3]u32{
        pos[0] / 8,
        flipped_y / 8,
        pos[2] / 8,
    };
    const one_dim_brick_index = brick_pos[0] + self.brick_dimensions[0] * (brick_pos[2] + self.brick_dimensions[2] * brick_pos[1]);

    const voxel_pos = [3]u32{
        pos[0] % 8,
        flipped_y % 8,
        pos[2] % 8,
    };
    const one_dim_voxel_index = voxel_pos[0] + 8 * (voxel_pos[2] + 8 * voxel_pos[1]);
    self.voxel_material_indices[one_dim_brick_index * 512 + one_dim_voxel_index] = @intCast(@intFromEnum(material));

    {
        // update brick
        {
            const bit_offset: u9 = @intCast(one_dim_voxel_index);
            self.bricks[one_dim_brick_index].solid_mask |= @as(u512, 1) << bit_offset;
        }

        // update brick set
        {
            const bit_offset: u3 = @intCast(one_dim_brick_index % 8);
            self.brick_set[one_dim_brick_index / 8] |= @as(u8, 1) << bit_offset;
        }

        self.brick_indices[one_dim_brick_index] = BrickIndex{ .status = .loading, .request_count = 100, .index = @intCast(one_dim_brick_index) };
    }

    // mark brick as device incoherent
    try self.inchoherent_bricks.put(one_dim_brick_index, {});
}

// TODO: Propagate changes to voxels in camera view, update brick set if needed
pub fn unsetVoxel(self: *HostBrickState, pos: [3]u32) !void {
    const flipped_y = (self.brick_dimensions[1] * 8) - (pos[1] + 1);

    const brick_pos = [3]u32{
        pos[0] / 8,
        flipped_y / 8,
        pos[2] / 8,
    };
    const one_dim_brick_index = brick_pos[0] + self.brick_dimensions[0] * (brick_pos[2] + self.brick_dimensions[2] * brick_pos[1]);

    const voxel_pos = [3]u32{
        pos[0] % 8,
        flipped_y % 8,
        pos[2] % 8,
    };
    const one_dim_voxel_index = voxel_pos[0] + 8 * (voxel_pos[2] + 8 * voxel_pos[1]);

    {
        // update brick
        {
            const bit_offset: u9 = @intCast(one_dim_voxel_index);
            self.bricks[one_dim_brick_index].solid_mask &= ~(@as(u512, 1) << bit_offset);
        }

        // update brick set
        if (self.bricks[one_dim_brick_index].solid_mask == 0) {
            const bit_offset: u3 = @intCast(one_dim_brick_index % 8);
            self.brick_set[one_dim_brick_index / 8] &= ~(@as(u8, 1) << bit_offset);
        }

        self.brick_indices[one_dim_brick_index] = BrickIndex{ .status = .loading, .request_count = 100, .index = one_dim_brick_index };
    }

    // mark brick as device incoherent
    self.inchoherent_bricks.put(one_dim_brick_index, {});
}

/// Temporary debug scene
pub fn setupTestScene(self: *HostBrickState) !void {
    try self.setVoxel([_]u32{ 0, 0, 0 }, .bronze);
    try self.setVoxel([_]u32{ 1, 0, 0 }, .bronze);
    try self.setVoxel([_]u32{ 0, 1, 0 }, .bronze);
    try self.setVoxel([_]u32{ 0, 0, 1 }, .bronze);

    try self.setVoxel([_]u32{ 0, 8, 0 }, .glass);
    try self.setVoxel([_]u32{ 1, 8, 0 }, .glass);
    try self.setVoxel([_]u32{ 0, 9, 0 }, .glass);
    try self.setVoxel([_]u32{ 0, 8, 1 }, .glass);
    try self.setVoxel([_]u32{ 1, 9, 1 }, .glass);
    try self.setVoxel([_]u32{ 2, 9, 1 }, .glass);

    try self.setVoxel([_]u32{ 8, 8, 8 }, .water);
    try self.setVoxel([_]u32{ 9, 8, 8 }, .water);
    try self.setVoxel([_]u32{ 8, 9, 8 }, .water);
    try self.setVoxel([_]u32{ 8, 8, 9 }, .water);
    try self.setVoxel([_]u32{ 10, 10, 9 }, .water);

    // const grid_bricks = brick_blk: {
    //     const test_brick_all = Brick{
    //         .solid_mask = ~@as(u512, 0),
    //     };
    //     const test_brick_one = Brick{
    //         .solid_mask = @as(u512, 1),
    //     };
    //     // row bitmasks
    //     const test_brick_two = Brick{
    //         .solid_mask = @as(u512, 0b11),
    //     };
    //     const test_brick_three = Brick{
    //         .solid_mask = @as(u512, 0b111),
    //     };
    //     const test_brick_four = Brick{
    //         .solid_mask = @as(u512, 0b1111),
    //     };
    //     const test_brick_five = Brick{
    //         .solid_mask = @as(u512, 0b11111),
    //     };
    //     const test_brick_six = Brick{
    //         .solid_mask = @as(u512, 0b111111),
    //     };
    //     const test_brick_seven = Brick{
    //         .solid_mask = @as(u512, 0b1111111),
    //     };

    //     const bricks = [_]Brick{
    //         test_brick_all,
    //         test_brick_one,
    //         test_brick_two,
    //         test_brick_three,
    //         test_brick_four,
    //         test_brick_five,
    //         test_brick_six,
    //         test_brick_seven,
    //     };
    //     @memcpy(self.bricks[0..bricks.len], &bricks);

    //     break :brick_blk bricks;
    // };

    // {
    //     const brick_indices = [_]BrickIndex{
    //         BrickIndex{ .status = .loaded, .request_count = 100, .index = 0 },
    //         BrickIndex{ .status = .loaded, .request_count = 100, .index = 1 },
    //         BrickIndex{ .status = .loaded, .request_count = 100, .index = 2 },
    //         BrickIndex{ .status = .loaded, .request_count = 100, .index = 3 },
    //         BrickIndex{ .status = .loaded, .request_count = 100, .index = 4 },
    //         BrickIndex{ .status = .loaded, .request_count = 100, .index = 5 },
    //         BrickIndex{ .status = .loaded, .request_count = 100, .index = 6 },
    //         BrickIndex{ .status = .loaded, .request_count = 100, .index = 7 },
    //     };
    //     @memcpy(self.brick_indices[0..brick_indices.len], &brick_indices);
    // }

    // {
    //     self.brick_set[0] = 1 << 7 | 1 << 6 | 0 << 5 | 1 << 4 | 1 << 3 | 1 << 2 | 1 << 1 | 1 << 0;
    // }

    // {
    //     // currently we only set 4 materials in main so lets just rotate material
    //     for (grid_bricks, 0..) |brick, brick_index| {
    //         // assumes all bits are sequential
    //         for (0..@popCount(brick.solid_mask)) |voxel_index| {
    //             self.voxel_material_indices[brick_index * 512 + voxel_index] = @intCast(voxel_index % 4);
    //         }
    //     }
    // }
}
