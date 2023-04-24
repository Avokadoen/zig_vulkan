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
pub const HitRecord = extern struct {
    point: [3]f32,
    normal_4b_and_material_index_28b: c_uint,
    ray_direction: [3]f32,
    ray_internal_reflection: f32,
};

// TODO: convert to a struct ...
pub const BufferInfo = enum(u32) {
    // ray buffer info
    in_ray_cursor,
    ray_buffer,
    out_hit_cursor,
    out_miss_cursor,
    hit_record_buffer,

    // brick buffer info
    brick_grid_state,
    bricks_set,
    bricks,
};
const buffer_info_count = @typeInfo(BufferInfo).Enum.fields.len;
const ray_info_count = @enumToInt(BufferInfo.hit_record_buffer) + 1;
const brick_info_count = (@enumToInt(BufferInfo.bricks) + 1) - ray_info_count;

// TODO: refactor command buffer should only be recorded on init and when rescaling!

/// compute shader that draws to a target texture
const TraverseRayPipeline = @This();

allocator: Allocator,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,
queue_family_index: u32,
queue: vk.Queue,
complete_semaphore: vk.Semaphore,

buffer_infos: [buffer_info_count]vk.DescriptorBufferInfo,

target_descriptor_layout: vk.DescriptorSetLayout,
target_descriptor_pool: vk.DescriptorPool,
target_descriptor_set: vk.DescriptorSet,

image_size: vk.Extent2D,
ray_buffer: *const GpuBufferMemory,

brick_grid_state_buffer_offset: vk.DeviceSize,
brick_grid_state: *BrickGridState,
voxel_scene_buffer: GpuBufferMemory,

work_group_dim: Dispatch2,
submit_wait_stage: [1]vk.PipelineStageFlags = .{.{ .compute_shader_bit = true }},

