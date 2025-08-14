const std = @import("std");
const Allocator = std.mem.Allocator;

const ecez = @import("ecez");
const vk = @import("vulkan");
const glfw = @import("glfw");
const tracy = @import("ztracy");

const render = @import("../render.zig");
const context = render.context;
const gpu_buffer_memory = render.gpu_buffer_memory;
const Texture = render.Texture;

const DeviceCamera = @import("camera.zig").components.DeviceCamera;
const DeviceSun = @import("sun.zig").components.DeviceSun;

/// compute shader that draws to a target texture
const ComputePipeline = @This();

// TODO: constant data
// TODO: explicit binding ..
pub const StateConfigs = struct {
    pub const max_uniforms = 4;
    pub const max_ssbos = 8;

    uniform_sizes: []const u64,
    storage_sizes: []const u64,

    pub fn init(uniform_sizes: []const u64, storage_sizes: []const u64) StateConfigs {
        std.debug.assert(uniform_sizes.len < max_uniforms);
        std.debug.assert(storage_sizes.len < max_ssbos);

        return StateConfigs{
            .uniform_sizes = uniform_sizes,
            .storage_sizes = storage_sizes,
        };
    }
};

pub const ImageInfo = struct {
    width: f32,
    height: f32,
    image: vk.Image,
    sampler: vk.Sampler,
    image_view: vk.ImageView,
};

pub const WorkgroupSize = struct {
    x: u32,
    y: u32,
};

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,
complete_semaphore: vk.Semaphore,
complete_fence: vk.Fence,

// info about the target image
target_image_info: ImageInfo,
target_descriptor_layout: vk.DescriptorSetLayout,
target_descriptor_pool: vk.DescriptorPool,
target_descriptor_set: vk.DescriptorSet,

uniform_offsets: [StateConfigs.max_uniforms]vk.DeviceSize,
storage_offsets: [StateConfigs.max_ssbos]vk.DeviceSize,

buffer_entity: ecez.Entity,

