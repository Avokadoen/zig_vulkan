const std = @import("std");
const Allocator = std.mem.Allocator;

const tracy = @import("../tracy.zig");

const za = @import("zalgebra");
const Vec2 = @Vector(2, f32);

const render = @import("../modules/render.zig");
const Context = render.Context;

const Pipeline = @import("voxel_rt/Pipeline.zig");
pub const Camera = @import("voxel_rt/Camera.zig");
pub const BrickGrid = @import("voxel_rt/brick/Grid.zig");
pub const GridState = @import("voxel_rt/brick/State.zig");
pub const gpu_types = @import("voxel_rt/gpu_types.zig");
pub const terrain = @import("voxel_rt/terrain/terrain.zig");
pub const vox = @import("voxel_rt/vox/loader.zig");

pub const Config = struct {
    internal_resolution_width: u32 = 1280,
    internal_resolution_height: u32 = 720,
    pipeline: Pipeline.Config = .{},
    camera: Camera.Config = .{},
};

const VoxelRT = @This();

camera: *Camera,
brick_grid: *BrickGrid,
pipeline: Pipeline,

/// init VoxelRT, api takes ownership of the brick_grid
pub fn init(allocator: Allocator, ctx: Context, brick_grid: *BrickGrid, config: Config) !VoxelRT {
    const camera = try allocator.create(Camera);
    camera.* = Camera.init(75, config.internal_resolution_width, config.internal_resolution_height, config.camera);

    const pipeline = try Pipeline.init(
        ctx,
        allocator,
        .{
            .width = config.internal_resolution_width,
            .height = config.internal_resolution_height,
        },
        brick_grid.state.*,
        camera,
        config.pipeline,
    );
    errdefer pipeline.deinit(ctx);
    try pipeline.transferCamera(ctx, camera.*);

    try pipeline.transferGridState(ctx, brick_grid.state.*);
    const metals = [_]gpu_types.Metal{.{
        .fuzz = 0.45,
    }};
    try pipeline.transferMetals(ctx, 0, metals[0..]);
    const dielectrics = [_]gpu_types.Dielectric{
        .{
            .internal_reflection = 1.333, // water
        },
        .{
            .internal_reflection = 1.52, // glass
        },
    };
    try pipeline.transferDielectrics(ctx, 0, dielectrics[0..]);

    return VoxelRT{
        .camera = camera,
        .brick_grid = brick_grid,
        .pipeline = pipeline,
    };
}

pub fn draw(self: *VoxelRT, ctx: Context) !void {
    try self.pipeline.draw(ctx);
}

/// push the materials to GPU
pub fn pushMaterials(self: VoxelRT, ctx: Context, materials: []const gpu_types.Material) !void {
    try self.pipeline.transferMaterials(ctx, 0, materials);
}

/// push the albedo to GPU
pub fn pushAlbedo(self: VoxelRT, ctx: Context, albedos: []const gpu_types.Albedo) !void {
    try self.pipeline.transferAlbedos(ctx, 0, albedos);
}

/// a temporary way of pushing camera changes (TODO: update function)
pub fn debugMoveCamera(self: *VoxelRT, ctx: Context) !void {
    try self.pipeline.transferCamera(ctx, self.camera.*);
}

/// Push all terrain data to GPU
pub fn debugUpdateTerrain(self: *VoxelRT, ctx: Context) !void {
    try self.pipeline.transferHigherOrderGrid(ctx, 0, self.brick_grid.state.higher_order_grid);
    try self.pipeline.transferGridEntries(ctx, 0, self.brick_grid.state.bricks);
    try self.pipeline.transferBricks(ctx, 0, self.brick_grid.state.bricks);
    try self.pipeline.transferMaterialIndices(ctx, 0, self.brick_grid.state.material_indices);
}

/// update grid device data based on changes 
pub fn updateGridDelta(self: *VoxelRT, ctx: Context) !void {
    {
        const transfer_zone = tracy.ZoneN(@src(), "higher order transfer");
        defer transfer_zone.End();

        var delta = self.brick_grid.state.higher_order_grid_delta;
        delta.mutex.lock();
        defer delta.mutex.unlock();

        if (delta.state == .active) {
            try self.pipeline.transferHigherOrderGrid(ctx, delta.from, self.brick_grid.state.higher_order_grid[delta.from..delta.to]);
            delta.resetDelta();
        }
    }
    {
        const transfer_zone = tracy.ZoneN(@src(), "grid transfer");
        defer transfer_zone.End();
        for (self.brick_grid.state.grid_deltas) |*delta| {
            delta.mutex.lock();
            defer delta.mutex.unlock();

            if (delta.state == .active) {
                try self.pipeline.transferGridEntries(ctx, delta.from, self.brick_grid.state.grid[delta.from..delta.to]);
                delta.resetDelta();
            }
        }
    }
    {
        const transfer_zone = tracy.ZoneN(@src(), "bricks transfer");
        defer transfer_zone.End();
        for (self.brick_grid.state.bricks_deltas) |*delta| {
            delta.mutex.lock();
            defer delta.mutex.unlock();

            if (delta.state == .active) {
                try self.pipeline.transferBricks(ctx, delta.from, self.brick_grid.state.bricks[delta.from..delta.to]);
                delta.resetDelta();
            }
        }
    }
    {
        const transfer_zone = tracy.ZoneN(@src(), "material indices transfer");
        defer transfer_zone.End();
        for (self.brick_grid.state.material_indices_deltas) |*delta| {
            delta.mutex.lock();
            defer delta.mutex.unlock();

            if (delta.state == .active) {
                try self.pipeline.transferMaterialIndices(ctx, delta.from, self.brick_grid.state.material_indices[delta.from..delta.to]);
                delta.resetDelta();
            }
        }
    }
}

pub fn deinit(self: VoxelRT, allocator: Allocator, ctx: Context) void {
    allocator.destroy(self.camera);
    self.pipeline.deinit(ctx);
}
