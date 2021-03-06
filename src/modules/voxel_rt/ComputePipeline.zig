const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const glfw = @import("glfw");
const tracy = @import("../../tracy.zig");

const render = @import("../render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;
const Texture = render.Texture;

const Camera = @import("Camera.zig");
const Sun = @import("Sun.zig");

/// compute shader that draws to a target texture
const ComputePipeline = @This();

// TODO: constant data
// TODO: explicit binding ..
pub const StateConfigs = struct {
    uniform_sizes: []const u64,
    storage_sizes: []const u64,
};

pub const ImageInfo = struct {
    width: f32,
    height: f32,
    image: vk.Image,
    sampler: vk.Sampler,
    image_view: vk.ImageView,
};

allocator: Allocator,

pipeline_layout: vk.PipelineLayout,
pipeline: *vk.Pipeline,

current_queue_buffer: usize,
command_pools: []vk.CommandPool,
command_buffers: []vk.CommandBuffer,
queues: []vk.Queue,
complete_semaphores: []vk.Semaphore,
complete_fences: []vk.Fence,

// info about the target image
target_image_info: ImageInfo,
target_descriptor_layout: vk.DescriptorSetLayout,
target_descriptor_pool: vk.DescriptorPool,
target_descriptor_set: vk.DescriptorSet,

// TODO: should be a slice or list. When the sum of a buffer size is greater than 250mb, we create a new buffer
uniform_offsets: []vk.DeviceSize,
storage_offsets: []vk.DeviceSize,
buffers: GpuBufferMemory,

work_group_dim: extern struct {
    x: u32,
    y: u32,
},

// TODO: descriptor has a lot of duplicate code with init ...
// TODO: refactor descriptor stuff to be configurable (loop array of config objects for buffer stuff)
// TODO: correctness if init fail, clean up resources created with errdefer

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(allocator: Allocator, ctx: Context, in_flight_count: usize, shader_path: []const u8, target_image_info: ImageInfo, state_config: StateConfigs) !ComputePipeline {
    std.debug.assert(in_flight_count <= ctx.queue_indices.compute_queue_count);

    var self: ComputePipeline = undefined;
    self.allocator = allocator;
    self.target_image_info = target_image_info;

    self.work_group_dim = blk: {
        const device_properties = ctx.getPhysicalDeviceProperties();
        const dim_size = device_properties.limits.max_compute_work_group_invocations;
        const uniform_dim = @floatToInt(u32, @floor(@sqrt(@intToFloat(f64, dim_size))));
        break :blk .{
            .x = uniform_dim,
            .y = uniform_dim / 2,
        };
    };

    self.queues = try allocator.alloc(vk.Queue, in_flight_count);
    errdefer allocator.free(self.queues);
    for (self.queues) |*queue, i| {
        queue.* = ctx.vkd.getDeviceQueue(ctx.logical_device, ctx.queue_indices.compute, @intCast(u32, i));
    }

    self.uniform_offsets = try allocator.alloc(vk.DeviceSize, state_config.uniform_sizes.len);
    errdefer allocator.free(self.uniform_offsets);
    self.storage_offsets = try allocator.alloc(vk.DeviceSize, state_config.storage_sizes.len);
    errdefer allocator.free(self.storage_offsets);

    var buffer_size: u64 = 0;
    for (state_config.uniform_sizes) |size, i| {
        self.uniform_offsets[i] = buffer_size;
        buffer_size += size;
    }
    for (state_config.storage_sizes) |size, i| {
        self.storage_offsets[i] = buffer_size;
        buffer_size += size;
    }
    self.buffers = try GpuBufferMemory.init(
        ctx,
        @intCast(vk.DeviceSize, buffer_size),
        .{ .storage_buffer_bit = true, .uniform_buffer_bit = true, .transfer_dst_bit = true },
        .{ .device_local_bit = true },
    );

    const set_count = 1 + state_config.uniform_sizes.len + state_config.storage_sizes.len;
    const layout_bindings = try allocator.alloc(vk.DescriptorSetLayoutBinding, set_count);
    defer allocator.free(layout_bindings);
    self.target_descriptor_layout = blk: {
        // target image
        layout_bindings[0] = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = .storage_image,
            .descriptor_count = 1,
            .stage_flags = .{
                .compute_bit = true,
            },
            .p_immutable_samplers = null,
        };
        for (state_config.uniform_sizes) |_, i| {
            layout_bindings[1 + i] = vk.DescriptorSetLayoutBinding{
                .binding = @intCast(u32, 1 + i),
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            };
        }
        const index_offset = 1 + state_config.uniform_sizes.len;
        for (state_config.storage_sizes) |_, i| {
            layout_bindings[index_offset + i] = vk.DescriptorSetLayoutBinding{
                .binding = @intCast(u32, index_offset + i),
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            };
        }

        const layout_info = vk.DescriptorSetLayoutCreateInfo{
            .flags = .{},
            .binding_count = @intCast(u32, layout_bindings.len),
            .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, layout_bindings.ptr),
        };
        break :blk try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &layout_info, null);
    };
    errdefer ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.target_descriptor_layout, null);

    const pool_sizes = try allocator.alloc(vk.DescriptorPoolSize, set_count);
    defer allocator.free(pool_sizes);
    self.target_descriptor_pool = blk: {
        pool_sizes[0] = vk.DescriptorPoolSize{
            .@"type" = .storage_image,
            .descriptor_count = 1,
        };
        for (state_config.uniform_sizes) |_, i| {
            pool_sizes[1 + i] = vk.DescriptorPoolSize{
                .@"type" = .uniform_buffer,
                .descriptor_count = 1,
            };
        }
        const index_offset = 1 + state_config.uniform_sizes.len;
        for (state_config.storage_sizes) |_, i| {
            pool_sizes[index_offset + i] = vk.DescriptorPoolSize{
                .@"type" = .storage_buffer,
                .descriptor_count = 1,
            };
        }
        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = 1,
            .pool_size_count = @intCast(u32, pool_sizes.len),
            .p_pool_sizes = @ptrCast([*]const vk.DescriptorPoolSize, pool_sizes.ptr),
        };
        break :blk try ctx.vkd.createDescriptorPool(ctx.logical_device, &pool_info, null);
    };
    errdefer ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

    {
        const descriptor_set_alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = self.target_descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &self.target_descriptor_layout),
        };
        try ctx.vkd.allocateDescriptorSets(ctx.logical_device, &descriptor_set_alloc_info, @ptrCast([*]vk.DescriptorSet, &self.target_descriptor_set));
    }

    {
        const buffer_infos = try allocator.alloc(vk.DescriptorBufferInfo, set_count - 1);
        defer allocator.free(buffer_infos);
        const write_descriptor_sets = try allocator.alloc(vk.WriteDescriptorSet, set_count);
        defer allocator.free(write_descriptor_sets);

        const image_info = vk.DescriptorImageInfo{
            .sampler = self.target_image_info.sampler,
            .image_view = self.target_image_info.image_view,
            .image_layout = .general,
        };
        write_descriptor_sets[0] = vk.WriteDescriptorSet{
            .dst_set = self.target_descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = @ptrCast([*]const vk.DescriptorImageInfo, &image_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        for (state_config.uniform_sizes) |size, i| {
            buffer_infos[i] = vk.DescriptorBufferInfo{
                .buffer = self.buffers.buffer,
                .offset = self.uniform_offsets[i],
                .range = size,
            };
            write_descriptor_sets[i + 1] = vk.WriteDescriptorSet{
                .dst_set = self.target_descriptor_set,
                .dst_binding = @intCast(u32, i + 1),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .uniform_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &buffer_infos[i]),
                .p_texel_buffer_view = undefined,
            };
        }

        // store any user defined shader buffers
        for (state_config.storage_sizes) |size, i| {
            const index = 1 + state_config.uniform_sizes.len + i;
            // descriptor for buffer info
            buffer_infos[index - 1] = vk.DescriptorBufferInfo{
                .buffer = self.buffers.buffer,
                .offset = self.storage_offsets[i],
                .range = size,
            };
            write_descriptor_sets[index] = vk.WriteDescriptorSet{
                .dst_set = self.target_descriptor_set,
                .dst_binding = @intCast(u32, index),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &buffer_infos[index - 1]),
                .p_texel_buffer_view = undefined,
            };
        }

        ctx.vkd.updateDescriptorSets(
            ctx.logical_device,
            @intCast(u32, write_descriptor_sets.len),
            write_descriptor_sets.ptr,
            0,
            undefined,
        );
    }

    self.pipeline_layout = blk: {
        const push_constant_ranges = [_]vk.PushConstantRange{.{
            .stage_flags = .{ .compute_bit = true },
            .offset = 0,
            .size = @sizeOf(Camera.Device) + @sizeOf(Sun.Device),
        }};
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast([*]vk.DescriptorSetLayout, &self.target_descriptor_layout),
            .push_constant_range_count = push_constant_ranges.len,
            .p_push_constant_ranges = &push_constant_ranges,
        };
        break :blk try ctx.createPipelineLayout(pipeline_layout_info);
    };
    self.pipeline = blk: {
        const SpecType = @TypeOf(self.work_group_dim);
        const spec_map = [_]vk.SpecializationMapEntry{ .{
            .constant_id = 0,
            .offset = @offsetOf(SpecType, "x"),
            .size = @sizeOf(u32),
        }, .{
            .constant_id = 1,
            .offset = @offsetOf(SpecType, "y"),
            .size = @sizeOf(u32),
        } };
        const specialization = vk.SpecializationInfo{
            .map_entry_count = spec_map.len,
            .p_map_entries = &spec_map,
            .data_size = @sizeOf(SpecType),
            .p_data = @ptrCast(*const anyopaque, &self.work_group_dim),
        };
        const stage = try render.pipeline.loadShaderStage(
            ctx,
            allocator,
            null,
            shader_path,
            .{ .compute_bit = true },
            @ptrCast(?*const vk.SpecializationInfo, &specialization),
        );
        defer ctx.destroyShaderModule(stage.module);

        // TOOD: read on defer_compile_bit_nv
        const pipeline_info = vk.ComputePipelineCreateInfo{
            .flags = .{},
            .stage = stage,
            .layout = self.pipeline_layout,
            .base_pipeline_handle = .null_handle, // TODO: GfxPipeline?
            .base_pipeline_index = -1,
        };
        break :blk try ctx.createComputePipeline(allocator, pipeline_info);
    };

    self.command_pools = try allocator.alloc(vk.CommandPool, in_flight_count);
    errdefer allocator.free(self.command_pools);
    self.command_buffers = try allocator.alloc(vk.CommandBuffer, in_flight_count);
    errdefer allocator.free(self.command_buffers);

    var initialized_command_pools: usize = 0;
    {
        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{},
            .queue_family_index = ctx.queue_indices.compute,
        };
        for (self.command_pools) |*command_pool, i| {
            command_pool.* = try ctx.vkd.createCommandPool(ctx.logical_device, &pool_info, null);
            self.command_buffers[i] = try render.pipeline.createCmdBuffer(ctx, command_pool.*);
        }
    }
    errdefer {
        var i: usize = 0;
        while (i < initialized_command_pools) : (i += 1) {
            ctx.vkd.freeCommandBuffers(
                ctx.logical_device,
                self.command_pools[i],
                @intCast(u32, 1),
                @ptrCast([*]const vk.CommandBuffer, &self.command_buffers[i]),
            );
            ctx.vkd.destroyCommandPool(ctx.logical_device, self.command_pools[i], null);
        }
    }

    const semaphore_info = vk.SemaphoreCreateInfo{ .flags = .{} };
    var semaphore_initialized: usize = 0;
    self.complete_semaphores = try allocator.alloc(vk.Semaphore, in_flight_count);
    errdefer allocator.free(self.complete_semaphores);
    for (self.complete_semaphores) |*semaphore, i| {
        semaphore.* = try ctx.vkd.createSemaphore(ctx.logical_device, &semaphore_info, null);
        semaphore_initialized = i + 1;
    }
    errdefer {
        var i: usize = 0;
        while (i < semaphore_initialized) : (i += 1) {
            ctx.vkd.destroySemaphore(ctx.logical_device, self.complete_semaphores[i], null);
        }
    }

    const fence_info = vk.FenceCreateInfo{
        .flags = .{
            .signaled_bit = true,
        },
    };
    self.complete_fences = try allocator.alloc(vk.Fence, in_flight_count);
    errdefer allocator.free(self.complete_fences);
    for (self.complete_fences) |*fence| {
        fence.* = try ctx.vkd.createFence(ctx.logical_device, &fence_info, null);
    }

    return ComputePipeline{
        .allocator = self.allocator,
        .pipeline_layout = self.pipeline_layout,
        .pipeline = self.pipeline,
        .current_queue_buffer = 0,
        .command_pools = self.command_pools,
        .command_buffers = self.command_buffers,
        .queues = self.queues,
        .complete_semaphores = self.complete_semaphores,
        .complete_fences = self.complete_fences,
        .target_image_info = self.target_image_info,
        .target_descriptor_layout = self.target_descriptor_layout,
        .target_descriptor_pool = self.target_descriptor_pool,
        .target_descriptor_set = self.target_descriptor_set,
        .uniform_offsets = self.uniform_offsets,
        .storage_offsets = self.storage_offsets,
        .buffers = self.buffers,
        .work_group_dim = self.work_group_dim,
    };
}

