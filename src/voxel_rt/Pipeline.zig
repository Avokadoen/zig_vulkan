const std = @import("std");
const Allocator = std.mem.Allocator;

const ecez = @import("ecez");
const tracy = @import("ztracy");
const vk = @import("vulkan");

const render = @import("../render.zig");
const context = render.context;
const texture = render.texture;
const vk_utils = render.vk_utils;
const memory = render.memory;
const gpu_buffer_memory = render.gpu_buffer_memory;
const grid_state = @import("brick/state.zig");
const camera = @import("camera.zig");
const ComputePipeline = @import("ComputePipeline.zig");
const gpu_types = @import("gpu_types.zig");
const GraphicsPipeline = @import("GraphicsPipeline.zig");
const ImguiGui = @import("ImguiGui.zig");
const ImguiPipeline = @import("ImguiPipeline.zig");
const sun = @import("sun.zig");

// TODO: move pipelines to ./internal/render/

pub const Config = struct {
    material_buffer: u64 = 256,

    gfx_pipeline_config: GraphicsPipeline.Config = .{},
};

/// VoxelRT render pipeline
const Pipeline = @This();

allocator: Allocator,

image_memory: vk.DeviceMemory,

compute_image_view: vk.ImageView,
compute_image: vk.Image,
sampler: vk.Sampler,

render_pass: vk.RenderPass,

present_complete_semaphore_index: usize,
present_complete_semaphores: []vk.Semaphore,
render_complete_semaphores: []vk.Semaphore,
render_complete_fence: vk.Fence,

compute_workgroup_size: ComputePipeline.WorkgroupSize,
compute_pipeline: ComputePipeline,
gfx_pipeline: GraphicsPipeline,
imgui_pipeline: ImguiPipeline,

swapchain_entity: ecez.Entity,
camera_entity: ecez.Entity,
sun_entity: ecez.Entity,

gui: ImguiGui,

requested_rescale_pipeline: bool = false,

// shared vertex index buffer for imgui and graphics pipeline
vertex_index_buffer_entity: ecez.Entity,

