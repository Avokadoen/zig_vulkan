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
pub fn generateCpu(comptime threads_count: usize, allocator: Allocator, seed: u64, scale: f32, ocean_level: usize, grid: *BrickGrid) !void { // TODO: return Terrain
    const zone = tracy.ZoneNS(@src(), "generate terrain chunk", 1);
    defer zone.End();

    const perlin = blk: {
        var p = try allocator.create(Perlin);
        p.* = Perlin.init(seed);
        break :blk p;
    };
    defer allocator.destroy(perlin);

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

    // create our gen function
    const insert_job_gen_fn = struct {
        pub fn insert(thread_id: usize, thread_name: [:0]const u8, perlin_: *const Perlin, voxel_dim_: [3]f32, point_mod_: [3]f32, ocean_level_v: usize, grid_: *BrickGrid) void {
            tracy.SetThreadName(thread_name.ptr);
            const gen_zone = tracy.ZoneN(@src(), "terrain gen");
            defer gen_zone.End();

            const thread_segment_size: f32 = if (threads_count == 0) voxel_dim_[0] else @ceil(voxel_dim_[0] / @intToFloat(f32, threads_count));

            const terrain_max_height: f32 = voxel_dim_[1] * 0.5;
            const inv_terrain_max_height = 1.0 / terrain_max_height;

            var point: [3]f32 = undefined;
            const thread_x_begin = thread_segment_size * @intToFloat(f32, thread_id);
            const thread_x_end = std.math.min(thread_x_begin + thread_segment_size, voxel_dim_[0]);
            var x: f32 = thread_x_begin;
            while (x < thread_x_end) : (x += 1) {
                const i_x = @floatToInt(usize, x);

                var z: f32 = 0;
                while (z < voxel_dim_[2]) : (z += 1) {
                    const i_z = @floatToInt(usize, z);

                    point[0] = x * point_mod_[0];
                    point[1] = 0;
                    point[2] = z * point_mod_[2];

                    const height = @floatToInt(usize, std.math.min(perlin_.smoothNoise(f32, point), 1) * terrain_max_height);

                    var i_y: usize = height / 2;
                    while (i_y < height) : (i_y += 1) {
                        const material_value = za.lerp(f32, 1, 3.4, @intToFloat(f32, i_y) * inv_terrain_max_height) + perlin_.rng.float(f32) * 0.5;
                        const material_index = @intToEnum(Material, @floatToInt(u8, @floor(material_value))).getMaterialIndex(perlin_.rng);
                        grid_.*.insert(i_x, i_y, i_z, material_index);
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
            const thread_name = std.fmt.comptimePrint("terrain thread {d}", .{i});
            threads[i] = try std.Thread.spawn(.{}, insert_job_gen_fn, .{ i, thread_name, perlin, voxel_dim, point_mod, ocean_level, grid });
        }
        i = 0;
        inline while (i < threads_count) : (i += 1) {
            threads[i].join();
        }
    }
}

/// color information expect by terrain to exist from 0.. in the albedo buffer
pub const color_data = [_]gpu_types.Albedo{
    // water
    .{ .color = za.Vec4.new(0.117, 0.45, 0.85, 1.0).data },
    // grass 1
    .{ .color = za.Vec4.new(0.0, 0.6, 0.0, 1.0).data },
    // grass 2
    .{ .color = za.Vec4.new(0.0, 0.5019, 0.0, 1.0).data },
    // dirt 1
    .{ .color = za.Vec4.new(0.3019, 0.149, 0, 1.0).data },
    // dirt 2
    .{ .color = za.Vec4.new(0.4, 0.2, 0, 1.0).data },
    // rock 1
    .{ .color = za.Vec4.new(0.275, 0.275, 0.275, 1.0).data },
    // rock 2
    .{ .color = za.Vec4.new(0.225, 0.225, 0.225, 1.0).data },
    // iron
    .{ .color = za.Vec4.new(0.6, 0.337, 0.282, 1.0).data },
};

/// material information expect by terrain to exist from 0.. in the material buffer
pub const material_data = [_]gpu_types.Material{
    // water
    .{ .type = .dielectric, .type_index = 0, .albedo_index = 0 },
    // grass 1
    .{ .type = .lambertian, .type_index = 0, .albedo_index = 1 },
    // grass 2
    .{ .type = .lambertian, .type_index = 0, .albedo_index = 2 },
    // dirt 1
    .{ .type = .lambertian, .type_index = 0, .albedo_index = 3 },
    // dirt 2
    .{ .type = .lambertian, .type_index = 0, .albedo_index = 4 },
    // rock
    .{ .type = .lambertian, .type_index = 0, .albedo_index = 5 },
    // rock
    .{ .type = .lambertian, .type_index = 0, .albedo_index = 6 },
    // iron
    .{ .type = .metal, .type_index = 0, .albedo_index = 4 },
};
