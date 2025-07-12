// This file contains an implementaion of "Real-time Ray tracing and Editing of Large Voxel Scenes"
// source: https://dspace.library.uu.nl/handle/1874/315917

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ecez = @import("ecez");

const ztracy = @import("ztracy");

const state = @import("state.zig");
const AtomicCount = state.AtomicCount;
const MaterialAllocator = @import("MaterialAllocator.zig");

const EventArgument = @import("../event_arg.zig").EventArgument;

pub const components = struct {
    pub const InsertVoxel = struct {
        x: u16,
        y: u16,
        z: u16,
        material_index: u8,
        brick_index: u32,
        grid_index: usize,
    };

    pub const InsertVoxelTag = struct {};
};

pub const queries = struct {
    pub const WriteInsertVoxel = ecez.Query(struct {
        insert: *components.InsertVoxel,
    }, .{}, .{});

    pub const ReadInsertVoxel = ecez.Query(struct {
        insert: components.InsertVoxel,
    }, .{}, .{});

    pub const RemoveInsertVoxel = ecez.Query(struct {
        entity: ecez.Entity,
    }, .{components.InsertVoxel}, .{});

    pub const ReuseInsertVoxel = ecez.QueryAny(
        struct {
            entity: ecez.Entity,
        },
        .{components.InsertVoxelTag}, // include
        .{components.InsertVoxel}, // exclude
    );
};

/// Initialize a BrickGrid that can be raytraced
/// @param:
///     - allocator: used to allocate bricks and the grid, also to clean up these in deinit
///     - config:    config options for the brickmap
pub fn createAndStoreStateComponents(comptime Storage: type, storage: *Storage, config: state.components.Device.Config) error{OutOfMemory}!ecez.Entity {
    return storage.createEntity(.{
        state.components.ActiveBricks.empty,
        state.components.Statuses.empty,
        state.components.StatusDelta.empty,
        state.components.Indices.empty,
        state.components.IndicesDelta.empty,
        state.components.Occupancy.empty,
        state.components.OccupancyDelta.empty,
        state.components.StartIndices.empty,
        state.components.StartIndicesDelta.empty,
        state.components.MaterialIndices.empty,
        state.components.MaterialIndicesDelta.empty,
        state.components.MaterialAllocator.init(state.components.MaterialIndices.material_index_count),
        state.components.Device.init(config),
    });
}

pub fn scheduleInsert(
    comptime Storage: type,
    storage: *Storage,
    x: u16,
    y: u16,
    z: u16,
    material_index: u8,
) error{OutOfMemory}!void {
    const insert_component = components.InsertVoxel{
        .x = x,
        .y = y,
        .z = z,
        .material_index = material_index,
        .brick_index = undefined,
        .grid_index = undefined,
    };

    var reuse_query = queries.ReuseInsertVoxel.prepare(storage);
    if (reuse_query.getAny()) |reuse_entity| {
        try storage.setComponents(reuse_entity.entity, .{insert_component});
    } else {
        _ = try storage.createEntity(.{
            insert_component,
            components.InsertVoxelTag{},
        });
    }
}