// TODO: descriptor has a lot of duplicate code with init ...
// TODO: refactor descriptor sets to share logic between ray pipelines
// TODO: correctness if init fail, clean up resources created with errdefer

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(
    allocator: Allocator,
    ctx: Context,
    ray_buffer: *const GpuBufferMemory,
    image_size: vk.Extent2D,
    staging_buffer: *StagingRamp,
) !TraverseRayPipeline {
    const zone = tracy.ZoneN(@src(), @typeName(TraverseRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    // TODO: change based on NVIDIA vs AMD vs Others?
    const work_group_dim = Dispatch2.init(ctx);

    // TODO: grab a dedicated compute queue if available https://github.com/Avokadoen/zig_vulkan/issues/163
    const queue_family_index = ctx.queue_indices.compute;
    const queue = ctx.vkd.getDeviceQueue(ctx.logical_device, queue_family_index, @intCast(u32, 0));

    const command_pool = blk: {
        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{},
            .queue_family_index = ctx.queue_indices.compute,
        };
        break :blk try ctx.vkd.createCommandPool(ctx.logical_device, &pool_info, null);
    };
    errdefer ctx.vkd.destroyCommandPool(ctx.logical_device, command_pool, null);

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
    try voxel_scene_buffer.fill(ctx, command_pool, 0, voxel_scene_buffer.size, 0);

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
        const pool_sizes = comptime pool_size_blk: {
            var sizes: [buffer_info_count]vk.DescriptorPoolSize = undefined;
            inline for (&sizes, 0..buffer_info_count) |*size, _| {
                size.* = .{
                    .type = .storage_buffer,
                    .descriptor_count = 1,
                };
            }
            break :pool_size_blk sizes;
        };
        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = 1,
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
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
        const ranges = [buffer_info_count]vk.DeviceSize{
            // in_ray_cursor
            @sizeOf(RayBufferCursor),
            // ray_buffer
            image_size.width * image_size.height * @sizeOf(Ray),
            // out_hit_cursor
            @sizeOf(RayBufferCursor),
            // out_miss_cursor
            @sizeOf(RayBufferCursor),
            // hit_record_buffer
            image_size.width * image_size.height * @sizeOf(HitRecord), // TODO: x2, x4, x8? (reflection + reflaction worst case)
            // brick_grid_state
            @sizeOf(BrickGridState),
            // bricks_set
            try std.math.divCeil(vk.DeviceSize, total_bricks, 8),
            // bricks
            @sizeOf(Brick) * total_bricks,
        };

        for (&infos, ranges, 0..buffer_info_count) |*info, range, info_index| {
            info.* = vk.DescriptorBufferInfo{
                .buffer = if (info_index < ray_info_count) ray_buffer.buffer else voxel_scene_buffer.buffer,
                // calculate offset by looking at previous info if there is any
                .offset = if (info_index == 0 or info_index == ray_info_count) 0 else pow2Align(
                    infos[info_index - 1].offset + infos[info_index - 1].range,
                    ctx.physical_device_limits.min_storage_buffer_offset_alignment,
                ),
                .range = range,
            };
        }

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

    const command_buffer = try render.pipeline.createCmdBuffer(ctx, command_pool);
    errdefer ctx.vkd.freeCommandBuffers(
        ctx.logical_device,
        command_pool,
        @intCast(u32, 1),
        @ptrCast([*]const vk.CommandBuffer, &command_buffer),
    );

    const complete_semaphore = blk: {
        const semaphore_info = vk.SemaphoreCreateInfo{ .flags = .{} };
        break :blk try ctx.vkd.createSemaphore(ctx.logical_device, &semaphore_info, null);
    };
    errdefer ctx.vkd.destroySemaphore(ctx.logical_device, complete_semaphore, null);

    const test_brick_none = Brick{
        .solid_mask = @as(u512, 0),
    };
    const test_brick_one = Brick{
        .solid_mask = @as(u512, 1),
    };
    const test_brick_all = Brick{
        .solid_mask = ~@as(u512, 0),
    };
    try staging_buffer.transferToBuffer(ctx, &voxel_scene_buffer, buffer_infos[@enumToInt(BufferInfo.bricks)].offset, Brick, &.{
        test_brick_one,
        test_brick_all,
        test_brick_none,
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
        .command_pool = command_pool,
        .command_buffer = command_buffer,
        .queue_family_index = queue_family_index,
        .queue = queue,
        .complete_semaphore = complete_semaphore,
        .buffer_infos = buffer_infos,
        .target_descriptor_layout = target_descriptor_layout,
        .target_descriptor_pool = target_descriptor_pool,
        .target_descriptor_set = target_descriptor_set,
        .image_size = image_size,
        .ray_buffer = ray_buffer,
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

    // TODO: waitDeviceIdle?
    self.voxel_scene_buffer.deinit(ctx);

    ctx.vkd.freeCommandBuffers(
        ctx.logical_device,
        self.command_pool,
        @intCast(u32, 1),
        @ptrCast([*]const vk.CommandBuffer, &self.command_buffer),
    );
    ctx.vkd.destroyCommandPool(ctx.logical_device, self.command_pool, null);

    ctx.vkd.destroySemaphore(ctx.logical_device, self.complete_semaphore, null);

    ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.target_descriptor_layout, null);
    ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyPipeline(self.pipeline);
}

pub inline fn inRayBufferInfos(self: TraverseRayPipeline) [2]vk.DescriptorBufferInfo {
    return [2]vk.DescriptorBufferInfo{
        self.buffer_infos[@enumToInt(BufferInfo.in_ray_cursor)],
        self.buffer_infos[@enumToInt(BufferInfo.ray_buffer)],
    };
}

pub inline fn outRayBufferInfos(self: TraverseRayPipeline) [2]vk.DescriptorBufferInfo {
    return [2]vk.DescriptorBufferInfo{
        self.buffer_infos[@enumToInt(BufferInfo.out_hit_cursor)],
        self.buffer_infos[@enumToInt(BufferInfo.hit_record_buffer)],
    };
}

// TODO: mention semaphore lifetime
pub inline fn dispatch(self: *TraverseRayPipeline, ctx: Context, wait_semaphore: *vk.Semaphore) !*vk.Semaphore {
    const zone = tracy.ZoneN(@src(), @typeName(TraverseRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    try ctx.vkd.resetCommandPool(ctx.logical_device, self.command_pool, .{});
    try self.recordCommandBuffer(ctx);

    {
        const compute_submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, wait_semaphore),
            .p_wait_dst_stage_mask = @ptrCast([*]const vk.PipelineStageFlags, &self.submit_wait_stage),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.command_buffer),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast([*]const vk.Semaphore, &self.complete_semaphore),
        };
        // TODO: only do one submit for all ray pipelines!
        try ctx.vkd.queueSubmit(
            self.queue,
            1,
            @ptrCast([*]const vk.SubmitInfo, &compute_submit_info),
            .null_handle,
        );
    }

    return &self.complete_semaphore;
}

// TODO: static command buffer (only record once)
pub fn recordCommandBuffer(self: TraverseRayPipeline, ctx: Context) !void {
    const zone = tracy.ZoneN(@src(), @typeName(TraverseRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    const command_begin_info = vk.CommandBufferBeginInfo{
        .flags = .{
            .one_time_submit_bit = true,
        },
        .p_inheritance_info = null,
    };
    try ctx.vkd.beginCommandBuffer(self.command_buffer, &command_begin_info);
    ctx.vkd.cmdBindPipeline(self.command_buffer, vk.PipelineBindPoint.compute, self.pipeline);

    // bind target texture
    ctx.vkd.cmdBindDescriptorSets(
        self.command_buffer,
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
        self.command_buffer,
        self.ray_buffer.buffer,
        self.buffer_infos[@enumToInt(BufferInfo.out_hit_cursor)].offset,
        fill_range,
        0,
    );
    const buffer_memory_barrier = vk.BufferMemoryBarrier{
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
        .src_queue_family_index = self.queue_family_index,
        .dst_queue_family_index = self.queue_family_index,
        .buffer = self.ray_buffer.buffer,
        .offset = self.buffer_infos[@enumToInt(BufferInfo.out_hit_cursor)].offset,
        .size = fill_range,
    };
    ctx.vkd.cmdPipelineBarrier(
        self.command_buffer,
        .{ .transfer_bit = true },
        .{ .compute_shader_bit = true },
        .{},
        0,
        undefined,
        1,
        @ptrCast([*]const vk.BufferMemoryBarrier, &buffer_memory_barrier),
        0,
        undefined,
    );

    const x_dispatch = @ceil(@intToFloat(f32, self.image_size.width) / @intToFloat(f32, self.work_group_dim.x));
    const y_dispatch = @ceil(@intToFloat(f32, self.image_size.height) / @intToFloat(f32, self.work_group_dim.y));

    ctx.vkd.cmdDispatch(self.command_buffer, @floatToInt(u32, x_dispatch), @floatToInt(u32, y_dispatch), 1);
    try ctx.vkd.endCommandBuffer(self.command_buffer);
}

// TODO: move to common math/mem file
pub inline fn pow2Align(size: vk.DeviceSize, alignment: vk.DeviceSize) vk.DeviceSize {
    return (size + alignment - 1) & ~(alignment - 1);
}
