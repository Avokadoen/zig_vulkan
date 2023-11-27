const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const tracy = @import("ztracy");

const render = @import("../render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;
const StagingRamp = render.StagingRamp;

const ray_pipeline_types = @import("./ray_pipeline_types.zig");
const ImageInfo = ray_pipeline_types.ImageInfo;
const RayHitLimits = ray_pipeline_types.RayHitLimits;
const BrickGridState = ray_pipeline_types.BrickGridState;
const BrickIndex = ray_pipeline_types.BrickIndex;
const Brick = ray_pipeline_types.Brick;
const BrickLimits = ray_pipeline_types.BrickLimits;
const Ray = ray_pipeline_types.Ray;
const RayHit = ray_pipeline_types.RayHit;
const RayShading = ray_pipeline_types.RayShading;
const RayHash = ray_pipeline_types.RayHash;

pub const Config = struct {
    brick_load_request_count: c_uint = 1024,
    brick_unload_request_count: c_uint = 1024,
};

// TODO: We should definitly rework all this resource stuff ...
/// Resources only accessible on device
///
/// Postfix indicate if enum represent set and binding, or just a binding
/// _s - The resource is binding specified resource and all subsequent bindings
/// _b - The resource is just a binding and cant be requested as a set
pub const DeviceOnlyResources = enum(u32) {
    ray_pipeline_limits_s,

    // ray buffer info 0 (ping pong)
    ray_0_s,
    ray_hit_0_s,
    ray_shading_0_s,
    ray_hash_0_s,

    // ray buffer info 1 (ping pong)
    ray_1_s,
    ray_hit_1_s,
    ray_shading_1_s,
    ray_hash_1_s, // TODO: hash might not need to be dupliacted

    // brick buffer info
    bricks_set_s,
    brick_indices_b,
    bricks_b,

    // draw image
    draw_image_s,

    pub const ray_count = @intFromEnum(DeviceOnlyResources.ray_hash_1_s) + 1;
    pub const brick_count = (@intFromEnum(DeviceOnlyResources.bricks_b) + 1) - ray_count;
    pub const image_count = (@intFromEnum(DeviceOnlyResources.draw_image_s) + 1) - (brick_count + ray_count);
    pub const all_count = @typeInfo(DeviceOnlyResources).Enum.fields.len;
};

pub const HostAndDeviceResources = enum(u32) {
    // brick request limits
    brick_req_limits_s,

    // request indices
    brick_load_request_s,
    brick_unload_request_b,

    pub const brick_limits_count = (@intFromEnum(HostAndDeviceResources.brick_req_limits_s) + 1);
    pub const brick_req_count = @intFromEnum(HostAndDeviceResources.brick_unload_request_b) + 1 - brick_limits_count;
    pub const all_count = @typeInfo(HostAndDeviceResources).Enum.fields.len;
};

// each individual data need some buffer info
pub const buffer_info_count = @typeInfo(DeviceOnlyResources).Enum.fields.len + @typeInfo(HostAndDeviceResources).Enum.fields.len;

// we use one set per ray buffer type and one set for the brick grid data
pub const descriptor_set_count =
    DeviceOnlyResources.ray_count +
    (DeviceOnlyResources.brick_count - 2) +
    DeviceOnlyResources.image_count +
    HostAndDeviceResources.brick_limits_count +
    (HostAndDeviceResources.brick_req_count - 1);

pub const descriptor_buffer_count = buffer_info_count - DeviceOnlyResources.image_count;
pub const descriptor_image_count = DeviceOnlyResources.image_count;

const RayDeviceResources = @This();

allocator: Allocator,

target_descriptor_pool: vk.DescriptorPool,
target_descriptor_layouts: [descriptor_set_count]vk.DescriptorSetLayout,
target_descriptor_sets: [descriptor_set_count]vk.DescriptorSet,

brick_grid_state: *BrickGridState,

target_image_info: ImageInfo,
buffer_infos: [descriptor_buffer_count]vk.DescriptorBufferInfo,
ray_buffer: GpuBufferMemory,
voxel_scene_buffer: GpuBufferMemory,
request_buffer: GpuBufferMemory,

brick_load_request_count: c_uint,
brick_unload_request_count: c_uint,

pub fn init(
    allocator: Allocator,
    ctx: Context,
    target_image_info: ImageInfo,
    init_command_pool: vk.CommandPool,
    staging_buffer: *StagingRamp,
    config: Config,
) !RayDeviceResources {
    const zone = tracy.ZoneN(@src(), @typeName(RayDeviceResources) ++ " " ++ @src().fn_name);
    defer zone.End();

    // TODO: allocate according to need
    var ray_buffer = try GpuBufferMemory.init(
        ctx,
        @as(vk.DeviceSize, @intCast(250 * 1024 * 1024)), // alloc 250mb
        .{ .storage_buffer_bit = true, .transfer_dst_bit = true, .transfer_src_bit = true },
        .{ .device_local_bit = true },
    );
    errdefer ray_buffer.deinit(ctx);

    var voxel_scene_buffer = try GpuBufferMemory.init(
        ctx,
        @as(vk.DeviceSize, @intCast(250 * 1024 * 1024)), // alloc 250mb
        .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
        .{ .device_local_bit = true },
    );
    errdefer voxel_scene_buffer.deinit(ctx);
    try voxel_scene_buffer.fill(ctx, init_command_pool, 0, voxel_scene_buffer.size, 0);

    var request_buffer = try GpuBufferMemory.init(
        ctx,
        @as(vk.DeviceSize, @intCast(64 * 1024 * 1024)), // alloc 64mb
        .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
        .{ .host_visible_bit = true },
    );
    errdefer request_buffer.deinit(ctx);
    try request_buffer.fill(ctx, init_command_pool, 0, request_buffer.size, 0);

    const brick_grid_state: *BrickGridState = blk: {
        const state = try allocator.create(BrickGridState);
        state.* = BrickGridState{
            .dim = [_]f32{ 32, 32, 32 },
            .padding1 = 0,
            .min_point = [_]f32{-1} ** 3,
            .scale = 2,
        };

        break :blk state;
    };
    errdefer allocator.destroy(brick_grid_state);

    // TODO: we dont want to store full grid, we stream grid
    const total_bricks = @as(vk.DeviceSize, @intFromFloat(brick_grid_state.dim[0] * brick_grid_state.dim[1] * brick_grid_state.dim[2]));
    std.debug.assert(total_bricks * @sizeOf(Brick) < voxel_scene_buffer.size);

    const target_descriptor_pool = blk: {
        const pool_sizes = [_]vk.DescriptorPoolSize{ .{
            .type = .storage_buffer,
            .descriptor_count = descriptor_buffer_count,
        }, .{
            .type = .storage_image,
            .descriptor_count = DeviceOnlyResources.image_count,
        } };
        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = descriptor_set_count,
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
        };
        break :blk try ctx.vkd.createDescriptorPool(ctx.logical_device, &pool_info, null);
    };
    errdefer ctx.vkd.destroyDescriptorPool(ctx.logical_device, target_descriptor_pool, null);

    const target_descriptor_layouts = blk: {
        var tmp_layout: [descriptor_set_count]vk.DescriptorSetLayout = undefined;

        // in the event of error destroy only created layouts
        var created_layouts: u32 = 0;
        errdefer {
            for (tmp_layout[0..created_layouts]) |layout| {
                ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, layout, null);
            }
        }

        // for each ray layout we only use one binding
        inline for (tmp_layout[0..DeviceOnlyResources.ray_count]) |*layout| {
            const binding = [_]vk.DescriptorSetLayoutBinding{.{
                .binding = 0,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            }};
            const layout_info = vk.DescriptorSetLayoutCreateInfo{
                .flags = .{},
                .binding_count = binding.len,
                .p_bindings = &binding,
            };
            layout.* = try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &layout_info, null);

            created_layouts += 1;
        }

        // for brick layout we use one set with 3 bindings
        {
            const bindings = [_]vk.DescriptorSetLayoutBinding{ .{
                .binding = 0,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            }, .{
                .binding = 1,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            }, .{
                .binding = 2,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            } };
            const layout_info = vk.DescriptorSetLayoutCreateInfo{
                .flags = .{},
                .binding_count = bindings.len,
                .p_bindings = &bindings,
            };
            const brick_set_index = (Resource{ .device = .bricks_set_s }).toDescriptorIndex();
            tmp_layout[brick_set_index] = try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &layout_info, null);

            created_layouts += 1;
        }

        // for image we use one set one binding, but storage image
        {
            const bindings = [_]vk.DescriptorSetLayoutBinding{
                .{
                    .binding = 0,
                    .descriptor_type = .storage_image,
                    .descriptor_count = 1,
                    .stage_flags = .{
                        .compute_bit = true,
                    },
                    .p_immutable_samplers = null,
                },
            };
            const layout_info = vk.DescriptorSetLayoutCreateInfo{
                .flags = .{},
                .binding_count = bindings.len,
                .p_bindings = &bindings,
            };
            const image_set_index = (Resource{ .device = .draw_image_s }).toDescriptorIndex();
            tmp_layout[image_set_index] = try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &layout_info, null);

            created_layouts += 1;
        }

        // for brick request layout we use one set with 2 bindings
        {
            const bindings = [_]vk.DescriptorSetLayoutBinding{ .{
                .binding = 0,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            }, .{
                .binding = 1,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            } };
            const layout_info = vk.DescriptorSetLayoutCreateInfo{
                .flags = .{},
                .binding_count = bindings.len,
                .p_bindings = &bindings,
            };
            const brick_req_set_index = (Resource{ .host_and_device = .brick_load_request_s }).toDescriptorIndex();
            tmp_layout[brick_req_set_index] = try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &layout_info, null);

            created_layouts += 1;
        }

        // brick req limits layout
        {
            const bindings = [_]vk.DescriptorSetLayoutBinding{.{
                .binding = 0,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            }};
            const layout_info = vk.DescriptorSetLayoutCreateInfo{
                .flags = .{},
                .binding_count = bindings.len,
                .p_bindings = &bindings,
            };
            const brick_req_limits_index = (Resource{ .host_and_device = .brick_req_limits_s }).toDescriptorIndex();
            tmp_layout[brick_req_limits_index] = try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &layout_info, null);

            created_layouts += 1;
        }

        break :blk tmp_layout;
    };
    errdefer {
        for (target_descriptor_layouts) |layout| {
            ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, layout, null);
        }
    }

    var target_descriptor_sets: [descriptor_set_count]vk.DescriptorSet = undefined;
    {
        const descriptor_set_alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = target_descriptor_pool,
            .descriptor_set_count = target_descriptor_layouts.len,
            .p_set_layouts = &target_descriptor_layouts,
        };
        try ctx.vkd.allocateDescriptorSets(
            ctx.logical_device,
            &descriptor_set_alloc_info,
            &target_descriptor_sets,
        );
    }

    // generate buffer info and write descriptor sets
    const buffer_infos: [descriptor_buffer_count]vk.DescriptorBufferInfo = blk: {
        var infos: [descriptor_buffer_count]vk.DescriptorBufferInfo = undefined;

        // TODO: when we convert this from enum to a struct we can bake some of the info into the struct.
        const ray_count: u64 = @intFromFloat(target_image_info.width * target_image_info.height);

        // TODO: offset each entry by item alignment
        const ray_ranges = [DeviceOnlyResources.ray_count]vk.DeviceSize{
            // limits
            @sizeOf(RayHitLimits),
            // rays 0
            ray_count * @sizeOf(Ray),
            // ray hits 0
            ray_count * @sizeOf(RayHit),
            // ray shadings 0
            ray_count * @sizeOf(RayShading),
            // ray hashes 0
            ray_count * @sizeOf(RayHash),
            // rays 1
            ray_count * @sizeOf(Ray),
            // ray hits 1
            ray_count * @sizeOf(RayHit),
            // ray shadings 1
            ray_count * @sizeOf(RayShading),
            // ray hashes 1
            ray_count * @sizeOf(RayHash),
        };
        const brick_grid_ranges = [DeviceOnlyResources.brick_count]vk.DeviceSize{
            // bricks set
            try std.math.divCeil(vk.DeviceSize, total_bricks, 8),
            // bricks indices
            total_bricks * @sizeOf(BrickIndex),
            // bricks
            total_bricks * @sizeOf(Brick),
        };
        const brick_request_ranges = [HostAndDeviceResources.brick_req_count + HostAndDeviceResources.brick_limits_count]vk.DeviceSize{
            // brick limits
            @sizeOf(BrickLimits),
            // load brick requests
            config.brick_load_request_count * @sizeOf(c_uint),
            // unload brick requests
            config.brick_unload_request_count * @sizeOf(c_uint),
        };

        for (infos[0..ray_ranges.len], ray_ranges, 0..) |*info, range, info_index| {
            info.* = vk.DescriptorBufferInfo{
                .buffer = ray_buffer.buffer,
                .offset = if (info_index == 0) 0 else pow2Align(
                    infos[info_index - 1].offset + infos[info_index - 1].range,
                    // TODO: use ray_buffer.memory requirement!
                    ctx.physical_device_limits.min_storage_buffer_offset_alignment,
                ),
                .range = range,
            };
            // TODO: assert we are within the allocated size of 250mb
        }
        const brick_grid_start = ray_ranges.len;
        const brick_grid_end = ray_ranges.len + brick_grid_ranges.len;
        const brick_infos = infos[brick_grid_start..brick_grid_end];
        for (brick_infos, brick_grid_ranges, 0..) |*brick_info, range, info_index| {
            brick_info.* = vk.DescriptorBufferInfo{
                .buffer = voxel_scene_buffer.buffer,
                .offset = if (info_index == 0) 0 else pow2Align(
                    brick_infos[info_index - 1].offset + brick_infos[info_index - 1].range,
                    ctx.physical_device_limits.min_storage_buffer_offset_alignment,
                ),
                .range = range,
            };
            // TODO: assert we are within the allocated size of 250mb
        }

        const brick_req_start = brick_grid_end;
        const brick_req_end = brick_req_start + brick_request_ranges.len;
        const brick_req_infos = infos[brick_req_start..brick_req_end];
        for (brick_req_infos, brick_request_ranges, 0..) |*brick_req_info, range, info_index| {
            brick_req_info.* = vk.DescriptorBufferInfo{
                .buffer = request_buffer.buffer,
                // calculate offset by looking at previous info if there is any
                .offset = if (info_index == 0) 0 else pow2Align(
                    brick_req_infos[info_index - 1].offset + brick_req_infos[info_index - 1].range,
                    ctx.physical_device_limits.min_storage_buffer_offset_alignment,
                ),
                .range = range,
            };
            // TODO: assert we are within the allocated size of 64mb
        }

        const image_info = vk.DescriptorImageInfo{
            .sampler = target_image_info.sampler,
            .image_view = target_image_info.image_view,
            .image_layout = .general,
        };
        const write_descriptor_set = write_blk: {
            var writes: [buffer_info_count]vk.WriteDescriptorSet = undefined;

            // each ray descriptor is one set
            for (
                writes[0..DeviceOnlyResources.ray_count],
                infos[0..DeviceOnlyResources.ray_count],
                target_descriptor_sets[0..DeviceOnlyResources.ray_count],
            ) |*write, *info, descriptor_set| {
                write.* = vk.WriteDescriptorSet{
                    .dst_set = descriptor_set,
                    .dst_binding = 0,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_buffer,
                    .p_image_info = undefined,
                    .p_buffer_info = @ptrCast(info),
                    .p_texel_buffer_view = undefined,
                };
            }

            const brick_desc_set_index = DeviceOnlyResources.ray_count;

            {
                const brick_set_res = Resource{ .device = .bricks_set_s };
                writes[@intFromEnum(DeviceOnlyResources.bricks_set_s)] = vk.WriteDescriptorSet{
                    .dst_set = target_descriptor_sets[brick_set_res.toDescriptorIndex()],
                    .dst_binding = 0,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_buffer,
                    .p_image_info = undefined,
                    .p_buffer_info = @ptrCast(&infos[brick_set_res.toBufferIndex()]),
                    .p_texel_buffer_view = undefined,
                };
                writes[@intFromEnum(DeviceOnlyResources.brick_indices_b)] = vk.WriteDescriptorSet{
                    .dst_set = target_descriptor_sets[brick_set_res.toDescriptorIndex()],
                    .dst_binding = 1,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_buffer,
                    .p_image_info = undefined,
                    .p_buffer_info = @ptrCast(&infos[(Resource{ .device = .brick_indices_b }).toBufferIndex()]),
                    .p_texel_buffer_view = undefined,
                };
                writes[@intFromEnum(DeviceOnlyResources.bricks_b)] = vk.WriteDescriptorSet{
                    .dst_set = target_descriptor_sets[brick_set_res.toDescriptorIndex()],
                    .dst_binding = 2,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_buffer,
                    .p_image_info = undefined,
                    .p_buffer_info = @ptrCast(&infos[(Resource{ .device = .bricks_b }).toBufferIndex()]),
                    .p_texel_buffer_view = undefined,
                };
            }

            {
                writes[@intFromEnum(DeviceOnlyResources.draw_image_s)] = vk.WriteDescriptorSet{
                    .dst_set = target_descriptor_sets[brick_desc_set_index + 1],
                    .dst_binding = 0,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_image,
                    .p_image_info = @ptrCast(&image_info),
                    .p_buffer_info = undefined,
                    .p_texel_buffer_view = undefined,
                };
            }

            // assert image is last enum value
            comptime std.debug.assert(@intFromEnum(DeviceOnlyResources.draw_image_s) == DeviceOnlyResources.all_count - 1);
            // assert brick set is last buffer enum value
            comptime std.debug.assert(@intFromEnum(DeviceOnlyResources.draw_image_s) == @intFromEnum(DeviceOnlyResources.bricks_b) + 1);

            const brick_req_write_offset = DeviceOnlyResources.all_count;
            writes[brick_req_write_offset + @intFromEnum(HostAndDeviceResources.brick_req_limits_s)] = vk.WriteDescriptorSet{
                .dst_set = target_descriptor_sets[brick_desc_set_index + 2],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast(&infos[(Resource{ .host_and_device = .brick_req_limits_s }).toBufferIndex()]),
                .p_texel_buffer_view = undefined,
            };

            writes[brick_req_write_offset + @intFromEnum(HostAndDeviceResources.brick_load_request_s)] = vk.WriteDescriptorSet{
                .dst_set = target_descriptor_sets[brick_desc_set_index + 3],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast(&infos[(Resource{ .host_and_device = .brick_load_request_s }).toBufferIndex()]),
                .p_texel_buffer_view = undefined,
            };
            writes[brick_req_write_offset + @intFromEnum(HostAndDeviceResources.brick_unload_request_b)] = vk.WriteDescriptorSet{
                .dst_set = target_descriptor_sets[brick_desc_set_index + 3],
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast(&infos[(Resource{ .host_and_device = .brick_unload_request_b }).toBufferIndex()]),
                .p_texel_buffer_view = undefined,
            };

            break :write_blk writes;
        };

        ctx.vkd.updateDescriptorSets(
            ctx.logical_device,
            write_descriptor_set.len,
            &write_descriptor_set,
            0,
            undefined,
        );

        break :blk infos;
    };

    // brick transfer
    {
        const test_brick_none = Brick{
            .solid_mask = @as(u512, 0),
        };
        _ = test_brick_none;
        const test_brick_one = Brick{
            .solid_mask = @as(u512, 1),
        };
        const test_brick_row = Brick{
            .solid_mask = @as(u512, 0b01111111),
        };
        const test_brick_all = Brick{
            .solid_mask = ~@as(u512, 0),
        };

        const brick_buffer_index = (Resource{ .device = .bricks_b }).toBufferIndex();
        try staging_buffer.transferToBuffer(ctx, &voxel_scene_buffer, buffer_infos[brick_buffer_index].offset, Brick, &.{
            test_brick_one,
            test_brick_all,
            test_brick_row,
        });
    }

    // brick indices transfer
    {
        const brick_indices_buffer_index = (Resource{ .device = .brick_indices_b }).toBufferIndex();
        try staging_buffer.transferToBuffer(ctx, &voxel_scene_buffer, buffer_infos[brick_indices_buffer_index].offset, BrickIndex, &.{
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 0 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 1 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 2 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 0 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 0 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 0 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 1 },
            BrickIndex{ .status = .loaded, .request_count = 100, .index = 0 },
        });
    }

    // brick set bits transfer
    {
        const brick_set_buffer_index = (Resource{ .device = .bricks_set_s }).toBufferIndex();
        try staging_buffer.transferToBuffer(ctx, &voxel_scene_buffer, buffer_infos[brick_set_buffer_index].offset, u8, &.{
            1 << 7 | 1 << 6 | 0 << 5 | 1 << 4 | 1 << 3 | 1 << 2 | 1 << 1 | 1 << 0,
            0,
            0,
            0,
        });
    }

    // brick limits transfer
    {
        // TODO: dont hard code
        const TODO_TMP_ACTIVE_BRICKS = 8;
        const brick_limits = [_]BrickLimits{.{
            .max_load_request_count = config.brick_load_request_count,
            .load_request_count = 0,
            .max_unload_request_count = config.brick_unload_request_count,
            .unload_request_count = 0,
            .max_active_bricks = @intCast(total_bricks),
            .active_bricks = TODO_TMP_ACTIVE_BRICKS,
        }};

        const brick_req_limits_buffer_index = (Resource{ .host_and_device = .brick_req_limits_s }).toBufferIndex();
        try staging_buffer.transferToBuffer(
            ctx,
            &request_buffer,
            buffer_infos[brick_req_limits_buffer_index].offset,
            BrickLimits,
            &brick_limits,
        );
    }

    return RayDeviceResources{
        .allocator = allocator,
        .buffer_infos = buffer_infos,
        .target_descriptor_pool = target_descriptor_pool,
        .target_descriptor_layouts = target_descriptor_layouts,
        .target_descriptor_sets = target_descriptor_sets,
        .target_image_info = target_image_info,
        .ray_buffer = ray_buffer,
        .brick_grid_state = brick_grid_state,
        .voxel_scene_buffer = voxel_scene_buffer,
        .request_buffer = request_buffer,
        .brick_load_request_count = config.brick_load_request_count,
        .brick_unload_request_count = config.brick_unload_request_count,
    };
}

