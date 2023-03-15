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

// TODO: refactor command buffer should only be recorded on init and when rescaling!

/// compute shader that draws to a target texture
const EmitRayPipeline = @This();

allocator: Allocator,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,
queue: vk.Queue,
complete_semaphore: vk.Semaphore,

// info about the target image
target_descriptor_layout: vk.DescriptorSetLayout,
target_descriptor_pool: vk.DescriptorPool,
target_descriptor_set: vk.DescriptorSet,

image_size: vk.Extent2D,
// TODO: ray_buffer: *const GpuBufferMemory,
ray_buffer: GpuBufferMemory,

work_group_dim: Dispatch2,

// TODO: descriptor has a lot of duplicate code with init ...
// TODO: correctness if init fail, clean up resources created with errdefer

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(allocator: Allocator, ctx: Context, image_size: vk.Extent2D) !EmitRayPipeline {
    const work_group_dim = Dispatch2.init(ctx);

    // TODO: grab a dedicated compute queue if available https://github.com/Avokadoen/zig_vulkan/issues/163
    const queue = ctx.vkd.getDeviceQueue(ctx.logical_device, ctx.queue_indices.compute, @intCast(u32, 0));

    // TODO: allocate according to need
    var ray_buffer = try GpuBufferMemory.init(
        ctx,
        @intCast(vk.DeviceSize, 250 * 1024 * 1024), // alloc 250mb
        .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
        .{ .device_local_bit = true },
    );

    const target_descriptor_layout = blk: {
        const layout_bindings = [_]vk.DescriptorSetLayoutBinding{
            // RayBufferCursor
            .{
                .binding = 0,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            },
            // RayBuffer
            .{
                .binding = 1,
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
        const pool_sizes = [_]vk.DescriptorPoolSize{ .{
            .type = .storage_buffer,
            .descriptor_count = 1,
        }, .{
            .type = .storage_buffer,
            .descriptor_count = 1,
        } };
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
        const ray_buffer_cursor_buffer_info = vk.DescriptorBufferInfo{
            .buffer = ray_buffer.buffer,
            .offset = RayBufferCursor.buffer_offset,
            .range = @sizeOf(RayBufferCursor),
        };
        const ray_buffer_buffer_info = vk.DescriptorBufferInfo{
            .buffer = ray_buffer.buffer,
            .offset = pow2Align(
                ray_buffer_cursor_buffer_info.offset + ray_buffer_cursor_buffer_info.range,
                ctx.physical_device_limits.min_storage_buffer_offset_alignment,
            ),
            .range = image_size.width * image_size.height * @sizeOf(Ray),
        };

        const write_descriptor_set = [_]vk.WriteDescriptorSet{ .{
            .dst_set = target_descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &ray_buffer_cursor_buffer_info),
            .p_texel_buffer_view = undefined,
        }, .{
            .dst_set = target_descriptor_set,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &ray_buffer_buffer_info),
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
        const push_constant_ranges = [_]vk.PushConstantRange{.{
            .stage_flags = .{ .compute_bit = true },
            .offset = 0,
            // TODO: only need image widht and height!
            .size = @sizeOf(Camera.Device),
        }};
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &target_descriptor_layout),
            .push_constant_range_count = push_constant_ranges.len,
            .p_push_constant_ranges = &push_constant_ranges,
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
            .p_code = @ptrCast([*]const u32, &shaders.emit_primary_rays_spv),
            .code_size = shaders.emit_primary_rays_spv.len,
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

    return EmitRayPipeline{
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
        .image_size = image_size,
        .ray_buffer = ray_buffer,
        .work_group_dim = work_group_dim,
    };
}

pub fn deinit(self: EmitRayPipeline, ctx: Context) void {
    // TODO: waitDeviceIdle?

    ctx.vkd.freeCommandBuffers(
        ctx.logical_device,
        self.command_pool,
        @intCast(u32, 1),
        @ptrCast([*]const vk.CommandBuffer, &self.command_buffer),
    );
    ctx.vkd.destroyCommandPool(ctx.logical_device, self.command_pool, null);

    self.ray_buffer.deinit(ctx);

    ctx.vkd.destroySemaphore(ctx.logical_device, self.complete_semaphore, null);

    ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.target_descriptor_layout, null);
    ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyPipeline(self.pipeline);
}

// TODO: mention semaphore lifetime
pub inline fn dispatch(self: *EmitRayPipeline, ctx: Context, camera: Camera) !*vk.Semaphore {
    try ctx.vkd.resetCommandPool(ctx.logical_device, self.command_pool, .{});
    try self.recordCommandBuffer(ctx, camera);

    {
        @setRuntimeSafety(false);
        var semo_null_ptr: [*c]const vk.Semaphore = null;
        var wait_null_ptr: [*c]const vk.PipelineStageFlags = null;
        const compute_submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = semo_null_ptr,
            .p_wait_dst_stage_mask = wait_null_ptr,
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
pub fn recordCommandBuffer(self: EmitRayPipeline, ctx: Context, camera: Camera) !void {
    const record_zone = tracy.ZoneN(@src(), "emit ray compute record");
    defer record_zone.End();

    const command_begin_info = vk.CommandBufferBeginInfo{
        .flags = .{
            .one_time_submit_bit = true,
        },
        .p_inheritance_info = null,
    };
    try ctx.vkd.beginCommandBuffer(self.command_buffer, &command_begin_info);
    ctx.vkd.cmdBindPipeline(self.command_buffer, vk.PipelineBindPoint.compute, self.pipeline);

    // push camera data as a push constant
    ctx.vkd.cmdPushConstants(
        self.command_buffer,
        self.pipeline_layout,
        .{ .compute_bit = true },
        0,
        @sizeOf(Camera.Device),
        &camera.d_camera,
    );

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

    // put ray cursor at 0
    ctx.vkd.cmdFillBuffer(
        self.command_buffer,
        self.ray_buffer.buffer,
        RayBufferCursor.buffer_offset,
        pow2Align(@sizeOf(RayBufferCursor), 4),
        0,
    );

    const x_dispatch = @ceil(@intToFloat(f32, self.image_size.width) / @intToFloat(f32, self.work_group_dim.x));
    const y_dispatch = @ceil(@intToFloat(f32, self.image_size.height) / @intToFloat(f32, self.work_group_dim.y));

    ctx.vkd.cmdDispatch(self.command_buffer, @floatToInt(u32, x_dispatch), @floatToInt(u32, y_dispatch), 1);
    try ctx.vkd.endCommandBuffer(self.command_buffer);
}

// TODO: move to common math/mem file
pub inline fn pow2Align(alignment: vk.DeviceSize, size: vk.DeviceSize) vk.DeviceSize {
    return (size + alignment - 1) & ~(alignment - 1);
}
