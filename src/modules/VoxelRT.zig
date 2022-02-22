const std = @import("std");
const Allocator = std.mem.Allocator;

const tracy = @import("../tracy.zig");

const za = @import("zalgebra");
const Vec2 = @Vector(2, f32);

const render = @import("../modules/render.zig");
const Context = render.Context;

pub const Camera = @import("voxel_rt/Camera.zig");
pub const BrickGrid = @import("voxel_rt/brick/Grid.zig");
pub const GridState = @import("voxel_rt/brick/State.zig");
pub const gpu_types = @import("voxel_rt/gpu_types.zig");
pub const terrain = @import("voxel_rt/terrain/terrain.zig");
pub const vox = @import("voxel_rt/vox/loader.zig");

pub const Config = struct {
    material_buffer: u64 = 256,
    albedo_buffer: u64 = 256,
    metal_buffer: u64 = 256,
    dielectric_buffer: u64 = 256,
};

const VoxelRT = @This();

camera: Camera,
brick_grid: *BrickGrid,
comp_pipeline: render.ComputeDrawPipeline,

/// init VoxelRT, api takes ownership of the brick_grid
pub fn init(allocator: Allocator, ctx: Context, brick_grid: *BrickGrid, target_texture: *render.Texture, config: Config) !VoxelRT {
    var comp_pipeline = blk: {
        const Compute = render.ComputeDrawPipeline;
        const uniform_sizes = [_]u64{
            @sizeOf(Camera.Device),
            @sizeOf(GridState.Device),
        };
        const storage_sizes = [_]u64{
            @sizeOf(gpu_types.Material) * config.material_buffer,
            @sizeOf(gpu_types.Albedo) * config.albedo_buffer,
            @sizeOf(gpu_types.Metal) * config.metal_buffer,
            @sizeOf(gpu_types.Dielectric) * config.dielectric_buffer,
            @sizeOf(u8) * brick_grid.state.higher_order_grid.len,
            @sizeOf(GridState.GridEntry) * brick_grid.state.grid.len,
            @sizeOf(GridState.Brick) * brick_grid.state.bricks.len,
            @sizeOf(u8) * brick_grid.state.material_indices.len,
        };
        const state_configs = Compute.StateConfigs{ .uniform_sizes = uniform_sizes[0..], .storage_sizes = storage_sizes[0..] };

        break :blk try Compute.init(allocator, ctx, "../../brick_raytracer.comp.spv", target_texture, state_configs);
    };
    errdefer comp_pipeline.deinit(ctx);

    const camera = blk: {
        var c_config = Camera.Config{
            .origin = za.Vec3.new(0.0, 0.0, 0.0).data,
            .normal_speed = 2,
            .viewport_height = 2,
            .samples_per_pixel = 1,
            .max_bounce = 1,
        };
        break :blk Camera.init(75, target_texture.image_extent.width, target_texture.image_extent.height, c_config);
    };

    {
        const camera_data = [_]Camera.Device{camera.d_camera};
        try comp_pipeline.uniform_buffers[0].transferToDevice(ctx, Camera.Device, 0, camera_data[0..]);
    }
    {
        const grid_data = [_]GridState.Device{brick_grid.state.device_state};
        try comp_pipeline.uniform_buffers[1].transferToDevice(ctx, GridState.Device, 0, grid_data[0..]);
    }
    {
        const metals = [_]gpu_types.Metal{.{
            .fuzz = 0.45,
        }};
        try comp_pipeline.storage_buffers[2].transferToDevice(ctx, gpu_types.Metal, 0, metals[0..]);
    }
    {
        const dielectrics = [_]gpu_types.Dielectric{
            .{
                .internal_reflection = 1.333, // water
            },
            .{
                .internal_reflection = 1.52, // glass
            },
        };
        try comp_pipeline.storage_buffers[3].transferToDevice(ctx, gpu_types.Dielectric, 0, dielectrics[0..]);
    }

    // zig fmt: off
    return VoxelRT{ 
        .camera = camera, 
        .brick_grid = brick_grid, 
        .comp_pipeline = comp_pipeline 
    };
    // zig fmt: on
}

/// push the materials to GPU
pub inline fn pushMaterials(self: VoxelRT, ctx: Context, materials: []const gpu_types.Material) !void {
    try self.comp_pipeline.storage_buffers[0].transferToDevice(ctx, gpu_types.Material, 0, materials);
}

/// push the albedo to GPU
pub inline fn pushAlbedo(self: VoxelRT, ctx: Context, albedos: []const gpu_types.Albedo) !void {
    try self.comp_pipeline.storage_buffers[1].transferToDevice(ctx, gpu_types.Albedo, 0, albedos);
}

/// a temporary way of pushing camera changes 
pub fn debugMoveCamera(self: *VoxelRT, ctx: Context) !void {
    const camera_data = [_]Camera.Device{self.camera.d_camera};
    try self.comp_pipeline.uniform_buffers[0].transferToDevice(ctx, Camera.Device, 0, camera_data[0..]);
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
            try self.comp_pipeline.storage_buffers[4].transferToDevice(ctx, u8, delta.from, self.brick_grid.state.higher_order_grid[delta.from..delta.to]);
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
                try self.comp_pipeline.storage_buffers[5].transferToDevice(ctx, GridState.GridEntry, delta.from, self.brick_grid.state.grid[delta.from..delta.to]);
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
                try self.comp_pipeline.storage_buffers[6].transferToDevice(ctx, GridState.Brick, delta.from, self.brick_grid.state.bricks[delta.from..delta.to]);
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
                try self.comp_pipeline.storage_buffers[7].transferToDevice(ctx, u8, delta.from, self.brick_grid.state.material_indices[delta.from..delta.to]);
                delta.resetDelta();
            }
        }
    }
}

// compute the next frame and draw it to target texture, note that it will not draw to any window
pub inline fn compute(self: VoxelRT, ctx: Context) !void {
    try self.comp_pipeline.compute(ctx);
}

pub fn deinit(self: VoxelRT, ctx: Context) void {
    self.comp_pipeline.deinit(ctx);
}
