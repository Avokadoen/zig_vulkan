const std = @import("std");
const Allocator = std.mem.Allocator;

const za = @import("zalgebra");
const Vec2 = @Vector(2, f32);

const render = @import("../render/render.zig");
const Context = render.Context;

const Camera = @import("Camera.zig");
const BrickGrid = @import("BrickGrid.zig");
const gpu_types = @import("gpu_types.zig");

pub const vox = @import("vox/loader.zig");

const default_material_buffer = 10;
const default_albedo_buffer = 10;
const default_metal_buffer = 10;
const default_dielectric_buffer = 10;

pub const Config = struct {
    material_buffer: ?u64 = null,
    albedo_buffer: ?u64 = null,
    metal_buffer: ?u64 = null,
    dielectric_buffer: ?u64 = null,
};

const VoxelRT = @This();

camera: Camera,
brick_grid: BrickGrid,
comp_pipeline: render.ComputeDrawPipeline,

/// init VoxelRT, api takes ownership of the octree
pub fn init(allocator: Allocator, ctx: Context, brick_grid: BrickGrid, target_texture: *render.Texture, config: Config) !VoxelRT {
    // place holder test compute pipeline
    var comp_pipeline = blk: {
        const Compute = render.ComputeDrawPipeline;
        const uniform_sizes = [_]u64{
            @sizeOf(Camera.Device),
            @sizeOf(BrickGrid.Device),
        };
        const storage_sizes = [_]u64{
            @sizeOf(gpu_types.Material) * (config.material_buffer orelse default_material_buffer),
            @sizeOf(gpu_types.Albedo) * (config.albedo_buffer orelse default_albedo_buffer),
            @sizeOf(gpu_types.Metal) * (config.metal_buffer orelse default_metal_buffer),
            @sizeOf(gpu_types.Dielectric) * (config.dielectric_buffer orelse default_dielectric_buffer),
            @sizeOf(BrickGrid.GridEntry) * brick_grid.grid.len,
            @sizeOf(BrickGrid.Brick) * brick_grid.bricks.len,
        };
        const state_configs = Compute.StateConfigs{ .uniform_sizes = uniform_sizes[0..], .storage_sizes = storage_sizes[0..] };

        break :blk try Compute.init(allocator, ctx, "../../brick_raytracer.comp.spv", target_texture, state_configs);
    };
    errdefer comp_pipeline.deinit(ctx);

    const camera = blk: {
        var c_config = Camera.Config{ .origin = za.Vec3.new(0.0, 0.0, 0.0), .normal_speed = 2, .viewport_height = 2, .samples_per_pixel = 4, .max_bounce = 1 };
        break :blk Camera.init(75, target_texture.image_extent.width, target_texture.image_extent.height, c_config);
    };

    {
        const camera_data = [_]Camera.Device{camera.d_camera};
        try comp_pipeline.uniform_buffers[0].transfer(ctx, Camera.Device, camera_data[0..]);
    }
    {
        const grid_data = [_]BrickGrid.Device{brick_grid.device_state};
        try comp_pipeline.uniform_buffers[1].transfer(ctx, BrickGrid.Device, grid_data[0..]);
    }

    {
        const materials = [_]gpu_types.Material{ .{
            .@"type" = .lambertian,
            .type_index = 0,
            .albedo_index = 0,
        }, .{
            .@"type" = .metal,
            .type_index = 0,
            .albedo_index = 1,
        }, .{
            .@"type" = .dielectric,
            .type_index = 0,
            .albedo_index = 2,
        } };
        try comp_pipeline.storage_buffers[0].transfer(ctx, gpu_types.Material, materials[0..]);
    }
    {
        const albedos = [_]gpu_types.Albedo{ .{
            .color = za.Vec4.new(0.5, 0.2, 0, 1),
        }, .{
            .color = za.Vec4.new(0.4, 0, 0.4, 1),
        }, .{
            .color = za.Vec4.new(0.0, 0.6, 0.6, 1),
        } };
        try comp_pipeline.storage_buffers[1].transfer(ctx, gpu_types.Albedo, albedos[0..]);
    }
    {
        const metals = [_]gpu_types.Metal{.{
            .fuzz = 0.45,
        }};
        try comp_pipeline.storage_buffers[2].transfer(ctx, gpu_types.Metal, metals[0..]);
    }
    {
        const dielectrics = [_]gpu_types.Dielectric{.{
            .internal_reflection = 1.52, // glass
        }};
        try comp_pipeline.storage_buffers[3].transfer(ctx, gpu_types.Dielectric, dielectrics[0..]);
    }

    try comp_pipeline.storage_buffers[4].transfer(ctx, BrickGrid.GridEntry, brick_grid.grid);
    try comp_pipeline.storage_buffers[5].transfer(ctx, BrickGrid.Brick, brick_grid.bricks);

    // zig fmt: off
    return VoxelRT{ 
        .camera = camera, 
        .brick_grid = brick_grid, 
        .comp_pipeline = comp_pipeline 
    };
    // zig fmt: on
}

pub fn debug(self: *VoxelRT, ctx: Context) !void {
    const camera_data = [_]Camera.Device{self.camera.d_camera};
    try self.comp_pipeline.uniform_buffers[0].transfer(ctx, Camera.Device, camera_data[0..]);
}

// compute the next frame and draw it to target texture, note that it will not draw to any window
pub inline fn compute(self: VoxelRT, ctx: Context) !void {
    try self.comp_pipeline.compute(ctx);
}

pub fn deinit(self: VoxelRT, ctx: Context) void {
    self.comp_pipeline.deinit(ctx);
}
