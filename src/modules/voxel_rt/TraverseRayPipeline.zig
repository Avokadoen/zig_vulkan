const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const glfw = @import("glfw");
const tracy = @import("ztracy");

const shaders = @import("shaders");

const render = @import("../render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;
const StagingRamp = render.StagingRamp;

const Camera = @import("Camera.zig");

const ray_types = @import("ray_pipeline_types.zig");
const RayBufferCursor = ray_types.RayBufferCursor;
const Ray = ray_types.Ray;
const Dispatch2 = ray_types.Dispatch2;

// TODO: move types
pub const BrickGridState = extern struct {
    /// how many bricks in each axis
    dim: [3]f32,
    padding1: f32,

    min_point: [3]f32,
    scale: f32,
};
pub const Brick = packed struct {
    solid_mask: u512,
};

// must be kept in sync with ray_commons.HitRecord
pub const HitRecord = extern struct {
    point: [3]f32,
    normal_4b_and_material_index_28b: c_uint,
    previous_ray_direction: [3]f32,
    previous_ray_internal_reflection: f32,
    previous_color: [3]f32,
    pixel_coord: c_uint,
    padding: [3]f32,
    t_value: f32,
};

// TODO: convert to a struct ...
pub const BufferInfo = enum(u32) {
    // ray buffer info
    // if a cursor is removed, or added we must update emit manually
    in_ray_cursor,
    out_hit_cursor,
    out_miss_cursor,
    draw_cursor, // TODO: not used by traverse, but to make it easier to add this we will just add it to traverse shader for now

    in_hit_record_buffer,
    out_hit_record_buffer,

    // brick buffer info
    brick_grid_state,
    bricks_set,
    bricks,
};
const buffer_info_count = @typeInfo(BufferInfo).Enum.fields.len;
const ray_info_count = @enumToInt(BufferInfo.out_hit_record_buffer) + 1;
const brick_info_count = (@enumToInt(BufferInfo.bricks) + 1) - ray_info_count;

// TODO: refactor command buffer should only be recorded on init and when rescaling!

/// compute shader that draws to a target texture
const TraverseRayPipeline = @This();

allocator: Allocator,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

buffer_infos: [buffer_info_count]vk.DescriptorBufferInfo,

target_descriptor_layout: vk.DescriptorSetLayout,
target_descriptor_pool: vk.DescriptorPool,
target_descriptor_set: vk.DescriptorSet,

image_size: vk.Extent2D,
ray_hit_buffer: *const GpuBufferMemory,

brick_grid_state_buffer_offset: vk.DeviceSize,
brick_grid_state: *BrickGridState,
voxel_scene_buffer: GpuBufferMemory,

work_group_dim: Dispatch2,

// TODO: descriptor has a lot of duplicate code with init ...
// TODO: refactor descriptor sets to share logic between ray pipelines
// TODO: correctness if init fail, clean up resources created with errdefer

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(
    allocator: Allocator,
    ctx: Context,
    ray_hit_buffer: *const GpuBufferMemory,
    image_size: vk.Extent2D,
    init_command_pool: vk.CommandPool,
    staging_buffer: *StagingRamp,
) !TraverseRayPipeline {
    const zone = tracy.ZoneN(@src(), @typeName(TraverseRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    // TODO: change based on NVIDIA vs AMD vs Others?
    const work_group_dim = Dispatch2.init(ctx);

    var voxel_scene_buffer = try GpuBufferMemory.init(
        ctx,
        @intCast(vk.DeviceSize, 250 * 1024 * 1024), // alloc 250mb
        .{
            .storage_buffer_bit = true,
            .transfer_dst_bit = true,
        },
        .{ .device_local_bit = true },
    );
    errdefer voxel_scene_buffer.deinit(ctx);
    try voxel_scene_buffer.fill(ctx, init_command_pool, 0, voxel_scene_buffer.size, 0);

    const brick_grid_state_buffer_offset: vk.DeviceSize = 0;
    const brick_grid_state: *BrickGridState = blk: {
        var state = try allocator.create(BrickGridState);
        state.* = BrickGridState{
            .dim = [_]f32{ 32, 32, 32 },
            .padding1 = 0,
            .min_point = [_]f32{-1} ** 3,
            .scale = 2,
        };

        break :blk state;
    };
    errdefer allocator.destroy(brick_grid_state);

    try staging_buffer.transferToBuffer(
        ctx,
        &voxel_scene_buffer,
        brick_grid_state_buffer_offset,
        BrickGridState,
        &[1]BrickGridState{brick_grid_state.*},
    );
    const total_bricks = @floatToInt(vk.DeviceSize, brick_grid_state.dim[0] * brick_grid_state.dim[1] * brick_grid_state.dim[2]);
    std.debug.assert(total_bricks * @sizeOf(Brick) < voxel_scene_buffer.size);

    const target_descriptor_layout = blk: {
        const layout_bindings = comptime binding_blk: {
            var bindings: [buffer_info_count]vk.DescriptorSetLayoutBinding = undefined;
            inline for (&bindings, 0..buffer_info_count) |*binding, buffer_binding_num| {
                binding.* = vk.DescriptorSetLayoutBinding{
                    .binding = buffer_binding_num,
                    .descriptor_type = .storage_buffer,
                    .descriptor_count = 1,
                    .stage_flags = .{
                        .compute_bit = true,
                    },
                    .p_immutable_samplers = null,
                };
            }
            break :binding_blk bindings;
        };

        const layout_info = vk.DescriptorSetLayoutCreateInfo{
            .flags = .{},
            .binding_count = layout_bindings.len,
            .p_bindings = &layout_bindings,
        };
        break :blk try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &layout_info, null);
    };
    errdefer ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, target_descriptor_layout, null);

    const target_descriptor_pool = blk: {
        const pool_sizes = vk.DescriptorPoolSize{
            .type = .storage_buffer,
            .descriptor_count = buffer_info_count,
        };
        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast([*]const vk.DescriptorPoolSize, &pool_sizes),
        };
        break :blk try ctx.vkd.createDescriptorPool(ctx.logical_device, &pool_info, null);
    };
    errdefer ctx.vkd.destroyDescriptorPool(ctx.logical_device, target_descriptor_pool, null);

    var target_descriptor_set: vk.DescriptorSet = undefined;
    {
        const descriptor_set_alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = target_descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &target_descriptor_layout),
        };
        try ctx.vkd.allocateDescriptorSets(ctx.logical_device, &descriptor_set_alloc_info, @ptrCast([*]vk.DescriptorSet, &target_descriptor_set));
    }

    var buffer_infos: [buffer_info_count]vk.DescriptorBufferInfo = blk: {
        var infos: [buffer_info_count]vk.DescriptorBufferInfo = undefined;

        // TODO: when we convert this from enum to a struct we can bake some of the info into the struct.
        const hit_record_buffer_size = image_size.width * image_size.height * @sizeOf(HitRecord);
        const ranges = [buffer_info_count]vk.DeviceSize{
            // in_ray_cursor
            @sizeOf(RayBufferCursor),
            // out_hit_cursor
            @sizeOf(RayBufferCursor),
            // out_miss_cursor
            @sizeOf(RayBufferCursor),
            // draw_cursor
            @sizeOf(RayBufferCursor),
            // in hit_record_buffer
            hit_record_buffer_size, // TODO: x2, x4, x8? (reflection + reflaction worst case)
            // out hit_record_buffer
            hit_record_buffer_size, // TODO: x2, x4, x8? (reflection + reflaction worst case)
            // brick_grid_state
            @sizeOf(BrickGridState),
            // bricks_set
            try std.math.divCeil(vk.DeviceSize, total_bricks, 8),
            // bricks
            @sizeOf(Brick) * total_bricks,
        };

        for (&infos, ranges, 0..buffer_info_count) |*info, range, info_index| {
            info.* = vk.DescriptorBufferInfo{
                .buffer = if (info_index < ray_info_count) ray_hit_buffer.buffer else voxel_scene_buffer.buffer,
                // calculate offset by looking at previous info if there is any
                .offset = if (info_index == 0 or info_index == ray_info_count) 0 else pow2Align(
                    infos[info_index - 1].offset + infos[info_index - 1].range,
                    ctx.physical_device_limits.min_storage_buffer_offset_alignment,
                ),
                .range = range,
            };
        }

        // TODO: assert we are within the allocated sized of 250mb

        const write_descriptor_set = write_blk: {
            var writes: [buffer_info_count]vk.WriteDescriptorSet = undefined;
            for (&writes, &infos, 0..buffer_info_count) |*write, *info, buffer_info_index| {
                write.* = vk.WriteDescriptorSet{
                    .dst_set = target_descriptor_set,
                    .dst_binding = @intCast(u32, buffer_info_index),
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_buffer,
                    .p_image_info = undefined,
                    .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, info),
                    .p_texel_buffer_view = undefined,
                };
            }
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

    const pipeline_layout = blk: {
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &target_descriptor_layout),
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null,
        };
        break :blk try ctx.createPipelineLayout(pipeline_layout_info);
    };
    const pipeline = blk: {
        const spec_map = [_]vk.SpecializationMapEntry{ .{
            .constant_id = 0,
            .offset = @offsetOf(Dispatch2, "x"),
            .size = @sizeOf(u32),
        }, .{
            .constant_id = 1,
            .offset = @offsetOf(Dispatch2, "y"),
            .size = @sizeOf(u32),
        } };
        const specialization = vk.SpecializationInfo{
            .map_entry_count = spec_map.len,
            .p_map_entries = &spec_map,
            .data_size = @sizeOf(Dispatch2),
            .p_data = @ptrCast(*const anyopaque, &work_group_dim),
        };
        const module_create_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .p_code = @ptrCast([*]const u32, &shaders.traverse_rays_spv),
            .code_size = shaders.traverse_rays_spv.len,
        };
        const module = try ctx.vkd.createShaderModule(ctx.logical_device, &module_create_info, null);

        const stage = vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = .{ .compute_bit = true },
            .module = module,
            .p_name = "main",
            .p_specialization_info = @ptrCast(?*const vk.SpecializationInfo, &specialization),
        };
        defer ctx.destroyShaderModule(stage.module);

        // TOOD: read on defer_compile_bit_nv
        const pipeline_info = vk.ComputePipelineCreateInfo{
            .flags = .{},
            .stage = stage,
            .layout = pipeline_layout,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };
        break :blk try ctx.createComputePipeline(pipeline_info);
    };
    errdefer ctx.destroyPipeline(pipeline);

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
    try staging_buffer.transferToBuffer(ctx, &voxel_scene_buffer, buffer_infos[@enumToInt(BufferInfo.bricks)].offset, Brick, &.{
        test_brick_one,
        test_brick_all,
        test_brick_row,
        test_brick_one,
        test_brick_one,
        test_brick_one,
        test_brick_all,
        test_brick_one,
    });
    try staging_buffer.transferToBuffer(ctx, &voxel_scene_buffer, buffer_infos[@enumToInt(BufferInfo.bricks_set)].offset, u8, &.{
        1 << 7 | 1 << 6 | 0 << 5 | 1 << 4 | 1 << 3 | 1 << 2 | 1 << 1 | 1 << 0,
        0,
        0,
        0,
    });

    return TraverseRayPipeline{
        .allocator = allocator,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .buffer_infos = buffer_infos,
        .target_descriptor_layout = target_descriptor_layout,
        .target_descriptor_pool = target_descriptor_pool,
        .target_descriptor_set = target_descriptor_set,
        .image_size = image_size,
        .ray_hit_buffer = ray_hit_buffer,
        .brick_grid_state_buffer_offset = brick_grid_state_buffer_offset,
        .brick_grid_state = brick_grid_state,
        .voxel_scene_buffer = voxel_scene_buffer,
        .work_group_dim = work_group_dim,
    };
}