pub fn init(
    ctx_entity: ecez.Entity,
    allocator: Allocator,
    comptime Storage: type,
    storage: *Storage,
    internal_render_resolution: vk.Extent2D,
    grid_entity: ecez.Entity,
    camera_entity: ecez.Entity,
    sun_entity: ecez.Entity,
    config: Config,
) !Pipeline {
    const init_zone = tracy.ZoneN(@src(), "init pipeline");
    defer init_zone.End();

    const ctx = storage.getComponents(ctx_entity, struct {
        vki: context.components.vk_dispatch.Instance,
        physical_device: context.components.PhysicalDevice,
        physical_device_properties: context.components.PhysicalDeviceProperties,
        host_image_properties: context.components.PhysicalDeviceHostImageCopyProperties,
        vkd: context.components.vk_dispatch.Device,
        logical_device: context.components.Device,
        queue_indices: context.components.QueueFamilyIndices,
        graphics_queue: context.components.GraphicsQueue,
        auxillary_cmd_pool: context.components.AuxillaryCommandPool,
    }).?;

    // use graphics and compute index
    // if they are the same, then we use that index
    const indices = [_]u32{ ctx.queue_indices.graphics, ctx.queue_indices.compute };
    const indices_len: usize = if (ctx.queue_indices.graphics == ctx.queue_indices.compute) 1 else 2;

    const compute_image = blk: {
        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = vk.Extent3D{
                .width = internal_render_resolution.width,
                .height = internal_render_resolution.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{
                .@"1_bit" = true,
            },
            .tiling = .optimal,
            .usage = .{ .sampled_bit = true, .storage_bit = true },
            .sharing_mode = .concurrent,
            .queue_family_index_count = @intCast(indices_len),
            .p_queue_family_indices = &indices,
            .initial_layout = .undefined,
        };
        break :blk try ctx.vkd.createImage(ctx.logical_device.v, &image_info, null);
    };
    errdefer ctx.vkd.destroyImage(ctx.logical_device.v, compute_image, null);

    const memory_requirements = ctx.vkd.getImageMemoryRequirements(ctx.logical_device.v, compute_image);
    const image_memory_type_index = try vk_utils.findMemoryTypeIndex(
        ctx.vki,
        ctx.physical_device,
        memory_requirements.memory_type_bits,
        .{
            .device_local_bit = true,
        },
    );
    const image_memory_capacity = 64 * render.memory.bytes_in_mb;
    const image_alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = image_memory_capacity,
        .memory_type_index = image_memory_type_index,
    };
    const image_memory = try ctx.vkd.allocateMemory(ctx.logical_device.v, &image_alloc_info, null);
    errdefer ctx.vkd.freeMemory(ctx.logical_device.v, image_memory, null);

    try ctx.vkd.bindImageMemory(ctx.logical_device.v, compute_image, image_memory, 0);

    // transition from undefined -> general -> shader_read_only_optimal -> general
    // with queue ownership transfer is needed to silence validation
    const transitions = [_]texture.TransitionConfig{ .{
        .image = compute_image,
        .old_layout = .undefined,
        .new_layout = .general,
        .src_queue_family_index = ctx.queue_indices.graphics,
        .dst_queue_family_index = ctx.queue_indices.graphics,
    }, .{
        .image = compute_image,
        .old_layout = .general,
        .new_layout = .shader_read_only_optimal,
        .src_queue_family_index = ctx.queue_indices.graphics,
        .dst_queue_family_index = ctx.queue_indices.graphics,
    }, .{
        .image = compute_image,
        .old_layout = .shader_read_only_optimal,
        .new_layout = .general,
        .src_queue_family_index = ctx.queue_indices.graphics,
        .dst_queue_family_index = ctx.queue_indices.compute,
    } };
    try texture.transitionImageLayouts(
        ctx.vkd,
        ctx.logical_device,
        ctx.graphics_queue,
        ctx.auxillary_cmd_pool.pool,
        &transitions,
    );

    const compute_image_view = blk: {
        const image_view_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = compute_image,
            .view_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{
                    .color_bit = true,
                },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        break :blk try ctx.vkd.createImageView(ctx.logical_device.v, &image_view_info, null);
    };

    const sampler = blk: {
        const sampler_info = vk.SamplerCreateInfo{
            .flags = .{},
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .mip_lod_bias = 0.0,
            .anisotropy_enable = vk.FALSE,
            .max_anisotropy = 1.0,
            .compare_enable = vk.FALSE,
            .compare_op = .always,
            .min_lod = 0.0,
            .max_lod = 0.0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = vk.FALSE,
        };
        break :blk try ctx.vkd.createSampler(ctx.logical_device.v, &sampler_info, null);
    };
    errdefer ctx.vkd.destroySampler(ctx.logical_device.v, sampler, null);

    const swapchain_component = try render.swapchain.createSwapchainComponent(
        allocator,
        ctx_entity,
        Storage,
        storage,
        null,
    );
    const swapchain_entity = try storage.createEntity(.{swapchain_component});

    const render_pass = try context.createRenderPass(ctx.vkd, ctx.logical_device, swapchain_component.format);
    errdefer ctx.vkd.destroyRenderPass(ctx.logical_device.v, render_pass, null);

    const present_complete_semaphores = try allocator.alloc(vk.Semaphore, swapchain_component.image_len);
    errdefer allocator.free(present_complete_semaphores);
    var created_present_complete_semaphores: u32 = 0;
    errdefer {
        for (present_complete_semaphores[0..created_present_complete_semaphores]) |*semaphore| {
            ctx.vkd.destroySemaphore(ctx.logical_device.v, semaphore.*, null);
        }
    }
    const semaphore_info = vk.SemaphoreCreateInfo{ .flags = .{} };
    for (present_complete_semaphores) |*semaphore| {
        semaphore.* = try ctx.vkd.createSemaphore(ctx.logical_device.v, &semaphore_info, null);
        created_present_complete_semaphores += 1;
    }

    const render_complete_semaphores = try allocator.alloc(vk.Semaphore, swapchain_component.image_len);
    errdefer allocator.free(render_complete_semaphores);

    var created_render_complete_semaphores: u32 = 0;
    errdefer {
        for (render_complete_semaphores[0..created_render_complete_semaphores]) |*semaphore| {
            ctx.vkd.destroySemaphore(ctx.logical_device.v, semaphore.*, null);
        }
    }
    for (render_complete_semaphores) |*semaphore| {
        semaphore.* = try ctx.vkd.createSemaphore(ctx.logical_device.v, &semaphore_info, null);
        created_render_complete_semaphores += 1;
    }

    const fence_info = vk.FenceCreateInfo{
        .flags = .{
            .signaled_bit = true,
        },
    };
    const render_complete_fence = try ctx.vkd.createFence(ctx.logical_device.v, &fence_info, null);
    errdefer ctx.vkd.destroyFence(ctx.logical_device.v, render_complete_fence, null);

    const MinSize = struct {
        fn ssbo(physical_device_properties: context.components.PhysicalDeviceProperties, size: u64) u64 {
            const storage_size = physical_device_properties.limits.min_storage_buffer_offset_alignment;
            return storage_size * (std.math.divCeil(vk.DeviceSize, size, storage_size) catch unreachable);
        }

        fn uniform(physical_device_properties: context.components.PhysicalDeviceProperties, size: u64) u64 {
            const uniform_size = physical_device_properties.limits.min_uniform_buffer_offset_alignment;
            return uniform_size * (std.math.divCeil(vk.DeviceSize, size, uniform_size) catch unreachable);
        }
    };

    const compute_workgroup_size = ComputePipeline.calculateDefaultWorkgroupSize(ctx.physical_device_properties);
    var compute_pipeline = blk: {
        const uniform_sizes = [_]u64{
            MinSize.uniform(ctx.physical_device_properties, @sizeOf(grid_state.components.Device)),
        };
        const storage_sizes = [_]u64{
            MinSize.ssbo(ctx.physical_device_properties, @sizeOf(gpu_types.Material) * config.material_buffer),
            MinSize.ssbo(ctx.physical_device_properties, @sizeOf(grid_state.BrickStatusMask) * grid_state.components.Statuses.brick_status_count),
            MinSize.ssbo(ctx.physical_device_properties, @sizeOf(grid_state.IndexToBrick) * grid_state.brick_count),
            MinSize.ssbo(ctx.physical_device_properties, @sizeOf(grid_state.Brick.Occupancy) * grid_state.components.Occupancy.occupancy_count),
            MinSize.ssbo(ctx.physical_device_properties, @sizeOf(grid_state.Brick.StartIndex) * grid_state.brick_count),
            MinSize.ssbo(ctx.physical_device_properties, @sizeOf(grid_state.components.MaterialIndices.IndexType) * grid_state.components.MaterialIndices.material_index_count),
        };
        const state_configs: ComputePipeline.StateConfigs = .init(
            uniform_sizes[0..],
            storage_sizes[0..],
        );

        const target_image_info = ComputePipeline.ImageInfo{
            .width = @floatFromInt(internal_render_resolution.width),
            .height = @floatFromInt(internal_render_resolution.height),
            .image = compute_image,
            .sampler = sampler,
            .image_view = compute_image_view,
        };
        const ComputeSpecialization = extern struct {
            workgroup_size_x: c_uint,
            workgroup_size_y: c_uint,
            brick_bits: c_uint,
            brick_bytes: c_uint,
            brick_dimensions: c_int,
            brick_voxel_scale: f32,
        };

        break :blk try ComputePipeline.init(
            ctx.vki,
            ctx.physical_device,
            ctx.vkd,
            ctx.logical_device,
            ctx.queue_indices,
            Storage,
            storage,
            target_image_info,
            state_configs,
            ComputeSpecialization{
                .workgroup_size_x = @intCast(compute_workgroup_size.x),
                .workgroup_size_y = @intCast(compute_workgroup_size.y),
                .brick_bits = @intCast(grid_state.brick_bits),
                .brick_bytes = @intCast(grid_state.brick_bytes),
                .brick_dimensions = @intCast(grid_state.brick_dimension),
                .brick_voxel_scale = 1.0 / @as(f32, @floatFromInt(grid_state.brick_dimension)),
            },
        );
    };
    errdefer compute_pipeline.deinit(ctx.vkd, ctx.logical_device);

    var vertex_index_buffer = try gpu_buffer_memory.createGpuBufferMemoryComponents(
        ctx.vki,
        ctx.physical_device,
        ctx.vkd,
        ctx.logical_device,
        memory.bytes_in_mb * 63,
        .{ .vertex_buffer_bit = true, .index_buffer_bit = true },
        .{ .device_local_bit = true, .host_visible_bit = true },
    );
    errdefer gpu_buffer_memory.destroyBuffer(ctx.vkd, ctx.logical_device, vertex_index_buffer);
    const vertex_index_buffer_entity = try storage.createEntity(.{vertex_index_buffer});

    const gfx_pipeline = try GraphicsPipeline.init(
        allocator,
        ctx.vkd,
        ctx.logical_device,
        ctx.physical_device_properties,
        ctx.queue_indices,
        swapchain_component,
        render_pass,
        sampler,
        compute_image_view,
        &vertex_index_buffer,
        config.gfx_pipeline_config,
    );
    errdefer gfx_pipeline.deinit(
        allocator,
        ctx.vkd,
        ctx.logical_device,
    );

    const imgui_pipeline = try ImguiPipeline.init(
        allocator,
        ctx.vki,
        ctx.physical_device,
        ctx.host_image_properties,
        ctx.vkd,
        ctx.logical_device,
        ctx.graphics_queue,
        ctx.auxillary_cmd_pool.pool,
        render_pass,
        swapchain_component.image_len,
        gfx_pipeline.bytes_used_in_buffer,
    );
    errdefer imgui_pipeline.deinit(ctx.vkd, ctx.logical_device);

    const grid_device = storage.getComponent(grid_entity, grid_state.components.Device).?;
    const state_binding = ImguiGui.StateBinding{
        .grid_device = grid_device,
        .gfx_pipeline_shader_constants = gfx_pipeline.shader_constants,
    };
    const gui = try ImguiGui.init(
        @floatFromInt(swapchain_component.extent.width),
        @floatFromInt(swapchain_component.extent.height),
        storage,
        state_binding,
        .{},
    );

    return Pipeline{
        .allocator = allocator,
        .image_memory = image_memory,
        .compute_image_view = compute_image_view,
        .compute_image = compute_image,
        .sampler = sampler,
        .render_pass = render_pass,
        .present_complete_semaphore_index = 0,
        .present_complete_semaphores = present_complete_semaphores,
        .render_complete_semaphores = render_complete_semaphores,
        .render_complete_fence = render_complete_fence,
        .compute_workgroup_size = compute_workgroup_size,
        .compute_pipeline = compute_pipeline,
        .gfx_pipeline = gfx_pipeline,
        .imgui_pipeline = imgui_pipeline,
        .swapchain_entity = swapchain_entity,
        .camera_entity = camera_entity,
        .sun_entity = sun_entity,
        .gui = gui,
        .vertex_index_buffer_entity = vertex_index_buffer_entity,
    };
}