pub inline fn deinit(self: RayDeviceResources, ctx: Context) void {
    for (self.target_descriptor_layouts) |layout| {
        ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, layout, null);
    }
    ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

    self.allocator.destroy(self.brick_grid_state);
    self.voxel_scene_buffer.deinit(ctx);
    self.ray_buffer.deinit(ctx);
    self.request_buffer.deinit(ctx);
}

pub const Resource = union(enum) {
    device: DeviceOnlyResources,
    host_and_device: HostAndDeviceResources,

    pub fn fromArray(comptime T: type, comptime resources: []const T) [resources.len]Resource {
        var rtr_res: [resources.len]Resource = undefined;
        switch (T) {
            DeviceOnlyResources => {
                for (&rtr_res, resources) |*rtr, resource| {
                    rtr.* = Resource{ .device = resource };
                }
            },
            HostAndDeviceResources => {
                for (&rtr_res, resources) |*rtr, resource| {
                    rtr.* = Resource{ .host_and_device = resource };
                }
            },
            else => {
                @compileError("unsupported resource type '" ++ @typeName(T) ++ "'");
            },
        }

        return rtr_res;
    }

    pub fn from(comptime resource: anytype) Resource {
        const ResType = @TypeOf(resource);
        switch (ResType) {
            DeviceOnlyResources => {
                return Resource{ .device = resource };
            },
            HostAndDeviceResources => {
                return Resource{ .host_and_device = resource };
            },
            else => {
                @compileError("unsupported resource type '" ++ @typeName(ResType) ++ "'");
            },
        }
    }

    pub fn toDescriptorIndex(comptime resource: Resource) usize {
        // Preconditions
        comptime {
            // First entry must be:
            std.debug.assert(@intFromEnum(DeviceOnlyResources.ray_pipeline_limits_s) == 0);

            // These are in a set and must be in correct order
            std.debug.assert(@intFromEnum(DeviceOnlyResources.bricks_set_s) ==
                (@intFromEnum(DeviceOnlyResources.brick_indices_b) - 1));
            std.debug.assert(@intFromEnum(DeviceOnlyResources.bricks_set_s) ==
                @intFromEnum(DeviceOnlyResources.bricks_b) - 2);

            switch (resource) {
                Resource.device => |d_resource| {
                    if (std.mem.endsWith(u8, @tagName(d_resource), "_b")) {
                        @compileError(@tagName(d_resource) ++ " is not a legal descriptor literal");
                    }
                },
                Resource.host_and_device => |hd_resource| {
                    if (std.mem.endsWith(u8, @tagName(hd_resource), "_b")) {
                        @compileError(@tagName(hd_resource) ++ " is not a legal descriptor literal");
                    }
                },
            }
        }

        switch (resource) {
            Resource.device => |d_resource| {
                const neg_offset: usize = offset_blk: {
                    if (@intFromEnum(d_resource) >= @intFromEnum(DeviceOnlyResources.bricks_b)) {
                        break :offset_blk 2;
                    }
                    break :offset_blk 0;
                };
                return @intFromEnum(d_resource) - neg_offset;
            },
            Resource.host_and_device => |hd_resource| {
                const neg_offset: usize = 2;
                return @intFromEnum(hd_resource) + DeviceOnlyResources.all_count - neg_offset;
            },
        }
    }

    pub fn toBufferIndex(comptime resource: Resource) usize {
        // Preconditions
        comptime {
            // Expect draw_image_s to be last entry
            std.debug.assert(@intFromEnum(DeviceOnlyResources.draw_image_s) == DeviceOnlyResources.all_count - 1);

            switch (resource) {
                Resource.device => |d_resource| {
                    if (d_resource == DeviceOnlyResources.draw_image_s) {
                        @compileError(@tagName(d_resource) ++ " is not a legal buffer literal");
                    }
                },
                Resource.host_and_device => {},
            }
        }

        switch (resource) {
            Resource.device => |d_resource| {
                return @intFromEnum(d_resource);
            },
            Resource.host_and_device => |hd_resource| {
                return @intFromEnum(hd_resource) + DeviceOnlyResources.all_count - DeviceOnlyResources.image_count;
            },
        }
    }
};
pub inline fn getDescriptorSets(self: RayDeviceResources, comptime resources: []const Resource) [resources.len]vk.DescriptorSet {
    var descriptor_sets: [resources.len]vk.DescriptorSet = undefined;
    inline for (resources, &descriptor_sets) |resource, *descriptor_set| {
        descriptor_set.* = self.target_descriptor_sets[resource.toDescriptorIndex()];
    }

    return descriptor_sets;
}

