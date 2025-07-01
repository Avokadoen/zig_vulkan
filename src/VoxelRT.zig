const std = @import("std");
const Allocator = std.mem.Allocator;

const tracy = @import("ztracy");

const za = @import("zalgebra");
const Vec2 = @Vector(2, f32);

const ecez = @import("ecez");

const render = @import("render.zig");
const Context = render.Context;

const Pipeline = @import("voxel_rt/Pipeline.zig");
pub const camera = @import("voxel_rt/camera.zig");
pub const sun = @import("voxel_rt/sun.zig");
pub const BrickGrid = @import("voxel_rt/brick/Grid.zig");
pub const GridState = @import("voxel_rt/brick/State.zig");
pub const benchmark = @import("voxel_rt/benchmark.zig");
pub const gpu_types = @import("voxel_rt/gpu_types.zig");
pub const terrain = @import("voxel_rt/terrain/terrain.zig");
pub const vox = @import("voxel_rt/vox/loader.zig");

pub const EventArgument = @import("voxel_rt/event_arg.zig").EventArgument;

pub fn CreateEvents(comptime Storage: type) type {
    return struct {
        const BenchmarkSystems = benchmark.CreateSystems(Storage).systems;

        pub const events = struct {
            pub const voxel_rt_update = ecez.Event("voxel_rt_update", .{
                BenchmarkSystems.update,
                sun.systems.update,
            }, .{});
        };
    };
}

const VoxelRT = @This();

camera_entity: ecez.Entity,
sun_entity: ecez.Entity,

brick_grid: *BrickGrid,
pipeline: Pipeline,

pub const Config = struct {
    internal_resolution_width: u32 = 1280,
    internal_resolution_height: u32 = 720,
    pipeline: Pipeline.Config = .{},
    camera: camera.Config = .{},
    sun: sun.Config = .{},
};
/// init VoxelRT, api takes ownership of the brick_grid
pub fn init(allocator: Allocator, ctx: Context, brick_grid: *BrickGrid, comptime Storage: type, storage: *Storage, config: Config) !VoxelRT {
    const camera_entity = try storage.createEntity(camera.createCameraComponents(
        75,
        config.internal_resolution_width,
        config.internal_resolution_height,
        config.camera,
    ));

    const sun_entity = try storage.createEntity(sun.createSunComponents(config.sun));

    var pipeline = try Pipeline.init(
        ctx,
        allocator,
        Storage,
        storage,
        .{
            .width = config.internal_resolution_width,
            .height = config.internal_resolution_height,
        },
        brick_grid.state.*,
        camera_entity,
        sun_entity,
        config.pipeline,
    );
    errdefer pipeline.deinit(ctx);

    try pipeline.transferGridState(brick_grid.state.*);

    return VoxelRT{
        .camera_entity = camera_entity,
        .sun_entity = sun_entity,
        .brick_grid = brick_grid,
        .pipeline = pipeline,
    };
}

pub fn draw(self: *VoxelRT, ctx: Context, comptime Storage: type, storage: *Storage, delta_time: f32) !void {
    try self.pipeline.draw(ctx, Storage, storage, delta_time);
}

pub fn updateSun(self: *VoxelRT, comptime Storage: type, storage: *Storage, delta_time: f32) void {
    sun.update(self.sun_entity, storage, delta_time);
}

/// push the materials to GPU
pub fn pushMaterials(self: *VoxelRT, materials: []const gpu_types.Material) !void {
    try self.pipeline.transferMaterials(0, materials);
}

/// flush all grid data to GPU
pub fn debugFlushGrid(self: *VoxelRT, ctx: Context) void {
    if (@import("builtin").mode != .Debug) {
        @compileError("calling " ++ @src().fn_name ++ " in " ++ @tagName(@import("builtin").mode));
    }

    self.pipeline.transferBrickStatuses(ctx, 0, self.brick_grid.state.brick_statuses) catch unreachable;
    self.pipeline.transferBrickIndices(ctx, 0, self.brick_grid.state.brick_indices) catch unreachable;
    self.pipeline.transferBrickOccupancy(ctx, 0, self.brick_grid.state.brick_occupancy) catch unreachable;
    self.pipeline.transferBrickStartIndex(ctx, 0, self.brick_grid.state.brick_start_indices);
    self.pipeline.transferMaterialIndices(ctx, 0, self.brick_grid.state.material_indices) catch unreachable;
}

/// update grid device data based on changes
pub fn updateGridDelta(self: *VoxelRT) !void {
    {
        const transfer_zone = tracy.ZoneN(@src(), "grid type transfer");
        defer transfer_zone.End();

        const delta = &self.brick_grid.state.brick_statuses_delta;
        delta.mutex.lock();
        defer delta.mutex.unlock();

        if (delta.state == .active) {
            try self.pipeline.transferBrickStatuses(delta.from, self.brick_grid.state.brick_statuses[delta.from..delta.to]);
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
            try self.pipeline.transferBrickIndices(delta.from, self.brick_grid.state.brick_indices[delta.from..delta.to]);
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
            try self.pipeline.transferBrickOccupancy(delta.from, self.brick_grid.state.brick_occupancy[delta.from..delta.to]);
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
            try self.pipeline.transferBrickStartIndex(delta.from, self.brick_grid.state.brick_start_indices[delta.from..delta.to]);
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
            try self.pipeline.transferMaterialIndices(delta.from, self.brick_grid.state.material_indices[delta.from..delta.to]);
            delta.resetDelta();
        }
    }
}

pub fn deinit(self: VoxelRT, ctx: Context) void {
    self.pipeline.deinit(ctx);
}