pub fn deinit(self: Pipeline, comptime Storage: type, storage: *Storage, ctx_entity: ecez.Entity) void {
    const ctx = storage.getComponents(ctx_entity, struct {
        vkd: context.components.vk_dispatch.Device,
        logical_device: context.components.Device,
        compute_queue: context.components.ComputeQueue,
        graphics_queue: context.components.GraphicsQueue,
    }).?;

    ctx.vkd.queueWaitIdle(ctx.compute_queue.queue) catch {};
    ctx.vkd.queueWaitIdle(ctx.graphics_queue.queue) catch {};

    for (self.render_complete_semaphores) |semaphore| {
        ctx.vkd.destroySemaphore(ctx.logical_device.v, semaphore, null);
    }
    self.allocator.free(self.render_complete_semaphores);

    for (self.present_complete_semaphores) |semaphore| {
        ctx.vkd.destroySemaphore(ctx.logical_device.v, semaphore, null);
    }
    self.allocator.free(self.present_complete_semaphores);

    ctx.vkd.destroyFence(ctx.logical_device.v, self.render_complete_fence, null);

    self.imgui_pipeline.deinit(ctx.vkd, ctx.logical_device);
    self.gfx_pipeline.deinit(self.allocator, ctx.vkd, ctx.logical_device);
    self.compute_pipeline.deinit(ctx.vkd, ctx.logical_device);
    ctx.vkd.destroyRenderPass(ctx.logical_device.v, self.render_pass, null);

    ctx.vkd.destroySampler(ctx.logical_device.v, self.sampler, null);
    ctx.vkd.destroyImageView(ctx.logical_device.v, self.compute_image_view, null);
    ctx.vkd.destroyImage(ctx.logical_device.v, self.compute_image, null);
    ctx.vkd.freeMemory(ctx.logical_device.v, self.image_memory, null);
}