pub fn CreateSystems(comptime Storage: type) type {
    const sub_storages = struct {
        const RemoveInsertVoxel = Storage.Subset(.{
            *components.InsertVoxel,
        });
    };

    return struct {
        // Start by getting insert index for each insert job
        pub fn insertGetActiveIndex(
            new_voxels_query: *queries.WriteInsertVoxel,
            active_bricks_query: *state.queries.WriteActiveBricks,
            brick_statuses_query: *state.queries.WriteStatus,
            brick_indices_query: *state.queries.WriteIndices,
            device_grid_query: *state.queries.Device,
        ) void {
            const zone = ztracy.ZoneN(@src(), @src().fn_name);
            defer zone.End();

            const active_bricks = active_bricks_query.getAny().?;
            const device_grid = (device_grid_query.getAny().?).device;
            const brick_statuses = brick_statuses_query.getAny().?;
            const brick_indices = brick_indices_query.getAny().?;

            while (new_voxels_query.next()) |*new_voxel| {
                std.debug.assert(new_voxel.insert.x < device_grid.voxel_dim_x);
                std.debug.assert(new_voxel.insert.y < device_grid.voxel_dim_y);
                std.debug.assert(new_voxel.insert.z < device_grid.voxel_dim_z);

                // Flip Y so that higher value correspond to a higer voxel coordinate (0 is bottom, dim y - 1 is highest)
                new_voxel.insert.y = @intCast(device_grid.voxel_dim_y - 1 - new_voxel.insert.y);

                new_voxel.insert.grid_index = gridAt(device_grid, new_voxel.insert.x, new_voxel.insert.y, new_voxel.insert.z);
                const brick_status_index = new_voxel.insert.grid_index / 32;

                const brick_status_offset: u5 = @intCast(new_voxel.insert.grid_index % 32);
                const brick_status = brick_statuses.statuses.statuses[brick_status_index].read(brick_status_offset);

                new_voxel.insert.brick_index = blk: {
                    if (brick_status == .loaded) {
                        break :blk brick_indices.indices.indices[new_voxel.insert.grid_index];
                    }

                    // set the brick as loaded
                    brick_statuses.statuses.statuses[brick_status_index].write(.loaded, brick_status_offset);
                    brick_statuses.delta.delta.registerDelta(brick_status_index);

                    // atomically fetch previous brick count and then add 1 to count
                    const new_brick_index = active_bricks.active.count.fetchAdd(1, .monotonic);

                    // register brick index
                    brick_indices.indices.indices[new_voxel.insert.grid_index] = new_brick_index;
                    brick_indices.delta.delta.registerDelta(new_voxel.insert.grid_index);

                    break :blk new_brick_index;
                };
            }
        }

        pub fn insertBrickStartIndexAndMaterial(
            new_voxels_query: *queries.ReadInsertVoxel,
            brick_start_indices_query: *state.queries.WriteStartIndices,
            material_query: *state.queries.WriteMaterialIndices,
        ) void {
            const zone = ztracy.ZoneN(@src(), @src().fn_name);
            defer zone.End();

            const brick_start_indices = brick_start_indices_query.getAny().?;
            const material = material_query.getAny().?;

            while (new_voxels_query.next()) |new_voxel| {
                var brick_material_index = &brick_start_indices.indices.indices[new_voxel.insert.brick_index];

                // set the brick's material index if unset
                if (brick_material_index.* == state.Brick.unset_index) {
                    const material_entry = material.allocator.nextEntry();
                    brick_material_index.value = @intCast(material_entry);
                    brick_material_index.type = .voxel_start_index;

                    // store brick material start index
                    brick_start_indices.delta.delta.registerDelta(new_voxel.insert.brick_index);
                }

                std.debug.assert(brick_material_index.type == .voxel_start_index);
                std.debug.assert(brick_material_index.value == std.mem.alignForward(u31, brick_material_index.value, 16));

                // set the voxel material
                const nth_bit = voxelAt(new_voxel.insert.x, new_voxel.insert.y, new_voxel.insert.z);
                const new_voxel_material_index = brick_material_index.value + nth_bit;
                material.indices.indices[new_voxel_material_index] = new_voxel.insert.material_index;

                material.delta.delta.registerDelta(new_voxel_material_index);
            }
        }

        pub fn insertBrickOccupancy(
            new_voxels_query: *queries.ReadInsertVoxel,
            brick_occupancy_query: *state.queries.WriteOccupancy,
        ) void {
            const zone = ztracy.ZoneN(@src(), @src().fn_name);
            defer zone.End();

            const brick_occupancy = brick_occupancy_query.getAny().?;

            while (new_voxels_query.next()) |new_voxel| {
                const occupancy_from = new_voxel.insert.brick_index * state.brick_bytes;
                const occupancy_to = new_voxel.insert.brick_index * state.brick_bytes + state.brick_bytes;
                const brick_occupancy_bits = brick_occupancy.occupancy.occupancy[occupancy_from..occupancy_to];

                const nth_bit = voxelAt(new_voxel.insert.x, new_voxel.insert.y, new_voxel.insert.z);
                const mask_index = nth_bit / @bitSizeOf(u8);
                const mask_bit: u3 = @intCast(@rem(nth_bit, @bitSizeOf(u8)));
                brick_occupancy_bits[mask_index] |= @as(u8, 1) << mask_bit;

                // store brick changes
                brick_occupancy.delta.delta.registerDelta(occupancy_from + mask_index);
            }
        }

        pub fn removeInsertComponent(
            insert_entity_query: *queries.RemoveInsertVoxel,
            remove_storage: *sub_storages.RemoveInsertVoxel,
        ) void {
            const zone = ztracy.ZoneN(@src(), @src().fn_name);
            defer zone.End();

            while (insert_entity_query.next()) |insert| {
                remove_storage.unsetComponents(insert.entity, .{
                    components.InsertVoxel,
                });
            }
        }

        pub fn updateStatusDeltaGridDelta(
            status_query: *state.queries.upload.Status,
            event_arg: EventArgument,
        ) void {
            const zone = ztracy.ZoneN(@src(), @src().fn_name);
            defer zone.End();

            const statuses = status_query.getAny().?;
            const delta = &statuses.delta.delta;
            if (delta.state == .active) {
                try event_arg.voxel_rt.pipeline.transfer(
                    delta.from,
                    .brick_status,
                    statuses.statuses.statuses[delta.from..delta.to],
                );
                delta.resetDelta();
            }
        }

        pub fn updateIndicesDeltaGridDelta(
            indices_query: *state.queries.upload.Indices,
            event_arg: EventArgument,
        ) void {
            const zone = ztracy.ZoneN(@src(), @src().fn_name);
            defer zone.End();

            const indices = indices_query.getAny().?;
            const delta = &indices.delta.delta;
            if (delta.state == .active) {
                try event_arg.voxel_rt.pipeline.transfer(
                    delta.from,
                    .index_to_brick,
                    indices.indices.indices[delta.from..delta.to],
                );
                delta.resetDelta();
            }
        }

        pub fn updateOccupancyDeltaGridDelta(
            occupancy_query: *state.queries.upload.Occupancy,
            event_arg: EventArgument,
        ) void {
            const zone = ztracy.ZoneN(@src(), @src().fn_name);
            defer zone.End();

            const occupancy = occupancy_query.getAny().?;
            const delta = &occupancy.delta.delta;
            if (delta.state == .active) {
                try event_arg.voxel_rt.pipeline.transfer(
                    delta.from,
                    .occupancy,
                    occupancy.occupancy.occupancy[delta.from..delta.to],
                );
                delta.resetDelta();
            }
        }

        pub fn updateMaterialIndicesDeltaGridDelta(
            material_indices_query: *state.queries.upload.MaterialIndices,
            event_arg: EventArgument,
        ) void {
            const zone = ztracy.ZoneN(@src(), @src().fn_name);
            defer zone.End();

            const material_indices = material_indices_query.getAny().?;
            const delta = &material_indices.delta.delta;
            if (delta.state == .active) {
                try event_arg.voxel_rt.pipeline.transfer(
                    delta.from,
                    .material_index,
                    material_indices.indices.indices[delta.from..delta.to],
                );
                delta.resetDelta();
            }
        }

        pub fn updateStartIndicesDeltaGridDelta(
            start_indices_query: *state.queries.upload.StartIndices,
            event_arg: EventArgument,
        ) void {
            const zone = ztracy.ZoneN(@src(), @src().fn_name);
            defer zone.End();

            const start_indices = start_indices_query.getAny().?;
            const delta = &start_indices.delta.delta;
            if (delta.state == .active) {
                try event_arg.voxel_rt.pipeline.transfer(
                    delta.from,
                    .brick_start_index,
                    start_indices.indices.indices[delta.from..delta.to],
                );
                delta.resetDelta();
            }
        }
    };
}