pub fn deinit(self: TraverseRayPipeline, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(TraverseRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    self.allocator.destroy(self.brick_grid_state);

    self.voxel_scene_buffer.deinit(ctx);

    ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.target_descriptor_layout, null);
    ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyPipeline(self.pipeline);
}

pub inline fn emitPipelineDescriptorInfo(self: TraverseRayPipeline) [3]vk.DescriptorBufferInfo {
    return [3]vk.DescriptorBufferInfo{
        self.buffer_infos[@enumToInt(BufferInfo.in_ray_cursor)],
        self.buffer_infos[@enumToInt(BufferInfo.draw_cursor)],
        self.buffer_infos[@enumToInt(BufferInfo.in_hit_record_buffer)],
    };
}

pub inline fn drawPipelineDescriptorInfo(self: TraverseRayPipeline) [2]vk.DescriptorBufferInfo {
    return [2]vk.DescriptorBufferInfo{
        self.buffer_infos[@enumToInt(BufferInfo.draw_cursor)],
        self.buffer_infos[@enumToInt(BufferInfo.out_hit_record_buffer)],
    };
}

pub inline fn missPipelineDescriptorInfo(self: TraverseRayPipeline) [3]vk.DescriptorBufferInfo {
    return [3]vk.DescriptorBufferInfo{
        self.buffer_infos[@enumToInt(BufferInfo.out_hit_cursor)],
        self.buffer_infos[@enumToInt(BufferInfo.out_miss_cursor)],
        self.buffer_infos[@enumToInt(BufferInfo.out_hit_record_buffer)],
    };
}