/// draw a new frame, delta time is only used by gui
pub fn draw(self: *Pipeline, comptime Storage: type, storage: *Storage, ctx_entity: ecez.Entity, dt: f32) !void {
    const draw_zone = tracy.ZoneN(@src(), "draw");
    defer draw_zone.End();

    defer {
        self.present_complete_semaphore_index += 1;
        self.present_complete_semaphore_index = @mod(self.present_complete_semaphore_index, self.present_complete_semaphores.len);
    }

    const ctx = storage.getComponents(ctx_entity, struct {
        vkd: context.components.vk_dispatch.Device,
        logical_device: context.components.Device,
        queue_indices: context.components.QueueFamilyIndices,
        compute_queue: context.components.ComputeQueue,
        graphics_queue: context.components.GraphicsQueue,
        physical_device_properties: context.components.PhysicalDeviceProperties,
        window_ptr: context.components.WindowPtr,
    }).?;

    const device_camera = storage.getComponent(self.camera_entity, *camera.components.DeviceCamera).?;
    const device_sun = storage.getComponent(self.sun_entity, *sun.components.DeviceSun).?;
    const compute_semaphore = try self.compute_pipeline.dispatch(
        ctx.vkd,
        ctx.logical_device,
        ctx.compute_queue,
        ctx.queue_indices,
        self.compute_workgroup_size,
        device_camera.*,
        device_sun.*,
    );

    const swapchain_data = storage.getComponent(self.swapchain_entity, render.swapchain.components.SwapchainData).?;
    const image_index = blk: {
        const aquired = ctx.vkd.acquireNextImageKHR(
            ctx.logical_device.v,
            swapchain_data.swapchain,
            std.math.maxInt(u64),
            self.present_complete_semaphores[self.present_complete_semaphore_index],
            .null_handle,
        );

        if (aquired) |ok| switch (ok.result) {
            .success => break :blk ok.image_index,
            .suboptimal_khr => {
                self.requested_rescale_pipeline = true;
                break :blk ok.image_index;
            },
            else => {
                // TODO: handle timeout and not_ready
                return error.UnhandledAcquireResult;
            },
        } else |err| switch (err) {
            error.OutOfDateKHR => {
                self.requested_rescale_pipeline = true;
                return;
            },
            else => {
                return err;
            },
        }
    };

    {
        const wait_render_zone = tracy.ZoneN(@src(), "render wait complete");
        defer wait_render_zone.End();

        // wait for previous texture draw before updating buffers and command buffers
        _ = try ctx.vkd.waitForFences(ctx.logical_device.v, 1, @ptrCast(&self.render_complete_fence), vk.TRUE, std.math.maxInt(u64));
        try ctx.vkd.resetFences(ctx.logical_device.v, 1, @ptrCast(&self.render_complete_fence));
    }

    const update_metrics = image_index == 0;
    const camera_ptr = storage.getComponent(self.camera_entity, *camera.components.Camera).?;
    const sun_ptr = storage.getComponent(self.sun_entity, *sun.components.Sun).?;
    try self.gui.newFrame(
        ctx.physical_device_properties,
        storage,
        swapchain_data.extent,
        camera_ptr,
        device_camera,
        sun_ptr,
        device_sun,
        update_metrics,
        dt,
    );

    const vertex_index_buffer = storage.getComponent(
        self.vertex_index_buffer_entity,
        *gpu_buffer_memory.components.GpuBufferMemory,
    ).?;
    try self.imgui_pipeline.updateBuffers(
        ctx.vkd,
        ctx.logical_device,
        ctx.physical_device_properties,
        vertex_index_buffer,
    );

    // re-record command buffer to update any state
    try ctx.vkd.resetCommandPool(
        ctx.logical_device.v,
        self.gfx_pipeline.command_pools[image_index],
        .{},
    );
    try self.recordCommandBuffer(
        ctx.vkd,
        ctx.queue_indices,
        vertex_index_buffer.*,
        swapchain_data.extent,
        image_index,
    );

    const stage_masks = [_]vk.PipelineStageFlags{
        .{ .vertex_input_bit = true },
        .{ .color_attachment_output_bit = true },
    };
    const wait_semaphores = [stage_masks.len]vk.Semaphore{
        compute_semaphore,
        self.present_complete_semaphores[self.present_complete_semaphore_index],
    };
    const render_submit_info = vk.SubmitInfo{
        .wait_semaphore_count = wait_semaphores.len,
        .p_wait_semaphores = &wait_semaphores,
        .p_wait_dst_stage_mask = &stage_masks,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&self.gfx_pipeline.command_buffers[image_index]),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&self.render_complete_semaphores[image_index]),
    };

    try ctx.vkd.queueSubmit(
        ctx.graphics_queue.queue,
        1,
        @ptrCast(&render_submit_info),
        self.render_complete_fence,
    );

    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&self.render_complete_semaphores[image_index]),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&swapchain_data.swapchain),
        .p_image_indices = @ptrCast(&image_index),
        .p_results = null,
    };

    const queue_result = ctx.vkd.queuePresentKHR(ctx.graphics_queue.queue, &present_info);
    if (queue_result) |ok| switch (ok) {
        vk.Result.suboptimal_khr => self.requested_rescale_pipeline = true,
        else => {},
    } else |err| switch (err) {
        error.OutOfDateKHR => self.requested_rescale_pipeline = true,
        else => return err,
    }

    if (self.requested_rescale_pipeline) try self.rescalePipeline(
        Storage,
        storage,
        ctx_entity,
        ctx.vkd,
        ctx.logical_device,
        ctx.window_ptr,
    );
}