pub fn deinit(self: ComputePipeline, ctx: Context) void {
    // wait for all fences
    _ = ctx.vkd.waitForFences(
        ctx.logical_device,
        @intCast(u32, self.complete_fences.len),
        self.complete_fences.ptr,
        vk.TRUE,
        std.math.maxInt(u64),
    ) catch |err| std.debug.print("failed to wait for gfx fence, err: {any}", .{err});

    for (self.command_pools) |command_pool, i| {
        ctx.vkd.freeCommandBuffers(
            ctx.logical_device,
            command_pool,
            @intCast(u32, 1),
            @ptrCast([*]const vk.CommandBuffer, &self.command_buffers[i]),
        );
        ctx.vkd.destroyCommandPool(ctx.logical_device, command_pool, null);
    }
    self.allocator.free(self.command_buffers);
    self.allocator.free(self.command_pools);

    self.allocator.free(self.uniform_offsets);
    self.allocator.free(self.storage_offsets);
    self.buffers.deinit(ctx);

    for (self.complete_semaphores) |semaphore| {
        ctx.vkd.destroySemaphore(ctx.logical_device, semaphore, null);
    }
    self.allocator.free(self.complete_semaphores);
    for (self.complete_fences) |fence| {
        ctx.vkd.destroyFence(ctx.logical_device, fence, null);
    }
    self.allocator.free(self.complete_fences);
    self.allocator.free(self.queues);

    ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.target_descriptor_layout, null);
    ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyPipeline(self.pipeline);

    self.allocator.destroy(self.pipeline);
}

