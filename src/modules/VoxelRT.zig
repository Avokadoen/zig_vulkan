const std = @import("std");
const Allocator = std.mem.Allocator;

const tracy = @import("ztracy");

const za = @import("zalgebra");
const Vec2 = @Vector(2, f32);

const render = @import("../modules/render.zig");
const Context = render.Context;

const Pipeline = @import("voxel_rt/Pipeline.zig");
pub const Camera = @import("voxel_rt/Camera.zig");
pub const Sun = @import("voxel_rt/Sun.zig");
pub const Benchmark = @import("voxel_rt/Benchmark.zig");
pub const HostBrickState = @import("voxel_rt/brick/HostBrickState.zig");

const ray_pipeline_types = @import("voxel_rt/ray_pipeline_types.zig");
pub const Material = ray_pipeline_types.Material;

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

pipeline: Pipeline,

// TODO: host_brick_state should only be added as a imgui argument
/// init VoxelRT
pub fn init(allocator: Allocator, ctx: Context, host_brick_state: *HostBrickState, config: Config) !VoxelRT {
    const camera = try allocator.create(Camera);
    errdefer allocator.destroy(camera);
    camera.* = Camera.init(
        75,
        config.internal_resolution_width,
        config.internal_resolution_height,
        config.camera,
    );

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
        camera,
        sun,
        host_brick_state,
        config.pipeline,
    );
    errdefer pipeline.deinit(ctx);

    return VoxelRT{
        .camera = camera,
        .sun = sun,
        .pipeline = pipeline,
    };
}

pub fn draw(self: *VoxelRT, ctx: Context, host_brick_state: *HostBrickState, delta_time: f32) !void {
    try self.pipeline.draw(ctx, host_brick_state, delta_time);
}

pub fn updateSun(self: *VoxelRT, delta_time: f32) void {
    self.sun.update(delta_time);
}

pub fn deinit(self: VoxelRT, allocator: Allocator, ctx: Context) void {
    allocator.destroy(self.camera);
    allocator.destroy(self.sun);
    self.pipeline.deinit(ctx);
}
