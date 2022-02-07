const std = @import("std");
const Allocator = std.mem.Allocator;

const za = @import("zalgebra");
const stbi = @import("stbi");

const render = @import("../../render.zig");
const Context = render.Context;

const BrickGrid = @import("../brick/Grid.zig");
const gpu_types = @import("../gpu_types.zig");
const Perlin = @import("perlin.zig").PerlinNoiseGenerator(256);

const Material = enum(u8) {
    water = 0,
    grass,
    dirt,
    rock,

    pub fn getMaterialIndex(self: Material, rnd: std.rand.Random) u8 {
        switch (self) {
            .water => return 0,
            .grass => {
                const roll = rnd.float(f32);
                return 1 + @floatToInt(u8, @round(roll));
            },
            .dirt => {
                const roll = rnd.float(f32);
                return 3 + @floatToInt(u8, @round(roll));
            },
            .rock => {
                const roll = rnd.float(f32);
                return 5 + @floatToInt(u8, @round(roll));
            },
        }
    }
};

/// populate a voxel grid with perlin noise terrain on CPU
pub fn generateCpu(seed: u64, scale: f32, ocean_level: usize, grid: *BrickGrid) void { // TODO: return Terrain
    const perlin = Perlin.init(seed);

    const voxel_dim = [3]f32{
        @intToFloat(f32, grid.state.device_state.dim_x * 8),
        @intToFloat(f32, grid.state.device_state.dim_y * 8),
        @intToFloat(f32, grid.state.device_state.dim_z * 8),
    };
    const point_mod = [3]f32{
        (1 / voxel_dim[0]) * scale,
        (1 / voxel_dim[1]) * scale,
        (1 / voxel_dim[2]) * scale,
    };
    const terrain_max_height: f32 = voxel_dim[1] * 0.5;
    const inv_terrain_max_height = 1.0 / terrain_max_height;
    var point: [3]f32 = undefined;
    var x: f32 = 0;
    while (x < voxel_dim[0]) : (x += 1) {
        const i_x = @floatToInt(usize, x);

        var z: f32 = 0;
        while (z < voxel_dim[2]) : (z += 1) {
            const i_z = @floatToInt(usize, z);

            point[0] = x * point_mod[0];
            point[1] = 0;
            point[2] = z * point_mod[2];

            const height = @floatToInt(usize, std.math.min(perlin.smoothNoise(f32, point), 1) * terrain_max_height);

            var i_y: usize = 0;
            while (i_y < height) : (i_y += 1) {
                const material_value = za.lerp(f32, 1, 3.4, @intToFloat(f32, i_y) * inv_terrain_max_height) + perlin.rng.float(f32) * 0.5;
                const material_index = @intToEnum(Material, @floatToInt(u8, @floor(material_value))).getMaterialIndex(perlin.rng);
                grid.*.insert(i_x, i_y, i_z, material_index);
            }
            if (ocean_level > height) {
                while (i_y < ocean_level) : (i_y += 1) {
                    grid.*.insert(i_x, i_y, i_z, 0); // insert water
                }
            }
        }
    }

    std.debug.print("completed terrain tuff\n", .{});
}