pub inline fn getDescriptorSetLayouts(self: RayDeviceResources, comptime resources: []const Resource) [resources.len]vk.DescriptorSetLayout {
    var descriptor_layouts: [resources.len]vk.DescriptorSetLayout = undefined;
    inline for (resources, &descriptor_layouts) |resource, *descriptor_layout| {
        descriptor_layout.* = self.target_descriptor_layouts[resource.toDescriptorIndex()];
    }

    return descriptor_layouts;
}

/// Reset the brick request limit counters
///
/// Caller should make sure reset is done by calling ``resetBrickReqLimitsBarrier()``
pub inline fn resetBrickReqLimits(self: RayDeviceResources, ctx: Context, command_buffer: vk.CommandBuffer) void {
    const brick_req_limits_buffer_index = (Resource{ .host_and_device = .brick_req_limits_s }).toBufferIndex();
    {
        const load_request_count_offset = self.buffer_infos[brick_req_limits_buffer_index].offset + @offsetOf(BrickLimits, "load_request_count");
        ctx.vkd.cmdFillBuffer(
            command_buffer,
            self.request_buffer.buffer,
            load_request_count_offset,
            @sizeOf(c_uint),
            0,
        );
    }

    {
        const unload_request_count_offset = self.buffer_infos[brick_req_limits_buffer_index].offset + @offsetOf(BrickLimits, "unload_request_count");
        ctx.vkd.cmdFillBuffer(
            command_buffer,
            self.request_buffer.buffer,
            unload_request_count_offset,
            @sizeOf(c_uint),
            0,
        );
    }
}