// TODO: descriptor has a lot of duplicate code with init ...
// TODO: refactor descriptor stuff to be configurable (loop array of config objects for buffer stuff)
// TODO: correctness if init fail, clean up resources created with errdefer

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(
    vki: context.components.vk_dispatch.Instance,
    physical_device: context.components.PhysicalDevice,
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.Device,
    queue_indices: context.components.QueueFamilyIndices,
    comptime Storage: type,
    storage: *Storage,
    target_image_info: ImageInfo,
    state_config: StateConfigs,
    specialization_constants: anytype,
) !ComputePipeline {
    const uniform_len = state_config.uniform_sizes.len;
    const storage_len = state_config.storage_sizes.len;
    var uniform_offsets: [StateConfigs.max_uniforms]vk.DeviceSize = undefined;
    var storage_offsets: [StateConfigs.max_ssbos]vk.DeviceSize = undefined;

    var buffer_size: u64 = 0;
    for (uniform_offsets[0..uniform_len], state_config.uniform_sizes) |*uniform_offset, size| {
        uniform_offset.* = buffer_size;
        buffer_size += size;
    }
    for (storage_offsets[0..storage_len], state_config.storage_sizes) |*storage_offset, size| {
        storage_offset.* = buffer_size;
        buffer_size += size;
    }

    const buffer = try gpu_buffer_memory.createGpuBufferMemoryComponents(
        vki,
        physical_device,
        vkd,
        logical_device,
        @intCast(buffer_size),
        .{ .storage_buffer_bit = true, .uniform_buffer_bit = true },
        .{ .device_local_bit = true, .host_visible_bit = true },
    );
    const buffer_entity = buffer_init: {
        errdefer gpu_buffer_memory.destroyBuffer(vkd, logical_device, buffer);

        break :buffer_init try storage.createEntity(.{buffer});
    };

    const render_target_count = 1;
    const max_set_count = render_target_count + StateConfigs.max_uniforms + StateConfigs.max_ssbos;
    const set_count: u32 = @intCast(render_target_count + uniform_len + storage_len);
    const target_descriptor_layout = blk: {
        var layout_bindings: [max_set_count]vk.DescriptorSetLayoutBinding = undefined;
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
        for (state_config.uniform_sizes, 0..) |_, i| {
            layout_bindings[1 + i] = vk.DescriptorSetLayoutBinding{
                .binding = @intCast(1 + i),
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            };
        }
        const index_offset = 1 + state_config.uniform_sizes.len;
        for (state_config.storage_sizes, 0..) |_, i| {
            layout_bindings[index_offset + i] = vk.DescriptorSetLayoutBinding{
                .binding = @intCast(index_offset + i),
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
            .binding_count = set_count,
            .p_bindings = @ptrCast(&layout_bindings),
        };
        break :blk try vkd.createDescriptorSetLayout(logical_device.v, &layout_info, null);
    };
    errdefer vkd.destroyDescriptorSetLayout(logical_device.v, target_descriptor_layout, null);

    var pool_sizes: [max_set_count]vk.DescriptorPoolSize = undefined;
    const target_descriptor_pool = blk: {
        pool_sizes[0] = vk.DescriptorPoolSize{
            .type = .storage_image,
            .descriptor_count = 1,
        };
        for (state_config.uniform_sizes, 0..) |_, i| {
            pool_sizes[1 + i] = vk.DescriptorPoolSize{
                .type = .uniform_buffer,
                .descriptor_count = 1,
            };
        }
        const index_offset = 1 + state_config.uniform_sizes.len;
        for (state_config.storage_sizes, 0..) |_, i| {
            pool_sizes[index_offset + i] = vk.DescriptorPoolSize{
                .type = .storage_buffer,
                .descriptor_count = 1,
            };
        }
        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = 1,
            .pool_size_count = @intCast(set_count),
            .p_pool_sizes = @ptrCast(&pool_sizes),
        };
        break :blk try vkd.createDescriptorPool(logical_device.v, &pool_info, null);
    };
    errdefer vkd.destroyDescriptorPool(logical_device.v, target_descriptor_pool, null);

    var target_descriptor_set: vk.DescriptorSet = undefined;
    {
        const descriptor_set_alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = target_descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&target_descriptor_layout),
        };
        try vkd.allocateDescriptorSets(
            logical_device.v,
            &descriptor_set_alloc_info,
            @ptrCast(&target_descriptor_set),
        );
    }
    errdefer {
        vkd.freeDescriptorSets(
            logical_device.v,
            target_descriptor_pool,
            1,
            @ptrCast(&target_descriptor_set),
        ) catch {};
    }

    {
        var buffer_infos: [max_set_count - render_target_count]vk.DescriptorBufferInfo = undefined;
        var write_descriptor_sets: [max_set_count]vk.WriteDescriptorSet = undefined;

        const image_info = vk.DescriptorImageInfo{
            .sampler = target_image_info.sampler,
            .image_view = target_image_info.image_view,
            .image_layout = .general,
        };
        write_descriptor_sets[0] = vk.WriteDescriptorSet{
            .dst_set = target_descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = @ptrCast(&image_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        for (state_config.uniform_sizes, 0..) |size, i| {
            buffer_infos[i] = vk.DescriptorBufferInfo{
                .buffer = buffer.buffer,
                .offset = uniform_offsets[i],
                .range = size,
            };
            write_descriptor_sets[i + 1] = vk.WriteDescriptorSet{
                .dst_set = target_descriptor_set,
                .dst_binding = @intCast(i + 1),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .uniform_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast(&buffer_infos[i]),
                .p_texel_buffer_view = undefined,
            };
        }

        // store any user defined shader buffers
        for (state_config.storage_sizes, 0..) |size, i| {
            const index = 1 + state_config.uniform_sizes.len + i;
            // descriptor for buffer info
            buffer_infos[index - 1] = vk.DescriptorBufferInfo{
                .buffer = buffer.buffer,
                .offset = storage_offsets[i],
                .range = size,
            };
            write_descriptor_sets[index] = vk.WriteDescriptorSet{
                .dst_set = target_descriptor_set,
                .dst_binding = @intCast(index),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast(&buffer_infos[index - 1]),
                .p_texel_buffer_view = undefined,
            };
        }

        vkd.updateDescriptorSets(
            logical_device.v,
            set_count,
            &write_descriptor_sets,
            0,
            undefined,
        );
    }

    const pipeline_layout = blk: {
        const push_constant_ranges = [_]vk.PushConstantRange{.{
            .stage_flags = .{ .compute_bit = true },
            .offset = 0,
            .size = @sizeOf(DeviceCamera) + @sizeOf(DeviceSun),
        }};
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&target_descriptor_layout),
            .push_constant_range_count = push_constant_ranges.len,
            .p_push_constant_ranges = &push_constant_ranges,
        };
        break :blk try vkd.createPipelineLayout(logical_device.v, &pipeline_layout_info, null);
    };

    const pipeline = blk: {
        const SpecializationConsts = @TypeOf(specialization_constants);
        switch (@typeInfo(SpecializationConsts)) {
            .@"struct" => |struct_info| {
                if (struct_info.layout != .@"extern") {
                    @compileError("specialization_constants must be a extern struct");
                }
            },
            else => @compileError("specialization_constants must be a struct of specializations constants"),
        }

        const fields = std.meta.fields(SpecializationConsts);
        const spec_map = comptime generate_spec_map_blk: {
            var map: [fields.len]vk.SpecializationMapEntry = undefined;
            for (&map, fields, 0..) |*entry, field, id| {
                entry.* = .{
                    .constant_id = id,
                    .offset = @offsetOf(SpecializationConsts, field.name),
                    .size = @sizeOf(field.type),
                };
            }
            break :generate_spec_map_blk map;
        };

        const specialization = vk.SpecializationInfo{
            .map_entry_count = spec_map.len,
            .p_map_entries = &spec_map,
            .data_size = @sizeOf(SpecializationConsts),
            .p_data = @ptrCast(&specialization_constants),
        };

        const brick_raytracer_comp_spv align(@alignOf(u32)) = @embedFile("brick_raytracer_comp_spv").*;
        const module_create_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .p_code = @ptrCast(&brick_raytracer_comp_spv),
            .code_size = brick_raytracer_comp_spv.len,
        };
        const module = try vkd.createShaderModule(logical_device.v, &module_create_info, null);

        const stage = vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = .{ .compute_bit = true },
            .module = module,
            .p_name = "main",
            .p_specialization_info = @ptrCast(&specialization),
        };
        defer vkd.destroyShaderModule(logical_device.v, stage.module, null);

        const pipeline_info = vk.ComputePipelineCreateInfo{
            .flags = .{},
            .stage = stage,
            .layout = pipeline_layout,
            .base_pipeline_handle = .null_handle, // TODO: GfxPipeline?
            .base_pipeline_index = -1,
        };

        break :blk try context.createComputePipeline(vkd, logical_device, pipeline_info);
    };

    const pool_info = vk.CommandPoolCreateInfo{
        .flags = .{ .transient_bit = true },
        .queue_family_index = queue_indices.compute,
    };
    const command_pool = try vkd.createCommandPool(logical_device.v, &pool_info, null);
    errdefer vkd.destroyCommandPool(logical_device.v, command_pool, null);

    const command_buffer = try render.pipeline.createCmdBuffer(vkd, logical_device, command_pool);
    errdefer vkd.freeCommandBuffers(
        logical_device.v,
        command_pool,
        1,
        @ptrCast(&command_buffer),
    );

    const semaphore_info = vk.SemaphoreCreateInfo{ .flags = .{} };
    const complete_semaphore = try vkd.createSemaphore(logical_device.v, &semaphore_info, null);
    errdefer vkd.destroySemaphore(logical_device.v, complete_semaphore, null);

    const fence_info = vk.FenceCreateInfo{
        .flags = .{
            .signaled_bit = true,
        },
    };
    const complete_fence = try vkd.createFence(logical_device.v, &fence_info, null);
    errdefer vkd.destroyFence(logical_device.v, complete_fence);

    return ComputePipeline{
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .command_pool = command_pool,
        .command_buffer = command_buffer,
        .complete_semaphore = complete_semaphore,
        .complete_fence = complete_fence,
        .target_image_info = target_image_info,
        .target_descriptor_layout = target_descriptor_layout,
        .target_descriptor_pool = target_descriptor_pool,
        .target_descriptor_set = target_descriptor_set,
        .uniform_offsets = uniform_offsets,
        .storage_offsets = storage_offsets,
        .buffer_entity = buffer_entity,
    };
}

