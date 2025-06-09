const std = @import("std");
const Allocator = std.mem.Allocator;

const za = @import("zalgebra");
const stbi = @import("stbi");

const tracy = @import("ztracy");

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

    pub fn getMaterialIndex(self: Material, rnd: std.Random) u8 {
        switch (self) {
            .water => return 0,
            .grass => {
                const roll = rnd.float(f32);
                return 1 + @as(u8, @intFromFloat(@round(roll)));
            },
            .dirt => {
                const roll = rnd.float(f32);
                return 3 + @as(u8, @intFromFloat(@round(roll)));
            },
            .rock => {
                const roll = rnd.float(f32);
                return 5 + @as(u8, @intFromFloat(@round(roll)));
            },
        }
    }
};

/// populate a voxel grid with perlin noise terrain on CPU
pub fn generateCpu(comptime threads_count: usize, allocator: Allocator, seed: u64, scale: f32, ocean_level: usize, grid: *BrickGrid) !void { // TODO: return Terrain
    const zone = tracy.ZoneNS(@src(), "generate terrain chunk", 1);
    defer zone.End();

    const perlin = blk: {
        const p = try allocator.create(Perlin);
        p.* = Perlin.init(seed);
        break :blk p;
    };
    defer allocator.destroy(perlin);

    const voxel_dim = [3]f32{
        @floatFromInt(grid.state.device_state.voxel_dim_x),
        @floatFromInt(grid.state.device_state.voxel_dim_y),
        @floatFromInt(grid.state.device_state.voxel_dim_z),
    };
    const point_mod = [3]f32{
        (1 / voxel_dim[0]) * scale,
        (1 / voxel_dim[1]) * scale,
        (1 / voxel_dim[2]) * scale,
    };

    // create our gen function
    const insert_job_gen_fn = struct {
        pub fn insert(thread_id: usize, thread_name: [:0]const u8, perlin_: *const Perlin, voxel_dim_: [3]f32, point_mod_: [3]f32, ocean_level_v: usize, grid_: *BrickGrid) void {
            tracy.SetThreadName(thread_name.ptr);
            const gen_zone = tracy.ZoneN(@src(), "terrain gen");
            defer gen_zone.End();

            const thread_segment_size: f32 = blk: {
                if (threads_count == 0) {
                    break :blk voxel_dim_[0];
                } else {
                    break :blk @ceil(voxel_dim_[0] / @as(f32, @floatFromInt(threads_count)));
                }
            };

            const terrain_max_height: f32 = voxel_dim_[1] * 0.5;
            const inv_terrain_max_height = 1.0 / terrain_max_height;

            var point: [3]f32 = undefined;
            const thread_x_begin = thread_segment_size * @as(f32, @floatFromInt(thread_id));
            const thread_x_end = @min(thread_x_begin + thread_segment_size, voxel_dim_[0]);
            var x: f32 = thread_x_begin;
            while (x < thread_x_end) : (x += 1) {
                const i_x: usize = @intFromFloat(x);
                var z: f32 = 0;
                while (z < voxel_dim_[2]) : (z += 1) {
                    const i_z: usize = @intFromFloat(z);

                    point[0] = x * point_mod_[0];
                    point[1] = 0;
                    point[2] = z * point_mod_[2];

                    const height: usize = @intFromFloat(@min(perlin_.smoothNoise(f32, point), 1) * terrain_max_height);
                    var i_y: usize = height / 2;
                    while (i_y < height) : (i_y += 1) {
                        const height_lerp = za.lerp(f32, 1, 3.4, @as(f32, @floatFromInt(i_y)) * inv_terrain_max_height);
                        const material_value = height_lerp + perlin_.rng.float(f32) * 0.5;
                        const material: Material = @enumFromInt(@as(u8, @intFromFloat(@floor(material_value))));
                        grid_.*.insert(i_x, i_y, i_z, material.getMaterialIndex(perlin_.rng));
                    }
                    while (i_y < ocean_level_v) : (i_y += 1) {
                        grid_.*.insert(i_x, i_y, i_z, 0); // insert water
                    }
                }
            }
        }
    }.insert;

    if (threads_count == 0) {
        // run on main thread
        @call(.{ .modifier = .always_inline }, insert_job_gen_fn, .{ 0, perlin, voxel_dim, point_mod, ocean_level, grid });
    } else {
        var threads: [threads_count]std.Thread = undefined;
        comptime var i = 0;
        inline while (i < threads_count) : (i += 1) {
            const thread_name = comptime std.fmt.comptimePrint("terrain thread {d}", .{i});
            threads[i] = try std.Thread.spawn(.{}, insert_job_gen_fn, .{ i, thread_name, perlin, voxel_dim, point_mod, ocean_level, grid });
        }
        i = 0;
        inline while (i < threads_count) : (i += 1) {
            threads[i].join();
        }
    }
}

pub const materials = [_]gpu_types.Material{
    // Water
    .{
        .type = .dielectric,
        // Water is 1.3333... glass is 1.52
        .albedo_r = 0.117,
        .albedo_g = 0.45,
        .albedo_b = 0.85,
        .type_data = 1.333,
    },
    // Grass 1
    .{
        .type = .lambertian,
        .albedo_r = 0.0,
        .albedo_g = 0.6,
        .albedo_b = 0.0,
        .type_data = 0.0,
    },
    // Grass 2
    .{
        .type = .lambertian,
        .albedo_r = 0.0,
        .albedo_g = 0.5019,
        .albedo_b = 0.0,
        .type_data = 0.0,
    },
    // Dirt 1
    .{
        .type = .lambertian,
        .albedo_r = 0.301,
        .albedo_g = 0.149,
        .albedo_b = 0.0,
        .type_data = 0.0,
    },
    // Dirt 2
    .{
        .type = .lambertian,
        .albedo_r = 0.4,
        .albedo_g = 0.2,
        .albedo_b = 0.0,
        .type_data = 0.0,
    },
    // Rock 1
    .{
        .type = .lambertian,
        .albedo_r = 0.275,
        .albedo_g = 0.275,
        .albedo_b = 0.275,
        .type_data = 0.0,
    },
    // Rock 2
    .{
        .type = .lambertian,
        .albedo_r = 0.225,
        .albedo_g = 0.225,
        .albedo_b = 0.225,
        .type_data = 0.0,
    },
    // Iron
    .{
        .type = .metal,
        .albedo_r = 0.6,
        .albedo_g = 0.337,
        .albedo_b = 0.282,
        .type_data = 0.45,
    },
};