/// Reset barrier for the brick request limit counters
pub inline fn resetBrickReqLimitsBarrier(self: RayDeviceResources, ctx: Context, command_buffer: vk.CommandBuffer) void {
    const limits_memory_barrier = [_]vk.BufferMemoryBarrier{.{
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .buffer = self.voxel_scene_buffer.buffer,
        .offset = 0,
        .size = @sizeOf(BrickLimits),
    }};
    ctx.vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .transfer_bit = true },
        .{ .compute_shader_bit = true },
        .{},
        0,
        undefined,
        limits_memory_barrier.len,
        &limits_memory_barrier,
        0,
        undefined,
    );
}

/// Reset the ray limit counters
pub inline fn resetRayLimits(self: RayDeviceResources, ctx: Context, command_buffer: vk.CommandBuffer) void {
    {
        const limits_memory_barrier = [_]vk.BufferMemoryBarrier{.{
            .src_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
            .src_queue_family_index = ctx.queue_indices.compute,
            .dst_queue_family_index = ctx.queue_indices.compute,
            .buffer = self.ray_buffer.buffer,
            .offset = 0,
            .size = @sizeOf(ray_pipeline_types.RayHitLimits),
        }};
        ctx.vkd.cmdPipelineBarrier(
            command_buffer,
            .{ .compute_shader_bit = true },
            .{ .transfer_bit = true },
            .{},
            0,
            undefined,
            limits_memory_barrier.len,
            &limits_memory_barrier,
            0,
            undefined,
        );
    }

    var copy_region = [_]vk.BufferCopy{.{
        .src_offset = @offsetOf(ray_pipeline_types.RayHitLimits, "out_hit_count"),
        .dst_offset = @offsetOf(ray_pipeline_types.RayHitLimits, "in_hit_count"),
        .size = @sizeOf(c_uint),
    }};
    ctx.vkd.cmdCopyBuffer(
        command_buffer,
        self.ray_buffer.buffer,
        self.ray_buffer.buffer,
        copy_region.len,
        &copy_region,
    );

    {
        const limits_memory_barrier = [_]vk.BufferMemoryBarrier{.{
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
            .src_queue_family_index = ctx.queue_indices.compute,
            .dst_queue_family_index = ctx.queue_indices.compute,
            .buffer = self.ray_buffer.buffer,
            .offset = 0,
            .size = @sizeOf(ray_pipeline_types.RayHitLimits),
        }};
        ctx.vkd.cmdPipelineBarrier(
            command_buffer,
            .{ .transfer_bit = true },
            .{ .transfer_bit = true },
            .{},
            0,
            undefined,
            limits_memory_barrier.len,
            &limits_memory_barrier,
            0,
            undefined,
        );
    }

    ctx.vkd.cmdFillBuffer(
        command_buffer,
        self.ray_buffer.buffer,
        @offsetOf(ray_pipeline_types.RayHitLimits, "out_hit_count"),
        @offsetOf(ray_pipeline_types.RayHitLimits, "out_miss_count") + @sizeOf(c_uint),
        0,
    );

    {
        const limits_memory_barrier = [_]vk.BufferMemoryBarrier{.{
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
            .src_queue_family_index = ctx.queue_indices.compute,
            .dst_queue_family_index = ctx.queue_indices.compute,
            .buffer = self.ray_buffer.buffer,
            .offset = 0,
            .size = @sizeOf(ray_pipeline_types.RayHitLimits),
        }};
        ctx.vkd.cmdPipelineBarrier(
            command_buffer,
            .{ .transfer_bit = true },
            .{ .compute_shader_bit = true },
            .{},
            0,
            undefined,
            limits_memory_barrier.len,
            &limits_memory_barrier,
            0,
            undefined,
        );
    }
}