// generate terrain, utilize gpu to generate the inital height map
pub fn generateGpu(ctx: Context, allocator: Allocator, seed: u32, scale: f32, ocean_level: usize, grid: *BrickGrid) !void {
    _ = seed;
    _ = scale;
    _ = ocean_level;
    _ = grid;

    const rng = std.rand.DefaultPrng.init(seed).random();

    const TerrainUniform = extern struct {
        // offset and scale of the texture
        offset_scale: [4]f32,
        seed: f32,
    };

    const voxel_dim = [3]f32{
        @intToFloat(f32, grid.state.device_state.dim_x * 8),
        @intToFloat(f32, grid.state.device_state.dim_y * 8),
        @intToFloat(f32, grid.state.device_state.dim_z * 8),
    };
    // const point_mod = [3]f32{
    //     (1 / voxel_dim[0]) * scale,
    //     (1 / voxel_dim[1]) * scale,
    //     (1 / voxel_dim[2]) * scale,
    // };

    // TODO: drop texture/image,
    //       use a insert job buffer where the compute shader directly supply
    //       insert jobs to the CPU!

    var target_image = stbi.Image{
        .width = @floatToInt(i32, voxel_dim[0]),
        .height = @floatToInt(i32, voxel_dim[2]),
        .channels = 4,
        .data = try allocator.alloc(stbi.Pixel, @floatToInt(usize, voxel_dim[0] * voxel_dim[2])),
    };
    defer allocator.free(target_image.data);

    var target_texture = try render.Texture.init(ctx, ctx.comp_cmd_pool, .general, stbi.Pixel, .{
        .data = target_image.data,
        .width = @intCast(u32, target_image.width),
        .height = @intCast(u32, target_image.height),
        .usage = .{
            .transfer_src_bit = true,
            .transfer_dst_bit = true,
            .storage_bit = true,
        },
        .queue_family_indices = &[1]u32{ctx.queue_indices.graphics},
        .format = .r8g8b8a8_unorm,
    });

    var comp_pipeline = blk: {
        const Compute = render.ComputeDrawPipeline;
        const uniform_sizes = [_]u64{
            @sizeOf(TerrainUniform),
        };
        const state_configs = Compute.StateConfigs{ .uniform_sizes = uniform_sizes[0..], .storage_sizes = &.{} };

        break :blk try Compute.init(allocator, ctx, "../../height_map_gen.comp.spv", &target_texture, state_configs);
    };
    defer comp_pipeline.deinit(ctx);

    const terrain_gen_data = [1]TerrainUniform{.{
        .offset_scale = [_]f32{ 0, 0, 0, 20 },
        .seed = 0,
    }};
    try comp_pipeline.uniform_buffers[0].transferToDevice(ctx, TerrainUniform, terrain_gen_data[0..]);

    try comp_pipeline.compute(ctx);
    try target_texture.copyToHost(ctx, stbi.Pixel, target_image.data);

    const inv_255: f32 = 1.0 / 255.0;
    const terrain_max_height: f32 = voxel_dim[1] * 0.5;
    const inv_terrain_max_height = 1.0 / terrain_max_height;
    const image_width = @intCast(usize, target_image.width);
    for (target_image.data) |pixel, i| {
        const i_x = i % image_width;
        const i_z = i / image_width;
        const height = @floatToInt(usize, @intToFloat(f32, pixel.r) * inv_255 * terrain_max_height);

        var i_y: usize = 0;
        while (i_y < height) : (i_y += 1) {
            const material_value = za.lerp(f32, 1, 3.4, @intToFloat(f32, i_y) * inv_terrain_max_height) + rng.float(f32) * 0.5;
            const material_index = @intToEnum(Material, @floatToInt(u8, @floor(material_value))).getMaterialIndex(rng);
            grid.*.insert(i_x, i_y, i_z, material_index);
        }
        if (ocean_level > height) {
            while (i_y < ocean_level) : (i_y += 1) {
                grid.*.insert(i_x, i_y, i_z, 0); // insert water
            }
        }
    }
}

/// color information expect by terrain to exist from 0.. in the albedo buffer
pub const color_data = [_]gpu_types.Albedo{
    // water
    .{ .color = za.Vec4.new(0.117, 0.45, 0.85, 1.0) },
    // grass 1
    .{ .color = za.Vec4.new(0.0, 0.6, 0.0, 1.0) },
    // grass 2
    .{ .color = za.Vec4.new(0.0, 0.5019, 0.0, 1.0) },
    // dirt 1
    .{ .color = za.Vec4.new(0.3019, 0.149, 0, 1.0) },
    // dirt 2
    .{ .color = za.Vec4.new(0.4, 0.2, 0, 1.0) },
    // rock 1
    .{ .color = za.Vec4.new(0.275, 0.275, 0.275, 1.0) },
    // rock 2
    .{ .color = za.Vec4.new(0.225, 0.225, 0.225, 1.0) },
    // iron
    .{ .color = za.Vec4.new(0.6, 0.337, 0.282, 1.0) },
};

/// material information expect by terrain to exist from 0.. in the material buffer
pub const material_data = [_]gpu_types.Material{
    // water
    .{ .@"type" = .dielectric, .type_index = 0, .albedo_index = 0 },
    // grass 1
    .{ .@"type" = .lambertian, .type_index = 0, .albedo_index = 1 },
    // grass 2
    .{ .@"type" = .lambertian, .type_index = 0, .albedo_index = 2 },
    // dirt 1
    .{ .@"type" = .lambertian, .type_index = 0, .albedo_index = 3 },
    // dirt 2
    .{ .@"type" = .lambertian, .type_index = 0, .albedo_index = 4 },
    // rock
    .{ .@"type" = .lambertian, .type_index = 0, .albedo_index = 5 },
    // rock
    .{ .@"type" = .lambertian, .type_index = 0, .albedo_index = 6 },
    // iron
    .{ .@"type" = .metal, .type_index = 0, .albedo_index = 4 },
};
