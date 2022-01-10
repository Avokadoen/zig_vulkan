const std = @import("std");
const Allocator = std.mem.Allocator;

const za = @import("zalgebra");
const Vec2 = @Vector(2, f32);

const render = @import("../render/render.zig");
const Context = render.Context;

const Camera = @import("Camera.zig");
const Octree = @import("Octree.zig");
const gpu_types = @import("gpu_types.zig");

const VoxelRT = @This();

camera: Camera,
octree: Octree,
comp_pipeline: render.ComputeDrawPipeline,

/// init VoxelRT, api takes ownership of the octree
pub fn init(allocator: Allocator, ctx: Context, octree: Octree, target_texture: *render.Texture) !VoxelRT {
    // place holder test compute pipeline
    var comp_pipeline = blk: {
        const Compute = render.ComputeDrawPipeline;
        var buffer_configs = [_]Compute.BufferConfig{
            .{ .size = @sizeOf(gpu_types.Node) * octree.indirect_cells.len, .constant = false },
            .{ .size = @sizeOf(gpu_types.Material), .constant = false },
            .{ .size = @sizeOf(gpu_types.Albedo), .constant = false },
            .{ .size = @sizeOf(gpu_types.Metal), .constant = false },
            .{ .size = @sizeOf(gpu_types.Dielectric), .constant = false },
            .{ .size = @sizeOf(gpu_types.Floats), .constant = false },
            .{ .size = @sizeOf(gpu_types.Ints), .constant = false },
        };

        break :blk try Compute.init(allocator, ctx, "../../raytracer.comp.spv", target_texture, Camera.getGpuSize(), buffer_configs[0..]);
    };
    errdefer comp_pipeline.deinit(ctx);

    const camera = blk: {
        var builder = Camera.Builder.init(75, target_texture.image_extent.width, target_texture.image_extent.height);
        const c = try builder.setOrigin(za.Vec3.new(0, -0.5, -0.3)).setViewportHeight(2).build();
        break :blk c;
    };

    {
        const camera_data = [_]Camera.Device{camera.d_camera};
        try comp_pipeline.uniform_buffer.transfer(ctx, Camera.Device, camera_data[0..]);
    }

    try comp_pipeline.storage_buffers[0].transfer(ctx, gpu_types.Node, octree.indirect_cells);
    {
        const materials = [_]gpu_types.Material{.{
            .@"type" = .lambertian,
            .attribute_index = 0,
            .albedo_index = 0,
        }};
        try comp_pipeline.storage_buffers[1].transfer(ctx, gpu_types.Material, materials[0..]);
    }
    {
        const albedos = [_]gpu_types.Albedo{.{
            .value = za.Vec3.new(1, 0, 0),
        }};
        try comp_pipeline.storage_buffers[2].transfer(ctx, gpu_types.Albedo, albedos[0..]);
    }
    {
        const metals = [_]gpu_types.Metal{.{
            .fuzz = 0.45,
        }};
        try comp_pipeline.storage_buffers[3].transfer(ctx, gpu_types.Metal, metals[0..]);
    }
    {
        const dielectrics = [_]gpu_types.Dielectric{.{
            .ir = 0.45,
        }};
        try comp_pipeline.storage_buffers[4].transfer(ctx, gpu_types.Dielectric, dielectrics[0..]);
    }
    {
        const floats = [_]gpu_types.Floats{octree.floats};
        try comp_pipeline.storage_buffers[5].transfer(ctx, gpu_types.Floats, floats[0..]);
    }
    {
        const ints = [_]gpu_types.Ints{octree.ints};
        try comp_pipeline.storage_buffers[6].transfer(ctx, gpu_types.Ints, ints[0..]);
    }

    // zig fmt: off
    return VoxelRT{ 
        .camera = camera, 
        .octree = octree, 
        .comp_pipeline = comp_pipeline 
    };
    // zig fmt: on
}

pub fn debug(self: *VoxelRT, ctx: Context) !void {
    const camera_data = [_]Camera.Device{self.camera.d_camera};
    try self.comp_pipeline.uniform_buffer.transfer(ctx, Camera.Device, camera_data[0..]);
}

// compute the next frame and draw it to target texture, note that it will not draw to any window
pub inline fn compute(self: VoxelRT, ctx: Context) !void {
    try self.comp_pipeline.compute(ctx);
}

pub fn deinit(self: VoxelRT, ctx: Context) void {
    self.comp_pipeline.deinit(ctx);
}