pub inline fn dispatch(self: *ComputePipeline, ctx: Context, camera: Camera, sun: Sun) !vk.Semaphore {
    {
        const wait_compute_zone = tracy.ZoneN(@src(), "idle wait compute");
        defer wait_compute_zone.End();

        // wait for previous compute dispatch to complete
        _ = try ctx.vkd.waitForFences(
            ctx.logical_device,
            1,
            @ptrCast([*]const vk.Fence, &self.complete_fences[self.current_queue_buffer]),
            vk.TRUE,
            std.math.maxInt(u64),
        );
        try ctx.vkd.resetFences(
            ctx.logical_device,
            1,
            @ptrCast([*]const vk.Fence, &self.complete_fences[self.current_queue_buffer]),
        );
    }

    try ctx.vkd.resetCommandPool(ctx.logical_device, self.command_pools[self.current_queue_buffer], .{});
    try self.recordCommandBuffer(ctx, self.current_queue_buffer, camera, sun);

    const compute_complete_semaphore = self.complete_semaphores[self.current_queue_buffer];
    // perform the compute ray tracing, draw to target texture
    const compute_submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.command_buffers[self.current_queue_buffer]),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast([*]const vk.Semaphore, &compute_complete_semaphore),
    };
    try ctx.vkd.queueSubmit(
        self.queues[self.current_queue_buffer],
        1,
        @ptrCast([*]const vk.SubmitInfo, &compute_submit_info),
        self.complete_fences[self.current_queue_buffer],
    );

    self.current_queue_buffer = (self.current_queue_buffer + 1) % self.command_buffers.len;
    return compute_complete_semaphore;
}

