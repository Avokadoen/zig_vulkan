const std = @import("std");
const Allocator = std.mem.Allocator;

const ecez = @import("ecez");

const za = @import("zalgebra");
const stbi = @import("stbi");
const ztracy = @import("ztracy");

const render = @import("../../render.zig");
const Context = render.Context;

const brick_state = @import("../brick/state.zig");
const brick_grid = @import("../brick/grid.zig");

pub fn createAndStoreInitialTerrainGenEntites(
    comptime Storage: type,
    storage: *Storage,
    seed: u64,
    scale: f32,
    ocean_level: usize,
) error{OutOfMemory}!void {
    _ = try storage.createEntity(.{components.Perlin.init(seed)});

    _ = try storage.createEntity(.{components.ChunkToGenerate{
        .scale = scale,
        .ocean_level = ocean_level,
    }});
}

const Material = enum(u8) {
    water = 0,
    grass,
    dirt,
    rock,

    pub fn getMaterialIndex(self: Material, rnd: std.Random) u8 {
        switch (self) {
            .water => return 0,
            .grass => {
                const roll = rnd.intRangeAtMost(u8, 0, 1);
                return 1 + roll;
            },
            .dirt => {
                const roll = rnd.intRangeAtMost(u8, 0, 1);
                return 3 + roll;
            },
            .rock => {
                const roll = rnd.intRangeAtMost(u8, 0, 1);
                return 5 + roll;
            },
        }
    }
};

pub const components = struct {
    pub const Perlin = @import("perlin.zig").PerlinNoiseGenerator(256);

    pub const ChunkToGenerate = struct {
        scale: f32,
        ocean_level: usize,
    };
};

pub const queries = struct {
    pub const Perlin = ecez.QueryAny(struct {
        perlin: components.Perlin,
    }, .{}, .{});

    pub const ReadChunkToGenerate = ecez.QueryAny(struct {
        chunk: components.ChunkToGenerate,
    }, .{}, .{});

    pub const ChunkToGenerateEntities = ecez.QueryAny(struct {
        entity: ecez.Entity,
    }, .{components.ChunkToGenerate}, .{});
};

pub fn CreateSystems(comptime Storage: type) type {
    const InsertVoxelStorage = Storage.Subset(.{
        *brick_grid.components.InsertVoxel,
        *brick_grid.components.InsertVoxelTag,
    });

    const ChunkToGenerateStorage = Storage.Subset(.{
        *components.ChunkToGenerate,
    });

    return struct {
        pub fn generateTerrainChunk(
            perlin_query: *queries.Perlin,
            read_chunk_query: *queries.ReadChunkToGenerate,
            grid_device_query: *brick_state.queries.Device,
            insert_storage: *InsertVoxelStorage,
        ) void {
            const zone = ztracy.ZoneN(@src(), @src().fn_name);
            defer zone.End();

            const read_chunk = read_chunk_query.getAny() orelse return;

            const grid_device = grid_device_query.getAny().?;
            const perlin = (perlin_query.getAny().?).perlin;

            const voxel_dim = [3]f32{
                @floatFromInt(grid_device.device.voxel_dim_x),
                @floatFromInt(grid_device.device.voxel_dim_y),
                @floatFromInt(grid_device.device.voxel_dim_z),
            };
            const point_mod = [3]f32{
                (1 / voxel_dim[0]) * read_chunk.chunk.scale,
                (1 / voxel_dim[1]) * read_chunk.chunk.scale,
                (1 / voxel_dim[2]) * read_chunk.chunk.scale,
            };

            const terrain_max_height: f32 = voxel_dim[1] * 0.5;
            const inv_terrain_max_height = 1.0 / terrain_max_height;

            for (0..grid_device.device.voxel_dim_x) |x| {
                const x_f: f32 = @floatFromInt(x);

                for (0..grid_device.device.voxel_dim_z) |z| {
                    const z_f: f32 = @floatFromInt(z);

                    const point = [_]f32{
                        x_f * point_mod[0],
                        0,
                        z_f * point_mod[2],
                    };

                    const height: usize = @intFromFloat(@min(perlin.smoothNoise(f32, point), 1) * terrain_max_height);
                    for (height / 2..height) |y| {
                        const height_lerp = za.lerp(f32, 1, 3.4, @as(f32, @floatFromInt(y)) * inv_terrain_max_height);
                        const material_value = height_lerp + perlin.rng.float(f32) * 0.5;
                        const material: Material = @enumFromInt(@as(u8, @intFromFloat(@floor(material_value))));

                        _ = insert_storage.createEntity(.{
                            brick_grid.components.InsertVoxel{
                                .x = @intCast(x),
                                .y = @intCast(y),
                                .z = @intCast(z),
                                .material_index = material.getMaterialIndex(perlin.rng),
                                .brick_index = undefined, // calculated by later system
                                .grid_index = undefined, // calculated by later system
                            },
                            brick_grid.components.InsertVoxelTag{},
                        }) catch std.debug.panic("terrain gen: failed to create inser voxel", .{});
                    }

                    // insert water
                    if (height < read_chunk.chunk.ocean_level) {
                        for (height..read_chunk.chunk.ocean_level) |y| {
                            _ = insert_storage.createEntity(.{
                                brick_grid.components.InsertVoxel{
                                    .x = @intCast(x),
                                    .y = @intCast(y),
                                    .z = @intCast(z),
                                    .material_index = Material.water.getMaterialIndex(perlin.rng),
                                    .brick_index = undefined, // calculated by later system
                                    .grid_index = undefined, // calculated by later system
                                },
                                brick_grid.components.InsertVoxelTag{},
                            }) catch std.debug.panic("terrain gen: failed to create inser voxel", .{});
                        }
                    }
                }
            }
        }

        // TODO: there is not caching of chunk generation entities
        pub fn removeGenerateChunkJob(
            chunk_to_generate_query: *queries.ChunkToGenerateEntities,
            chunk_to_generate_storage: *ChunkToGenerateStorage,
        ) void {
            while (chunk_to_generate_query.next()) |chunk| {
                chunk_to_generate_storage.unsetComponents(chunk.entity, .{components.ChunkToGenerate});
            }
        }
    };
}

pub const materials = [_]@import("../gpu_types.zig").Material{
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
