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
const ImageInfo = ray_types.ImageInfo;

// TODO: refactor command buffer should only be recorded on init and when rescaling!

/// compute shader that draws to a target texture
const DrawRayPipeline = @This();

allocator: Allocator,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,
queue: vk.Queue,
complete_semaphore: vk.Semaphore,

// info about the target image
target_image_info: ImageInfo,
target_descriptor_layout: vk.DescriptorSetLayout,
target_descriptor_pool: vk.DescriptorPool,
target_descriptor_set: vk.DescriptorSet,

ray_buffer: *const GpuBufferMemory,

work_group_dim: Dispatch2,

submit_wait_stage: [1]vk.PipelineStageFlags = .{.{ .compute_shader_bit = true }},
draw_ray_descriptor_info: [2]vk.DescriptorBufferInfo,

// TODO: share descriptors across ray pipelines (use vk descriptor buffers!)
// TODO: descriptor has a lot of duplicate code with init ...
// TODO: correctness if init fail, clean up resources created with errdefer

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(
    allocator: Allocator,
    ctx: Context,
    ray_buffer: *const GpuBufferMemory,
    target_image_info: ImageInfo,
    draw_ray_descriptor_info: [2]vk.DescriptorBufferInfo,
) !DrawRayPipeline {
    const zone = tracy.ZoneN(@src(), @typeName(DrawRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    // TODO: change based on NVIDIA vs AMD vs Others?
    const work_group_dim = blk: {
        const device_properties = ctx.getPhysicalDeviceProperties();
        const dim_size = device_properties.limits.max_compute_work_group_invocations;
        const uniform_dim = @floatToInt(u32, @floor(@sqrt(@intToFloat(f64, dim_size))));
        break :blk .{
            .x = uniform_dim,
            .y = uniform_dim / 2,
        };
    };

    // TODO: grab a dedicated compute queue if available https://github.com/Avokadoen/zig_vulkan/issues/163
    // TODO: queue should be submitted by init caller
    const queue = ctx.vkd.getDeviceQueue(ctx.logical_device, ctx.queue_indices.compute, @intCast(u32, 0));

    const target_descriptor_layout = blk: {
        const layout_bindings = [_]vk.DescriptorSetLayoutBinding{
            // Render image
            .{
                .binding = 0,
                .descriptor_type = .storage_image,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            },
            // RayBufferCursor
            .{
                .binding = 1,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            },
            // RayBuffer
            .{
                .binding = 2,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            },
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
        const pool_sizes = [_]vk.DescriptorPoolSize{
            .{
                .type = .storage_image,
                .descriptor_count = 1,
            },
            .{
                .type = .storage_buffer,
                .descriptor_count = 2,
            },
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

    {
        const image_info = vk.DescriptorImageInfo{
            .sampler = target_image_info.sampler,
            .image_view = target_image_info.image_view,
            .image_layout = .general,
        };

        const write_descriptor_set = [_]vk.WriteDescriptorSet{ .{
            .dst_set = target_descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = @ptrCast([*]const vk.DescriptorImageInfo, &image_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }, .{
            .dst_set = target_descriptor_set,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &draw_ray_descriptor_info[0]),
            .p_texel_buffer_view = undefined,
        }, .{
            .dst_set = target_descriptor_set,
            .dst_binding = 2,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &draw_ray_descriptor_info[1]),
            .p_texel_buffer_view = undefined,
        } };

        ctx.vkd.updateDescriptorSets(
            ctx.logical_device,
            write_descriptor_set.len,
            &write_descriptor_set,
            0,
            undefined,
        );
    }

    const pipeline_layout = blk: {
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &target_descriptor_layout),
            .push_constant_range_count = 0,
            .p_push_constant_ranges = undefined,
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
            .p_code = @ptrCast([*]const u32, &shaders.draw_rays_spv),
            .code_size = shaders.draw_rays_spv.len,
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

    const command_pool = blk: {
        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{},
            .queue_family_index = ctx.queue_indices.compute,
        };
        break :blk try ctx.vkd.createCommandPool(ctx.logical_device, &pool_info, null);
    };
    errdefer ctx.vkd.destroyCommandPool(ctx.logical_device, command_pool, null);

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

    return DrawRayPipeline{
        .allocator = allocator,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .command_pool = command_pool,
        .command_buffer = command_buffer,
        .queue = queue,
        .complete_semaphore = complete_semaphore,
        .target_descriptor_layout = target_descriptor_layout,
        .target_descriptor_pool = target_descriptor_pool,
        .target_descriptor_set = target_descriptor_set,
        .ray_buffer = ray_buffer,
        .work_group_dim = work_group_dim,
        .target_image_info = target_image_info,
        .draw_ray_descriptor_info = draw_ray_descriptor_info,
    };
}

pub fn deinit(self: DrawRayPipeline, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(DrawRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();
    // TODO: waitDeviceIdle?

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

pub inline fn dispatch(self: *DrawRayPipeline, ctx: Context, wait_semaphore: *vk.Semaphore) !*vk.Semaphore {
    const zone = tracy.ZoneN(@src(), @typeName(DrawRayPipeline) ++ " " ++ @src().fn_name);
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
pub fn recordCommandBuffer(self: DrawRayPipeline, ctx: Context) !void {
    const zone = tracy.ZoneN(@src(), @typeName(DrawRayPipeline) ++ " " ++ @src().fn_name);
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

    // put cursor at 0, but not the max value of the cursor in the emit stage
    ctx.vkd.cmdFillBuffer(
        self.command_buffer,
        self.ray_buffer.buffer,
        self.draw_ray_descriptor_info[0].offset + @sizeOf(c_int),
        self.draw_ray_descriptor_info[0].range,
        0,
    );
    const buffer_memory_barrier = vk.BufferMemoryBarrier{
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .buffer = self.ray_buffer.buffer,
        .offset = self.draw_ray_descriptor_info[0].offset,
        .size = self.draw_ray_descriptor_info[0].range,
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
    const image_barrier = vk.ImageMemoryBarrier{
        .src_access_mask = .{ .shader_read_bit = true },
        .dst_access_mask = .{ .shader_write_bit = true },
        .old_layout = .shader_read_only_optimal,
        .new_layout = .general,
        .src_queue_family_index = ctx.queue_indices.graphics,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .image = self.target_image_info.image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    ctx.vkd.cmdPipelineBarrier(
        self.command_buffer,
        .{ .fragment_shader_bit = true },
        .{ .compute_shader_bit = true },
        .{},
        0,
        undefined,
        0,
        undefined,
        1,
        @ptrCast([*]const vk.ImageMemoryBarrier, &image_barrier),
    );

    const x_dispatch = @ceil(self.target_image_info.width / @intToFloat(f32, self.work_group_dim.x));
    const y_dispatch = @ceil(self.target_image_info.height / @intToFloat(f32, self.work_group_dim.y));

    ctx.vkd.cmdDispatch(self.command_buffer, @floatToInt(u32, x_dispatch), @floatToInt(u32, y_dispatch), 1);
    try ctx.vkd.endCommandBuffer(self.command_buffer);
}