/// get brick index from global index coordinates
fn voxelAt(x: usize, y: usize, z: usize) state.BrickMapLog2 {
    const brick_x: usize = @rem(x, state.brick_dimension);
    const brick_y: usize = @rem(y, state.brick_dimension);
    const brick_z: usize = @rem(z, state.brick_dimension);
    return @intCast(brick_x + state.brick_dimension * (brick_z + state.brick_dimension * brick_y));
}

/// get grid index from global index coordinates
fn gridAt(device_state: state.components.Device, x: usize, y: usize, z: usize) usize {
    const grid_x: u32 = @intCast(x / state.brick_dimension);
    const grid_y: u32 = @intCast(y / state.brick_dimension);
    const grid_z: u32 = @intCast(z / state.brick_dimension);
    return @intCast(grid_x + device_state.dim_x * (grid_z + device_state.dim_z * grid_y));
}

/// count the set bits up to range_to (exclusive)
fn countBits(bits: [state.brick_bytes]u8, range_to: u32) u32 {
    var bit: state.BrickMap = @bitCast(bits);
    var count: state.BrickMap = 0;
    var i: u32 = 0;
    while (i < range_to and bit != 0) : (i += 1) {
        count += bit & 1;
        bit = bit >> 1;
    }
    return @intCast(count);
}