pub fn setDenoiseSampleCount(self: *Pipeline, sample_count: i32) void {
    self.gfx_pipeline.shader_constants.samples = sample_count;
}

pub fn setDenoiseDistributionBias(self: *Pipeline, distribution_bias: f32) void {
    self.gfx_pipeline.shader_constants.distribution_bias = distribution_bias;
}

pub fn setDenoiseInverseHueTolerance(self: *Pipeline, inverse_hue_tolerance: f32) void {
    self.gfx_pipeline.shader_constants.inverse_hue_tolerance = inverse_hue_tolerance;
}

pub fn setDenoisePixelMultiplier(self: *Pipeline, pixel_multiplier: f32) void {
    self.gfx_pipeline.shader_constants.pixel_multiplier = pixel_multiplier;
}

pub const TransferBuffers = enum {
    grid_device,
    material,
    brick_status,
    index_to_brick,
    occupancy,
    brick_start_index,
    material_index,

    pub fn ToType(comptime self: TransferBuffers) type {
        return switch (self) {
            .grid_device => grid_state.components.Device,
            .material => gpu_types.Material,
            .brick_status => grid_state.BrickStatusMask,
            .index_to_brick => grid_state.IndexToBrick,
            .occupancy => grid_state.components.Occupancy.OccupancyByte,
            .brick_start_index => grid_state.Brick.StartIndex,
            .material_index => grid_state.components.MaterialIndices.IndexType,
        };
    }
};
/// Transfer data to the device
pub fn transfer(
    self: *const Pipeline,
    comptime Storage: type,
    storage: *Storage,
    offset: usize,
    comptime buffer_type: TransferBuffers,
    data: []const buffer_type.ToType(),
) !void {
    const type_offset = switch (buffer_type) {
        .grid_device => self.compute_pipeline.uniform_offsets[0],
        .material => self.compute_pipeline.storage_offsets[0],
        .brick_status => self.compute_pipeline.storage_offsets[1],
        .index_to_brick => self.compute_pipeline.storage_offsets[2],
        .occupancy => self.compute_pipeline.storage_offsets[3],
        .brick_start_index => self.compute_pipeline.storage_offsets[4],
        .material_index => self.compute_pipeline.storage_offsets[5],
    };
    const DataType = buffer_type.ToType();
    const buffer_offset = type_offset + offset * @sizeOf(DataType);

    const buffer = storage.getComponent(
        self.compute_pipeline.buffer_entity,
        gpu_buffer_memory.components.GpuBufferMemory,
    ).?;

    const mapped_device_data = buffer.typedMapAssumeMapped(DataType, buffer_offset);
    @memcpy(mapped_device_data[0..data.len], data);
}