pub fn recordCommandBuffer(self: ComputePipeline, ctx: Context, index: usize, camera: Camera, sun: Sun) !void {
    const draw_zone = tracy.ZoneN(@src(), "compute record");
    defer draw_zone.End();

    const command_begin_info = vk.CommandBufferBeginInfo{
        .flags = .{
            .one_time_submit_bit = true,
        },
        .p_inheritance_info = null,
    };
    try ctx.vkd.beginCommandBuffer(self.command_buffers[index], &command_begin_info);
    ctx.vkd.cmdBindPipeline(self.command_buffers[index], vk.PipelineBindPoint.compute, self.pipeline.*);

    // push camera data as a push constant
    ctx.vkd.cmdPushConstants(
        self.command_buffers[index],
        self.pipeline_layout,
        .{ .compute_bit = true },
        0,
        @sizeOf(Camera.Device),
        &camera.d_camera,
    );

    // push sun data as a push constant
    ctx.vkd.cmdPushConstants(
        self.command_buffers[index],
        self.pipeline_layout,
        .{ .compute_bit = true },
        @sizeOf(Camera.Device),
        @sizeOf(Sun.Device),
        &sun.device_data,
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
        self.command_buffers[index],
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

    // bind target texture
    ctx.vkd.cmdBindDescriptorSets(
        self.command_buffers[index],
        .compute,
        self.pipeline_layout,
        0,
        1,
        @ptrCast([*]const vk.DescriptorSet, &self.target_descriptor_set),
        0,
        undefined,
    );
    const x_dispatch = @ceil(self.target_image_info.width / @intToFloat(f32, self.work_group_dim.x));
    const y_dispatch = @ceil(self.target_image_info.height / @intToFloat(f32, self.work_group_dim.y));

    ctx.vkd.cmdDispatch(self.command_buffers[index], @floatToInt(u32, x_dispatch), @floatToInt(u32, y_dispatch), 1);
    try ctx.vkd.endCommandBuffer(self.command_buffers[index]);
}