// Make request data readable on host
pub fn invalidateBrickRequestData(self: RayDeviceResources, ctx: Context) !void {
    // Preconditions
    comptime {
        // brick_req_limits_s must be first enum
        std.debug.assert(@intFromEnum(HostAndDeviceResources.brick_req_limits_s) == 0);

        // brick_unload_request_b must be last enum
        std.debug.assert(@intFromEnum(HostAndDeviceResources.brick_unload_request_b) ==
            (HostAndDeviceResources.all_count - 1));
    }

    const first_request_dat_index = (Resource{ .host_and_device = .brick_req_limits_s }).toBufferIndex();
    const req_data_offset = self.buffer_infos[first_request_dat_index].offset;

    const last_request_dat_index = (Resource{ .host_and_device = .brick_unload_request_b }).toBufferIndex();
    const last_byte = self.buffer_infos[last_request_dat_index].offset +
        self.buffer_infos[last_request_dat_index].range;

    try self.request_buffer.sync(.invalidate, ctx, req_data_offset, last_byte);
}

// Map the subset of request buffer used by the brick request system
pub fn mapBrickRequestData(self: *RayDeviceResources, ctx: Context) !void {
    const first_request_dat_index = (Resource{ .host_and_device = .brick_req_limits_s }).toBufferIndex();
    const req_data_offset = self.buffer_infos[first_request_dat_index].offset;

    const last_request_dat_index = (Resource{ .host_and_device = .brick_unload_request_b }).toBufferIndex();
    const last_byte = self.buffer_infos[last_request_dat_index].offset +
        self.buffer_infos[last_request_dat_index].range;

    try self.request_buffer.map(ctx, req_data_offset, last_byte);
}

pub inline fn getBufferInfo(self: RayDeviceResources, comptime resource: Resource) vk.DescriptorBufferInfo {
    const index = resource.toBufferIndex();
    return self.buffer_infos[index];
}

// TODO: move to common math/mem file
pub inline fn pow2Align(size: vk.DeviceSize, alignment: vk.DeviceSize) vk.DeviceSize {
    return (size + alignment - 1) & ~(alignment - 1);
}
