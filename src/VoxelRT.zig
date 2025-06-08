const std = @import("std");
const Allocator = std.mem.Allocator;

const tracy = @import("ztracy");

const za = @import("zalgebra");
const Vec2 = @Vector(2, f32);

const render = @import("render.zig");
const Context = render.Context;

const Pipeline = @import("voxel_rt/Pipeline.zig");
pub const Camera = @import("voxel_rt/Camera.zig");
pub const Sun = @import("voxel_rt/Sun.zig");
pub const BrickGrid = @import("voxel_rt/brick/Grid.zig");
pub const GridState = @import("voxel_rt/brick/State.zig");
pub const Benchmark = @import("voxel_rt/Benchmark.zig");
pub const gpu_types = @import("voxel_rt/gpu_types.zig");
pub const terrain = @import("voxel_rt/terrain/terrain.zig");
pub const vox = @import("voxel_rt/vox/loader.zig");

pub const Config = struct {
    internal_resolution_width: u32 = 1280,
    internal_resolution_height: u32 = 720,
    pipeline: Pipeline.Config = .{},
    camera: Camera.Config = .{},
    sun: Sun.Config = .{},
};

const VoxelRT = @This();

camera: *Camera,
sun: *Sun,

brick_grid: *BrickGrid,
pipeline: Pipeline,

/// init VoxelRT, api takes ownership of the brick_grid
pub fn init(allocator: Allocator, ctx: Context, brick_grid: *BrickGrid, config: Config) !VoxelRT {
    const camera = try allocator.create(Camera);
    errdefer allocator.destroy(camera);
    camera.* = Camera.init(75, config.internal_resolution_width, config.internal_resolution_height, config.camera);

    const sun = try allocator.create(Sun);
    errdefer allocator.destroy(sun);
    sun.* = Sun.init(config.sun);

    var pipeline = try Pipeline.init(
        ctx,
        allocator,
        .{
            .width = config.internal_resolution_width,
            .height = config.internal_resolution_height,
        },
        brick_grid.state.*,
        camera,
        sun,
        config.pipeline,
    );
    errdefer pipeline.deinit(ctx);

    try pipeline.transferGridState(ctx, brick_grid.state.*);

    return VoxelRT{
        .camera = camera,
        .sun = sun,
        .brick_grid = brick_grid,
        .pipeline = pipeline,
    };
}

pub fn createBenchmark(self: *VoxelRT) Benchmark {
    return Benchmark.init(self.camera, self.brick_grid.state.*, self.sun.device_data.enabled > 0);
}

pub fn draw(self: *VoxelRT, ctx: Context, delta_time: f32) !void {
    try self.pipeline.draw(ctx, delta_time);
}

pub fn updateSun(self: *VoxelRT, delta_time: f32) void {
    self.sun.update(delta_time);
}

/// push the materials to GPU
pub fn pushMaterials(self: *VoxelRT, ctx: Context, materials: []const gpu_types.Material) !void {
    try self.pipeline.transferMaterials(ctx, 0, materials);
}

/// push the albedo to GPU
pub fn pushAlbedo(self: *VoxelRT, ctx: Context, albedos: []const gpu_types.Albedo) !void {
    try self.pipeline.transferAlbedos(ctx, 0, albedos);
}

/// flush all grid data to GPU
pub fn debugFlushGrid(self: *VoxelRT, ctx: Context) void {
    if (@import("builtin").mode != .Debug) {
        @compileError("calling " ++ @src().fn_name ++ " in " ++ @tagName(@import("builtin").mode));
    }

    self.pipeline.transferBrickStatuses(ctx, 0, self.brick_grid.state.brick_statuses) catch unreachable;
    self.pipeline.transferBrickIndices(ctx, 0, self.brick_grid.state.brick_indices) catch unreachable;
    self.pipeline.transferBricks(ctx, 0, self.brick_grid.state.bricks) catch unreachable;
    self.pipeline.transferMaterialIndices(ctx, 0, self.brick_grid.state.material_indices) catch unreachable;
}

/// update grid device data based on changes
pub fn updateGridDelta(self: *VoxelRT, ctx: Context) !void {
    {
        const transfer_zone = tracy.ZoneN(@src(), "grid type transfer");
        defer transfer_zone.End();

        const delta = &self.brick_grid.state.brick_statuses_delta;
        delta.mutex.lock();
        defer delta.mutex.unlock();

        if (delta.state == .active) {
            try self.pipeline.transferBrickStatuses(ctx, delta.from, self.brick_grid.state.brick_statuses[delta.from..delta.to]);
            delta.resetDelta();
        }
    }
    {
        const transfer_zone = tracy.ZoneN(@src(), "grid index transfer");
        defer transfer_zone.End();

        const delta = &self.brick_grid.state.brick_indices_delta;
        delta.mutex.lock();
        defer delta.mutex.unlock();

        if (delta.state == .active) {
            try self.pipeline.transferBrickIndices(ctx, delta.from, self.brick_grid.state.brick_indices[delta.from..delta.to]);
            delta.resetDelta();
        }
    }
    {
        const transfer_zone = tracy.ZoneN(@src(), "bricks occupancy transfer");
        defer transfer_zone.End();

        const delta = &self.brick_grid.state.bricks_occupancy_delta;
        delta.mutex.lock();
        defer delta.mutex.unlock();

        if (delta.state == .active) {
            try self.pipeline.transferBrickOccupancy(ctx, delta.from, self.brick_grid.state.brick_occupancy[delta.from..delta.to]);
            delta.resetDelta();
        }
    }
    {
        const transfer_zone = tracy.ZoneN(@src(), "bricks start indices transfer");
        defer transfer_zone.End();

        const delta = &self.brick_grid.state.bricks_start_indices_delta;
        delta.mutex.lock();
        defer delta.mutex.unlock();

        if (delta.state == .active) {
            try self.pipeline.transferBrickStartIndex(ctx, delta.from, self.brick_grid.state.brick_start_indices[delta.from..delta.to]);
            delta.resetDelta();
        }
    }
    {
        const transfer_zone = tracy.ZoneN(@src(), "material indices transfer");
        defer transfer_zone.End();
        const delta = &self.brick_grid.state.material_indices_delta;
        delta.mutex.lock();
        defer delta.mutex.unlock();

        if (delta.state == .active) {
            try self.pipeline.transferMaterialIndices(ctx, delta.from, self.brick_grid.state.material_indices[delta.from..delta.to]);
            delta.resetDelta();
        }
    }
}

pub fn deinit(self: VoxelRT, allocator: Allocator, ctx: Context) void {
    allocator.destroy(self.camera);
    allocator.destroy(self.sun);
    self.pipeline.deinit(ctx);
}
