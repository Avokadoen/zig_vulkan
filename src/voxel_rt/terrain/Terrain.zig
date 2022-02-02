const std = @import("std");
const za = @import("zalgebra");

const BrickGrid = @import("../BrickGrid.zig");
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

const Terrain = @This();

ocean_level: usize,
scale: f32,
grid: *BrickGrid,
perlin: Perlin,

// TODO: replace grid with VoxelRt
pub fn init(seed: u64, scale: f32, ocean_level: usize, grid: *BrickGrid) Terrain {
    const perlin = Perlin.init(seed);
    const voxel_dim = [3]f32{
        @intToFloat(f32, grid.device_state.dim_x * 8),
        @intToFloat(f32, grid.device_state.dim_y * 8),
        @intToFloat(f32, grid.device_state.dim_z * 8),
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
            if (ocean_level > height) {
                i_y = height;
                while (i_y < ocean_level) : (i_y += 1) {
                    grid.*.insert(i_x, i_y, i_z, 0); // insert water
                }
                i_y = ocean_level;
            }
            i_y = 0;
            while (i_y < height) : (i_y += 1) {
                const material_value = za.lerp(f32, 1, 3.4, @intToFloat(f32, i_y) * inv_terrain_max_height) + perlin.rng.float(f32) * 0.5;
                const material_index = @intToEnum(Material, @floatToInt(u8, @floor(material_value))).getMaterialIndex(perlin.rng);
                grid.*.insert(i_x, i_y, i_z, material_index);
            }
        }
    }

    return Terrain{
        .ocean_level = ocean_level,
        .scale = scale,
        .grid = grid,
        .perlin = perlin,
    };
}

pub const MaterialData = struct {
    color: []const gpu_types.Albedo,
    materials: []const gpu_types.Material,
};
pub inline fn getMaterialData() MaterialData {
    return MaterialData{
        .color = &[_]gpu_types.Albedo{
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
        },
        .materials = &[_]gpu_types.Material{
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
        },
    };
}