// TODO: make allow to multithread this
/// Used to update the pipeline according to changes in the window spec
/// This functions should only be called from the main thread (see glfwGetFramebufferSize)
fn rescalePipeline(
    self: *Pipeline,
    comptime Storage: type,
    storage: *Storage,
    ctx_entity: ecez.Entity,
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.Device,
    window_ptr: context.components.WindowPtr,
) !void {
    const rescale_zone = tracy.ZoneN(@src(), "rescale pipeline");
    defer rescale_zone.End();

    var window_size = window_ptr.ptr.*.getFramebufferSize();
    if (window_size[0] == 0 or window_size[1] == 0) {
        window_size = window_ptr.ptr.*.getFramebufferSize();
        @import("zglfw").waitEvents();
    }

    self.requested_rescale_pipeline = false;

    // Wait for pipeline to become idle
    {
        _ = vkd.waitForFences(
            logical_device.v,
            1,
            @ptrCast(&self.compute_pipeline.complete_fence),
            vk.TRUE,
            std.math.maxInt(u64),
        ) catch |err| std.debug.print("failed to wait for compute fences, err: {any}", .{err});
        // wait for previous texture draw before updating buffers and command buffers
        _ = try vkd.waitForFences(logical_device.v, 1, @ptrCast(&self.render_complete_fence), vk.TRUE, std.math.maxInt(u64));
    }

    const swapchain_ptr = storage.getComponent(
        self.swapchain_entity,
        *render.swapchain.components.SwapchainData,
    ).?;
    // recreate swapchain utilizing the old one
    const old_swapchain = swapchain_ptr.*;
    defer render.swapchain.destroySwapchainData(vkd, logical_device, old_swapchain);
    swapchain_ptr.* = try render.swapchain.createSwapchainComponent(
        self.allocator,
        ctx_entity,
        Storage,
        storage,
        old_swapchain.swapchain,
    );

    // recreate renderpass
    vkd.destroyRenderPass(logical_device.v, self.render_pass, null);
    self.render_pass = try context.createRenderPass(vkd, logical_device, swapchain_ptr.format);
    errdefer vkd.destroyRenderPass(logical_device.v, self.render_pass, null);

    // recreate framebuffers
    for (self.gfx_pipeline.framebuffers) |framebuffer| {
        vkd.destroyFramebuffer(logical_device.v, framebuffer, null);
    }
    self.gfx_pipeline.framebuffers = try render.pipeline.createFramebuffers(
        self.allocator,
        vkd,
        logical_device,
        swapchain_ptr,
        self.render_pass,
        self.gfx_pipeline.framebuffers,
    );
    errdefer {
        for (self.gfx_pipeline.framebuffers) |buffer| {
            vkd.destroyFramebuffer(logical_device.v, buffer, null);
        }
        self.allocator.free(self.gfx_pipeline.framebuffers);
    }

    self.gui.handleRescale(
        @floatFromInt(window_size[0]),
        @floatFromInt(window_size[1]),
    );
}

