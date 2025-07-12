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
pub const grid = @import("voxel_rt/brick/grid.zig");
pub const grid_state = @import("voxel_rt/brick/state.zig");
pub const benchmark = @import("voxel_rt/benchmark.zig");
pub const gpu_types = @import("voxel_rt/gpu_types.zig");
pub const terrain = @import("voxel_rt/terrain/terrain.zig");
pub const vox = @import("voxel_rt/vox/loader.zig");

pub const EventArgument = @import("voxel_rt/event_arg.zig").EventArgument;

pub fn CreateEvents(comptime Storage: type) type {
    return struct {
        const BenchmarkSystems = benchmark.CreateSystems(Storage).systems;
        const GridSystems = grid.CreateSystems(Storage);
        const TerrainSystems = terrain.CreateSystems(Storage);

        pub const events = struct {
            pub const voxel_rt_update = ecez.Event("voxel_rt_update", .{
                TerrainSystems.generateTerrainChunk,
                TerrainSystems.removeGenerateChunkJob,
                GridSystems.insertGetActiveIndex,
                GridSystems.insertBrickStartIndexAndMaterial,
                GridSystems.insertBrickOccupancy,
                GridSystems.removeInsertComponent,
                GridSystems.updateStatusDeltaGridDelta,
                GridSystems.updateOccupancyDeltaGridDelta,
                GridSystems.updateIndicesDeltaGridDelta,
                GridSystems.updateMaterialIndicesDeltaGridDelta,
                GridSystems.updateStartIndicesDeltaGridDelta,
                BenchmarkSystems.update,
                sun.systems.update,
            }, .{});
        };
    };
}

const VoxelRT = @This();

pipeline: Pipeline,

pub const Config = struct {
    internal_resolution_width: u32 = 1280,
    internal_resolution_height: u32 = 720,
    pipeline: Pipeline.Config = .{},
    camera: camera.Config = .{},
    sun: sun.Config = .{},
};
/// init VoxelRT, api takes ownership of the brick_grid
pub fn init(
    allocator: Allocator,
    ctx: Context,
    comptime Storage: type,
    storage: *Storage,
    grid_entity: ecez.Entity,
    config: Config,
) !VoxelRT {
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
        grid_entity,
        camera_entity,
        sun_entity,
        config.pipeline,
    );
    errdefer pipeline.deinit(ctx);

    const grid_device_state = try storage.getComponent(grid_entity, grid_state.components.Device);
    try pipeline.transfer(
        0,
        .grid_device,
        &[_]grid_state.components.Device{grid_device_state},
    );

    return VoxelRT{
        .pipeline = pipeline,
    };
}

pub fn draw(self: *VoxelRT, ctx: Context, comptime Storage: type, storage: *Storage, delta_time: f32) !void {
    try self.pipeline.draw(ctx, Storage, storage, delta_time);
}

/// push the materials to GPU
pub fn pushMaterials(self: *VoxelRT, materials: []const gpu_types.Material) !void {
    try self.pipeline.transfer(0, .material, materials);
}

pub fn deinit(self: VoxelRT, ctx: Context) void {
    self.pipeline.deinit(ctx);
}