pub fn deinit(
    self: ComputePipeline,
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.Device,
) void {
    // wait for all fences
    _ = vkd.waitForFences(
        logical_device.v,
        1,
        @ptrCast(&self.complete_fence),
        vk.TRUE,
        std.math.maxInt(u64),
    ) catch |err| std.debug.print("failed to wait for gfx fence, err: {any}", .{err});

    vkd.freeCommandBuffers(
        logical_device.v,
        self.command_pool,
        @intCast(1),
        @ptrCast(&self.command_buffer),
    );
    vkd.destroyCommandPool(logical_device.v, self.command_pool, null);

    vkd.destroySemaphore(logical_device.v, self.complete_semaphore, null);
    vkd.destroyFence(logical_device.v, self.complete_fence, null);

    vkd.destroyDescriptorSetLayout(logical_device.v, self.target_descriptor_layout, null);
    vkd.destroyDescriptorPool(logical_device.v, self.target_descriptor_pool, null);

    vkd.destroyPipelineLayout(logical_device.v, self.pipeline_layout, null);
    vkd.destroyPipeline(logical_device.v, self.pipeline, null);
}

pub fn dispatch(
    self: *ComputePipeline,
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.Device,
    compute_queue: context.components.ComputeQueue,
    queue_indices: context.components.QueueFamilyIndices,
    workgroup_size: WorkgroupSize,
    device_camera: DeviceCamera,
    device_sun: DeviceSun,
) !vk.Semaphore {
    {
        const wait_compute_zone = tracy.ZoneN(@src(), "idle wait compute");
        defer wait_compute_zone.End();

        // wait for previous compute dispatch to complete
        _ = try vkd.waitForFences(
            logical_device.v,
            1,
            @ptrCast(&self.complete_fence),
            vk.TRUE,
            std.math.maxInt(u64),
        );
        try vkd.resetFences(
            logical_device.v,
            1,
            @ptrCast(&self.complete_fence),
        );
    }

    try vkd.resetCommandPool(logical_device.v, self.command_pool, .{});
    try self.recordCommandBuffer(vkd, queue_indices, workgroup_size, device_camera, device_sun);

    {
        @setRuntimeSafety(false);
        const semo_null_ptr: [*c]const vk.Semaphore = null;
        const wait_null_ptr: [*c]const vk.PipelineStageFlags = null;
        // perform the compute ray tracing, draw to target texture
        const compute_submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = semo_null_ptr,
            .p_wait_dst_stage_mask = wait_null_ptr,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&self.command_buffer),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&self.complete_semaphore),
        };
        try vkd.queueSubmit(
            compute_queue.queue,
            1,
            @ptrCast(&compute_submit_info),
            self.complete_fence,
        );
    }

    return self.complete_semaphore;
}