// TODO: properly handling of errors
fn recordCommandBuffer(
    self: Pipeline,
    vkd: context.components.vk_dispatch.Device,
    queue_indices: context.components.QueueFamilyIndices,
    vertex_index_buffer: gpu_buffer_memory.components.GpuBufferMemory,
    swapchain_extent: vk.Extent2D,
    index: usize,
) !void {
    const record_zone = tracy.ZoneN(@src(), "record gfx & imgui commands");
    defer record_zone.End();

    const command_buffer = self.gfx_pipeline.command_buffers[index];
    try vkd.beginCommandBuffer(command_buffer, &command_buffer_info);

    if (render.consts.enable_debug_markers) {
        const debug_label = vk.DebugUtilsLabelEXT{
            .p_label_name = "GFX Pipeline",
            .color = [4]f32{ 0.1, 0.1, 0.8, 1.0 },
        };
        vkd.cmdBeginDebugUtilsLabelEXT(command_buffer, &debug_label);
    }

    const acquire_image_barrier = vk.ImageMemoryBarrier{
        .src_access_mask = .{},
        .dst_access_mask = .{ .shader_read_bit = true },
        .old_layout = .general,
        .new_layout = .shader_read_only_optimal,
        .src_queue_family_index = queue_indices.compute,
        .dst_queue_family_index = queue_indices.graphics,
        .image = self.compute_image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    vkd.cmdPipelineBarrier(
        command_buffer,
        .{},
        .{ .fragment_shader_bit = true },
        .{},
        0,
        undefined,
        0,
        undefined,
        1,
        @ptrCast(&acquire_image_barrier),
    );

    const render_pass_begin_info = vk.RenderPassBeginInfo{
        .render_pass = self.render_pass,
        .framebuffer = self.gfx_pipeline.framebuffers[index],
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = swapchain_extent,
        },
        .clear_value_count = 0,
        .p_clear_values = undefined,
    };
    vkd.cmdBeginRenderPass(command_buffer, &render_pass_begin_info, .@"inline");

    {
        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(swapchain_extent.width),
            .height = @floatFromInt(swapchain_extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        vkd.cmdSetViewport(
            command_buffer,
            0,
            1,
            @ptrCast(&viewport),
        );
    }

    {
        const scissor = vk.Rect2D{
            .offset = .{
                .x = 0,
                .y = 0,
            },
            .extent = swapchain_extent,
        };
        vkd.cmdSetScissor(command_buffer, 0, 1, @ptrCast(&scissor));
    }

    vkd.cmdPushConstants(
        command_buffer,
        self.gfx_pipeline.pipeline_layout,
        .{ .fragment_bit = true },
        0,
        @sizeOf(GraphicsPipeline.PushConstant),
        self.gfx_pipeline.shader_constants,
    );

    vkd.cmdBindDescriptorSets(
        command_buffer,
        .graphics,
        self.gfx_pipeline.pipeline_layout,
        0,
        1,
        @ptrCast(&self.gfx_pipeline.descriptor_set),
        0,
        undefined,
    );
    vkd.cmdBindPipeline(command_buffer, .graphics, self.gfx_pipeline.pipeline);
    vkd.cmdBindVertexBuffers(
        command_buffer,
        0,
        1,
        @ptrCast(&vertex_index_buffer.buffer),
        &vertex_zero_offset,
    );
    vkd.cmdBindIndexBuffer(command_buffer, vertex_index_buffer.buffer, GraphicsPipeline.vertex_size, .uint16);
    vkd.cmdDrawIndexed(command_buffer, GraphicsPipeline.indices.len, 1, 0, 0, 0);

    try self.imgui_pipeline.recordCommandBuffer(
        vkd,
        command_buffer,
        self.gfx_pipeline.bytes_used_in_buffer,
        vertex_index_buffer,
    );

    vkd.cmdEndRenderPass(command_buffer);

    const release_image_barrier = vk.ImageMemoryBarrier{
        .src_access_mask = .{ .shader_read_bit = true },
        .dst_access_mask = .{},
        .old_layout = .shader_read_only_optimal,
        .new_layout = .general,
        .src_queue_family_index = queue_indices.graphics,
        .dst_queue_family_index = queue_indices.compute,
        .image = self.compute_image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .fragment_shader_bit = true },
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
        vkd.cmdEndDebugUtilsLabelEXT(command_buffer);
    }

    try vkd.endCommandBuffer(command_buffer);
}

const command_buffer_info = vk.CommandBufferBeginInfo{
    .flags = .{
        .one_time_submit_bit = true,
    },
    .p_inheritance_info = null,
};
const vertex_zero_offset = [_]vk.DeviceSize{0};