pub inline fn scatterPipelineDescriptorInfo(self: TraverseRayPipeline) [2][4]vk.DescriptorBufferInfo {
    return [2][4]vk.DescriptorBufferInfo{
        // traverse
        .{
            self.buffer_infos[@enumToInt(BufferInfo.out_hit_cursor)],
            self.buffer_infos[@enumToInt(BufferInfo.in_hit_record_buffer)],
            self.buffer_infos[@enumToInt(BufferInfo.in_ray_cursor)],
            self.buffer_infos[@enumToInt(BufferInfo.out_hit_record_buffer)],
        },
        // draw
        .{
            self.buffer_infos[@enumToInt(BufferInfo.out_hit_cursor)],
            self.buffer_infos[@enumToInt(BufferInfo.out_hit_record_buffer)],
            self.buffer_infos[@enumToInt(BufferInfo.out_hit_cursor)],
            self.buffer_infos[@enumToInt(BufferInfo.out_hit_record_buffer)],
        },
    };
}

pub fn appendPipelineCommands(self: TraverseRayPipeline, ctx: Context, command_buffer: vk.CommandBuffer) void {
    const zone = tracy.ZoneN(@src(), @typeName(TraverseRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (render.consts.enable_validation_layers) {
        const label_info = vk.DebugUtilsLabelEXT{
            .p_label_name = @typeName(TraverseRayPipeline) ++ " " ++ @src().fn_name,
            .color = [_]f32{ 0.4, 0.2, 0.2, 0.5 },
        };
        ctx.vkd.cmdBeginDebugUtilsLabelEXT(command_buffer, &label_info);
    }
    defer {
        if (render.consts.enable_validation_layers) {
            ctx.vkd.cmdEndDebugUtilsLabelEXT(command_buffer);
        }
    }

    // TODO: specify read only vs write only buffer elements (maybe actually loop buffer infos ?)
    const ray_buffer_memory_barrier = vk.BufferMemoryBarrier{
        .src_access_mask = .{ .shader_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .buffer = self.ray_hit_buffer.buffer,
        .offset = 0,
        .size = vk.WHOLE_SIZE,
    };
    // TODO: specify read only vs write only buffer elements (maybe actually loop buffer infos ?)
    const brick_buffer_memory_barrier = vk.BufferMemoryBarrier{
        .src_access_mask = .{ .shader_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .buffer = self.ray_hit_buffer.buffer,
        .offset = 0,
        .size = vk.WHOLE_SIZE,
    };
    const frame_mem_barriers = [_]vk.BufferMemoryBarrier{ ray_buffer_memory_barrier, brick_buffer_memory_barrier };
    ctx.vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .compute_shader_bit = true },
        .{ .compute_shader_bit = true },
        .{},
        0,
        undefined,
        frame_mem_barriers.len,
        &frame_mem_barriers,
        0,
        undefined,
    );

    ctx.vkd.cmdBindPipeline(command_buffer, vk.PipelineBindPoint.compute, self.pipeline);

    // bind target texture
    ctx.vkd.cmdBindDescriptorSets(
        command_buffer,
        .compute,
        self.pipeline_layout,
        0,
        1,
        @ptrCast([*]const vk.DescriptorSet, &self.target_descriptor_set),
        0,
        undefined,
    );

    // Assert that our two cursors are located next to eachother to avoid our fill nulling unrelated bytes
    std.debug.assert(@enumToInt(BufferInfo.out_miss_cursor) - @enumToInt(BufferInfo.out_hit_cursor) == 1);

    // we get distance between offset to account of alignment and padding
    const fill_range =
        self.buffer_infos[@enumToInt(BufferInfo.out_miss_cursor)].offset - self.buffer_infos[@enumToInt(BufferInfo.out_hit_cursor)].offset +
        self.buffer_infos[@enumToInt(BufferInfo.out_miss_cursor)].range;

    // TODO: if we perform this fill in the emit stage then we do not need duplicate synchronization
    //       we should also replace semaphores with proper memory barriers.
    //       Actually, we should use the transfer queue to do all of these fill buffers during the initial queue
    // put cursors at 0
    ctx.vkd.cmdFillBuffer(
        command_buffer,
        self.ray_hit_buffer.buffer,
        self.buffer_infos[@enumToInt(BufferInfo.out_hit_cursor)].offset,
        fill_range,
        0,
    );
    const reset_out_cursor_memory_barrier = vk.BufferMemoryBarrier{
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .buffer = self.ray_hit_buffer.buffer,
        .offset = self.buffer_infos[@enumToInt(BufferInfo.out_hit_cursor)].offset,
        .size = fill_range,
    };

    ctx.vkd.cmdFillBuffer(
        command_buffer,
        self.ray_hit_buffer.buffer,
        self.buffer_infos[@enumToInt(BufferInfo.in_ray_cursor)].offset + @offsetOf(RayBufferCursor, "cursor"),
        @sizeOf(c_int),
        0,
    );
    const reset_inn_cursor_memory_barrier = vk.BufferMemoryBarrier{
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .buffer = self.ray_hit_buffer.buffer,
        .offset = self.buffer_infos[@enumToInt(BufferInfo.in_ray_cursor)].offset + @offsetOf(RayBufferCursor, "cursor"),
        .size = @sizeOf(c_int),
    };
    const mem_barriers = [_]vk.BufferMemoryBarrier{ reset_out_cursor_memory_barrier, reset_inn_cursor_memory_barrier };

    ctx.vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .transfer_bit = true },
        .{ .compute_shader_bit = true },
        .{},
        0,
        undefined,
        mem_barriers.len,
        &mem_barriers,
        0,
        undefined,
    );

    const x_dispatch = @ceil(@intToFloat(f32, self.image_size.width) / @intToFloat(f32, self.work_group_dim.x));
    const y_dispatch = @ceil(@intToFloat(f32, self.image_size.height) / @intToFloat(f32, self.work_group_dim.y));

    ctx.vkd.cmdDispatch(command_buffer, @floatToInt(u32, x_dispatch), @floatToInt(u32, y_dispatch), 1);
}

// TODO: move to common math/mem file
pub inline fn pow2Align(size: vk.DeviceSize, alignment: vk.DeviceSize) vk.DeviceSize {
    return (size + alignment - 1) & ~(alignment - 1);
}