pub fn recordCommandBuffer(
    self: ComputePipeline,
    vkd: context.components.vk_dispatch.Device,
    queue_indices: context.components.QueueFamilyIndices,
    workgroup_size: WorkgroupSize,
    device_camera: DeviceCamera,
    device_sun: DeviceSun,
) !void {
    const draw_zone = tracy.ZoneN(@src(), "compute record");
    defer draw_zone.End();

    const command_begin_info = vk.CommandBufferBeginInfo{
        .flags = .{
            .one_time_submit_bit = true,
        },
        .p_inheritance_info = null,
    };
    try vkd.beginCommandBuffer(self.command_buffer, &command_begin_info);

    if (render.consts.enable_debug_markers) {
        const debug_label = vk.DebugUtilsLabelEXT{
            .p_label_name = "Voxel Raytracing Cmds",
            .color = [4]f32{ 0.5, 0.0, 0.3, 1.0 },
        };
        vkd.cmdBeginDebugUtilsLabelEXT(self.command_buffer, &debug_label);
    }

    vkd.cmdBindPipeline(self.command_buffer, vk.PipelineBindPoint.compute, self.pipeline);

    // push camera data as a push constant
    vkd.cmdPushConstants(
        self.command_buffer,
        self.pipeline_layout,
        .{ .compute_bit = true },
        0,
        @sizeOf(DeviceCamera),
        &device_camera,
    );

    // push sun data as a push constant
    vkd.cmdPushConstants(
        self.command_buffer,
        self.pipeline_layout,
        .{ .compute_bit = true },
        @sizeOf(DeviceCamera),
        @sizeOf(DeviceSun),
        &device_sun,
    );

    const acquire_image_barrier = vk.ImageMemoryBarrier{
        .src_access_mask = .{},
        .dst_access_mask = .{ .shader_write_bit = true },
        .old_layout = .shader_read_only_optimal,
        .new_layout = .general,
        .src_queue_family_index = queue_indices.graphics,
        .dst_queue_family_index = queue_indices.compute,
        .image = self.target_image_info.image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    vkd.cmdPipelineBarrier(
        self.command_buffer,
        .{},
        .{ .compute_shader_bit = true },
        .{},
        0,
        undefined,
        0,
        undefined,
        1,
        @ptrCast(&acquire_image_barrier),
    );

    // bind target texture
    vkd.cmdBindDescriptorSets(
        self.command_buffer,
        .compute,
        self.pipeline_layout,
        0,
        1,
        @ptrCast(&self.target_descriptor_set),
        0,
        undefined,
    );
    const x_dispatch = @ceil(self.target_image_info.width / @as(f32, @floatFromInt(workgroup_size.x)));
    const y_dispatch = @ceil(self.target_image_info.height / @as(f32, @floatFromInt(workgroup_size.y)));

    vkd.cmdDispatch(self.command_buffer, @intFromFloat(x_dispatch), @intFromFloat(y_dispatch), 1);

    const release_image_barrier = vk.ImageMemoryBarrier{
        .src_access_mask = .{ .shader_write_bit = true },
        .dst_access_mask = .{},
        .old_layout = .general,
        .new_layout = .shader_read_only_optimal,
        .src_queue_family_index = queue_indices.compute,
        .dst_queue_family_index = queue_indices.graphics,
        .image = self.target_image_info.image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    vkd.cmdPipelineBarrier(
        self.command_buffer,
        .{ .compute_shader_bit = true },
        .{},
        .{},
        0,
        undefined,
        0,
        undefined,
        1,
        @ptrCast(&release_image_barrier),
    );

    if (render.consts.enable_debug_markers) {
        vkd.cmdEndDebugUtilsLabelEXT(self.command_buffer);
    }

    try vkd.endCommandBuffer(self.command_buffer);
}

pub fn calculateDefaultWorkgroupSize(physical_device_properties: context.components.PhysicalDeviceProperties) WorkgroupSize {
    const dim_size = physical_device_properties.limits.max_compute_work_group_invocations;
    const sqrt_dim_size = @sqrt(@as(f64, @floatFromInt(dim_size)));
    const uniform_dim: u32 = @intFromFloat(@floor(sqrt_dim_size));
    return WorkgroupSize{
        .x = uniform_dim,
        .y = uniform_dim,
    };
}
