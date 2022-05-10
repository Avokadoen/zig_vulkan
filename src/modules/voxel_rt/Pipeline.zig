const std = @import("std");
const Allocator = std.mem.Allocator;

const glfw = @import("glfw");

const tracy = @import("../../tracy.zig");

const vk = @import("vulkan");
const render = @import("../render.zig");
const Context = render.Context;
const Texture = render.Texture;
const vk_utils = render.vk_utils;

// TODO: move pipelines to ./internal/render/
const ComputePipeline = @import("ComputePipeline.zig");
const GraphicsPipeline = @import("GraphicsPipeline.zig");
const ImguiPipeline = @import("ImguiPipeline.zig");
const StagingBuffers = render.StagingBuffers;
const GpuBufferMemory = render.GpuBufferMemory;

const ImguiGui = @import("ImguiGui.zig");

const Camera = @import("Camera.zig");
const Sun = @import("Sun.zig");
const GridState = @import("brick/State.zig");
const gpu_types = @import("gpu_types.zig");

pub const Config = struct {
    material_buffer: u64 = 256,
    albedo_buffer: u64 = 256,
    metal_buffer: u64 = 256,
    dielectric_buffer: u64 = 256,

    staging_buffers: usize = 3,
    in_flight_compute: usize = 1,
    gfx_pipeline_config: GraphicsPipeline.Config = .{},
};

const Pixel = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

/// VoxelRT render pipeline
const Pipeline = @This();

allocator: Allocator,

image_memory_type_index: u32,
image_memory_size: vk.DeviceSize,
image_memory_capacity: vk.DeviceSize,
image_memory: vk.DeviceMemory,

compute_image_view: vk.ImageView,
compute_image: vk.Image,
sampler: vk.Sampler,

// buffers used to transfer to device local memory
staging_buffers: StagingBuffers,

swapchain: render.swapchain.Data,
render_pass: vk.RenderPass,
render_pass_begin_info: vk.RenderPassBeginInfo,

present_complete_semaphore: vk.Semaphore,
render_complete_semaphore: vk.Semaphore,
render_complete_fence: vk.Fence,

compute_pipeline: ComputePipeline,
// TODO: rename pipeline
gfx_pipeline: GraphicsPipeline,
imgui_pipeline: ImguiPipeline,

camera: *Camera,
sun: *Sun,

gui: ImguiGui,

requested_rescale_pipeline: bool = false,
init_command_pool: vk.CommandPool, // kept in case of rescale

// shared vertex index buffer for imgui and graphics pipeline
vertex_index_buffer: GpuBufferMemory,

pub fn init(ctx: Context, allocator: Allocator, internal_render_resolution: vk.Extent2D, grid_state: GridState, camera: *Camera, sun: *Sun, config: Config) !Pipeline {
    const init_zone = tracy.ZoneN(@src(), "init pipeline");
    defer init_zone.End();

    const pool_info = vk.CommandPoolCreateInfo{
        .flags = .{},
        .queue_family_index = ctx.queue_indices.graphics,
    };
    const init_command_pool = try ctx.vkd.createCommandPool(ctx.logical_device, &pool_info, null);

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
            .sharing_mode = .exclusive,
            .queue_family_index_count = @intCast(u32, indices_len),
            .p_queue_family_indices = &indices,
            .initial_layout = .@"undefined",
        };
        break :blk try ctx.vkd.createImage(ctx.logical_device, &image_info, null);
    };
    errdefer ctx.vkd.destroyImage(ctx.logical_device, compute_image, null);

    // Allocate memory for all pipeline images
    const memory_requirements = ctx.vkd.getImageMemoryRequirements(ctx.logical_device, compute_image);
    const image_memory_type_index = try vk_utils.findMemoryTypeIndex(ctx, memory_requirements.memory_type_bits, .{
        .device_local_bit = true,
    });
    const image_memory_capacity = 250 * render.GpuBufferMemory.bytes_in_mb;
    const image_alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = image_memory_capacity,
        .memory_type_index = image_memory_type_index,
    };
    const image_memory = try ctx.vkd.allocateMemory(ctx.logical_device, &image_alloc_info, null);
    errdefer ctx.vkd.freeMemory(ctx.logical_device, image_memory, null);

    try ctx.vkd.bindImageMemory(ctx.logical_device, compute_image, image_memory, 0);
    var image_memory_size = memory_requirements.size;

    try Texture.transitionImageLayout(ctx, init_command_pool, compute_image, .@"undefined", .shader_read_only_optimal);

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
        break :blk try ctx.vkd.createImageView(ctx.logical_device, &image_view_info, null);
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
        break :blk try ctx.vkd.createSampler(ctx.logical_device, &sampler_info, null);
    };

    const swapchain = try render.swapchain.Data.init(allocator, ctx, init_command_pool, null);
    errdefer swapchain.deinit(ctx);

    const render_pass = try ctx.createRenderPass(swapchain.format);
    errdefer ctx.destroyRenderPass(render_pass);

    const semaphore_info = vk.SemaphoreCreateInfo{ .flags = .{} };
    const present_complete_semaphore = try ctx.vkd.createSemaphore(ctx.logical_device, &semaphore_info, null);
    errdefer ctx.vkd.destroySemaphore(ctx.logical_device, present_complete_semaphore, null);
    const render_complete_semaphore = try ctx.vkd.createSemaphore(ctx.logical_device, &semaphore_info, null);
    errdefer ctx.vkd.destroySemaphore(ctx.logical_device, render_complete_semaphore, null);

    const fence_info = vk.FenceCreateInfo{
        .flags = .{
            .signaled_bit = true,
        },
    };
    const render_complete_fence = try ctx.vkd.createFence(ctx.logical_device, &fence_info, null);

    var compute_pipeline = blk: {
        const uniform_sizes = [_]u64{
            @sizeOf(GridState.Device),
        };
        const storage_sizes = [_]u64{
            @sizeOf(gpu_types.Material) * config.material_buffer,
            @sizeOf(gpu_types.Albedo) * config.albedo_buffer,
            @sizeOf(gpu_types.Metal) * config.metal_buffer,
            @sizeOf(gpu_types.Dielectric) * config.dielectric_buffer,
            @sizeOf(u8) * grid_state.higher_order_grid.len,
            @sizeOf(GridState.GridEntry) * grid_state.grid.len,
            @sizeOf(GridState.Brick) * grid_state.bricks.len,
            @sizeOf(u8) * grid_state.material_indices.len,
        };
        const state_configs = ComputePipeline.StateConfigs{ .uniform_sizes = uniform_sizes[0..], .storage_sizes = storage_sizes[0..] };

        const target_image_info = ComputePipeline.ImageInfo{
            .width = @intToFloat(f32, internal_render_resolution.width),
            .height = @intToFloat(f32, internal_render_resolution.height),
            .image = compute_image,
            .sampler = sampler,
            .image_view = compute_image_view,
        };
        break :blk try ComputePipeline.init(allocator, ctx, config.in_flight_compute, "brick_raytracer.comp.spv", target_image_info, state_configs);
    };
    errdefer compute_pipeline.deinit(ctx);

    {
        var i: usize = 0;
        while (i < config.in_flight_compute) : (i += 1) {
            try compute_pipeline.recordCommandBuffer(ctx, i, camera.*, sun.*);
        }
    }

    var staging_buffers = try StagingBuffers.init(ctx, allocator, config.staging_buffers);
    errdefer staging_buffers.deinit(ctx, allocator);

    var vertex_index_buffer = try GpuBufferMemory.init(
        ctx,
        GpuBufferMemory.bytes_in_mb * 63,
        .{ .vertex_buffer_bit = true, .index_buffer_bit = true },
        .{ .host_visible_bit = true },
    );
    const gfx_pipeline = try GraphicsPipeline.init(
        allocator,
        ctx,
        swapchain,
        render_pass,
        sampler,
        compute_image_view,
        &vertex_index_buffer,
        config.gfx_pipeline_config,
    );
    errdefer gfx_pipeline.deinit(allocator, ctx);
    const imgui_pipeline = try ImguiPipeline.init(
        ctx,
        allocator,
        render_pass,
        swapchain.images.len,
        &staging_buffers,
        gfx_pipeline.bytes_used_in_buffer,
        image_memory_type_index,
        image_memory,
        image_memory_capacity,
        &image_memory_size,
    );
    errdefer imgui_pipeline.deinit(ctx);

    const render_pass_begin_info = vk.RenderPassBeginInfo{
        .render_pass = render_pass,
        .framebuffer = undefined,
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = swapchain.extent,
        },
        .clear_value_count = clear_values.len,
        .p_clear_values = &clear_values,
    };

    const state_binding = ImguiGui.StateBinding{
        .camera_ptr = camera,
        .sun_ptr = sun,
        .gfx_pipeline_shader_constants = gfx_pipeline.shader_constants,
    };
    const gui = ImguiGui.init(
        ctx,
        @intToFloat(f32, swapchain.extent.width),
        @intToFloat(f32, swapchain.extent.height),
        state_binding,
        .{},
    );

    return Pipeline{
        .allocator = allocator,
        .image_memory_type_index = image_memory_type_index,
        .image_memory_size = image_memory_size,
        .image_memory_capacity = image_memory_capacity,
        .image_memory = image_memory,
        .compute_image_view = compute_image_view,
        .compute_image = compute_image,
        .sampler = sampler,
        .staging_buffers = staging_buffers,
        .swapchain = swapchain,
        .render_pass = render_pass,
        .render_pass_begin_info = render_pass_begin_info,
        .present_complete_semaphore = present_complete_semaphore,
        .render_complete_semaphore = render_complete_semaphore,
        .render_complete_fence = render_complete_fence,
        .compute_pipeline = compute_pipeline,
        .gfx_pipeline = gfx_pipeline,
        .imgui_pipeline = imgui_pipeline,
        .camera = camera,
        .sun = sun,
        .gui = gui,
        .init_command_pool = init_command_pool,
        .vertex_index_buffer = vertex_index_buffer,
    };
}

pub fn deinit(self: Pipeline, ctx: Context) void {
    _ = ctx.vkd.waitForFences(
        ctx.logical_device,
        1,
        @ptrCast([*]const vk.Fence, &self.render_complete_fence),
        vk.TRUE,
        std.math.maxInt(u64),
    ) catch |err| std.debug.print("failed to wait for compute fence, err: {any}", .{err});

    ctx.vkd.destroySemaphore(ctx.logical_device, self.present_complete_semaphore, null);
    ctx.vkd.destroySemaphore(ctx.logical_device, self.render_complete_semaphore, null);
    ctx.vkd.destroyFence(ctx.logical_device, self.render_complete_fence, null);

    self.imgui_pipeline.deinit(ctx);
    self.gfx_pipeline.deinit(self.allocator, ctx);
    self.compute_pipeline.deinit(ctx);
    ctx.destroyRenderPass(self.render_pass);
    self.swapchain.deinit(ctx);
    self.staging_buffers.deinit(ctx, self.allocator);
    self.vertex_index_buffer.deinit(ctx);

    ctx.vkd.destroyCommandPool(ctx.logical_device, self.init_command_pool, null);

    ctx.vkd.destroySampler(ctx.logical_device, self.sampler, null);
    ctx.vkd.destroyImageView(ctx.logical_device, self.compute_image_view, null);
    ctx.vkd.destroyImage(ctx.logical_device, self.compute_image, null);
    ctx.vkd.freeMemory(ctx.logical_device, self.image_memory, null);
}

pub inline fn draw(self: *Pipeline, ctx: Context) !void {
    const draw_zone = tracy.ZoneN(@src(), "draw");
    defer draw_zone.End();

    const compute_semaphore = try self.compute_pipeline.dispatch(ctx, self.camera.*, self.sun.*);

    const image_index = blk: {
        const aquired = ctx.vkd.acquireNextImageKHR(
            ctx.logical_device,
            self.swapchain.swapchain,
            std.math.maxInt(u64),
            self.present_complete_semaphore,
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
        _ = try ctx.vkd.waitForFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.render_complete_fence), vk.TRUE, std.math.maxInt(u64));
        try ctx.vkd.resetFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.render_complete_fence));
    }

    self.gui.newFrame(ctx, self, image_index == 0);
    try self.imgui_pipeline.updateBuffers(ctx, &self.vertex_index_buffer);

    // re-record command buffer to update any state
    var begin_info = self.render_pass_begin_info;
    try ctx.vkd.resetCommandPool(ctx.logical_device, self.gfx_pipeline.command_pools[image_index], .{});
    try self.recordCommandBuffer(ctx, image_index, &begin_info);

    const stage_masks = [_]vk.PipelineStageFlags{ .{ .vertex_input_bit = true }, .{ .color_attachment_output_bit = true } };
    const wait_semaphores = [stage_masks.len]vk.Semaphore{ compute_semaphore, self.present_complete_semaphore };
    const render_submit_info = vk.SubmitInfo{
        .wait_semaphore_count = wait_semaphores.len,
        .p_wait_semaphores = &wait_semaphores,
        .p_wait_dst_stage_mask = &stage_masks,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.gfx_pipeline.command_buffers[image_index]),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast([*]const vk.Semaphore, &self.render_complete_semaphore),
    };

    try ctx.vkd.queueSubmit(
        ctx.graphics_queue,
        1,
        @ptrCast([*]const vk.SubmitInfo, &render_submit_info),
        self.render_complete_fence,
    );

    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &self.render_complete_semaphore),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast([*]const vk.SwapchainKHR, &self.swapchain.swapchain),
        .p_image_indices = @ptrCast([*]const u32, &image_index),
        .p_results = null,
    };

    const queue_result = ctx.vkd.queuePresentKHR(ctx.graphics_queue, &present_info);
    if (queue_result) |ok| switch (ok) {
        vk.Result.suboptimal_khr => self.requested_rescale_pipeline = true,
        else => {},
    } else |err| switch (err) {
        error.OutOfDateKHR => self.requested_rescale_pipeline = true,
        else => return err,
    }

    if (self.requested_rescale_pipeline) try self.rescalePipeline(ctx);
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

/// Transfer grid data to GPU
pub inline fn transferGridState(self: *Pipeline, ctx: Context, grid: GridState) !void {
    const grid_data = [_]GridState.Device{grid.device_state};
    const buffer_offset = self.compute_pipeline.uniform_offsets[0];
    try self.staging_buffers.transferToBuffer(
        ctx,
        &self.compute_pipeline.buffers,
        buffer_offset,
        GridState.Device,
        grid_data[0..],
    );
}

/// Transfer material data to GPU
pub inline fn transferMaterials(self: *Pipeline, ctx: Context, offset: usize, materials: []const gpu_types.Material) !void {
    const buffer_offset = self.compute_pipeline.storage_offsets[0];
    try self.staging_buffers.transferToBuffer(
        ctx,
        &self.compute_pipeline.buffers,
        buffer_offset + offset * @sizeOf(gpu_types.Material),
        gpu_types.Material,
        materials,
    );
}

/// Transfer albedo data to GPU
pub inline fn transferAlbedos(self: *Pipeline, ctx: Context, offset: usize, albedo: []const gpu_types.Albedo) !void {
    const buffer_offset = self.compute_pipeline.storage_offsets[1];
    try self.staging_buffers.transferToBuffer(
        ctx,
        &self.compute_pipeline.buffers,
        buffer_offset + offset * @sizeOf(gpu_types.Albedo),
        gpu_types.Albedo,
        albedo,
    );
}

/// Transfer metal data to GPU
pub inline fn transferMetals(self: *Pipeline, ctx: Context, offset: usize, metals: []const gpu_types.Metal) !void {
    const buffer_offset = self.compute_pipeline.storage_offsets[2];
    try self.staging_buffers.transferToBuffer(
        ctx,
        &self.compute_pipeline.buffers,
        buffer_offset + offset * @sizeOf(gpu_types.Metal),
        gpu_types.Metal,
        metals,
    );
}

/// Transfer dielectric data to GPU
pub inline fn transferDielectrics(self: *Pipeline, ctx: Context, offset: usize, dielectrics: []const gpu_types.Dielectric) !void {
    const buffer_offset = self.compute_pipeline.storage_offsets[3];
    try self.staging_buffers.transferToBuffer(
        ctx,
        &self.compute_pipeline.buffers,
        buffer_offset + offset * @sizeOf(gpu_types.Dielectric),
        gpu_types.Dielectric,
        dielectrics,
    );
}

/// Transfer higher order grid data to GPU
pub inline fn transferHigherOrderGrid(self: *Pipeline, ctx: Context, offset: usize, higher_order_grid: []const u8) !void {
    const buffer_offset = self.compute_pipeline.storage_offsets[4];
    try self.staging_buffers.transferToBuffer(
        ctx,
        &self.compute_pipeline.buffers,
        buffer_offset + offset * @sizeOf(u8),
        u8,
        higher_order_grid,
    );
}

/// Transfer dielectric data to GPU
pub inline fn transferGridEntries(self: *Pipeline, ctx: Context, offset: usize, grid_entries: []const GridState.GridEntry) !void {
    const buffer_offset = self.compute_pipeline.storage_offsets[5];
    try self.staging_buffers.transferToBuffer(
        ctx,
        &self.compute_pipeline.buffers,
        buffer_offset + offset * @sizeOf(GridState.GridEntry),
        GridState.GridEntry,
        grid_entries,
    );
}

/// Transfer bricks data to GPU
pub inline fn transferBricks(self: *Pipeline, ctx: Context, offset: usize, bricks: []const GridState.Brick) !void {
    const buffer_offset = self.compute_pipeline.storage_offsets[6];
    try self.staging_buffers.transferToBuffer(
        ctx,
        &self.compute_pipeline.buffers,
        buffer_offset + offset * @sizeOf(GridState.Brick),
        GridState.Brick,
        bricks,
    );
}

/// Transfer material index data to GPU
pub inline fn transferMaterialIndices(self: *Pipeline, ctx: Context, offset: usize, material_indices: []const u8) !void {
    const buffer_offset = self.compute_pipeline.storage_offsets[7];
    try self.staging_buffers.transferToBuffer(
        ctx,
        &self.compute_pipeline.buffers,
        buffer_offset + offset * @sizeOf(u8),
        u8,
        material_indices,
    );
}

// TODO: make allow to multithread this
/// Used to update the pipeline according to changes in the window spec
/// This functions should only be called from the main thread (see glfwGetFramebufferSize)
fn rescalePipeline(self: *Pipeline, ctx: Context) !void {
    const rescale_zone = tracy.ZoneN(@src(), "rescale pipeline");
    defer rescale_zone.End();

    var window_size = try ctx.window_ptr.*.getFramebufferSize();
    if (window_size.width == 0 or window_size.height == 0) {
        window_size = try ctx.window_ptr.*.getFramebufferSize();
        try glfw.waitEvents();
    }

    self.requested_rescale_pipeline = false;

    // Wait for pipeline to become idle
    {
        _ = ctx.vkd.waitForFences(
            ctx.logical_device,
            @intCast(u32, self.compute_pipeline.complete_fences.len),
            self.compute_pipeline.complete_fences.ptr,
            vk.TRUE,
            std.math.maxInt(u64),
        ) catch |err| std.debug.print("failed to wait for compute fences, err: {any}", .{err});
        // wait for previous texture draw before updating buffers and command buffers
        _ = try ctx.vkd.waitForFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.render_complete_fence), vk.TRUE, std.math.maxInt(u64));
    }

    // recreate swapchain utilizing the old one
    const old_swapchain = self.swapchain;
    defer old_swapchain.deinit(ctx);

    self.swapchain = try render.swapchain.Data.init(self.allocator, ctx, self.init_command_pool, old_swapchain.swapchain);
    errdefer self.swapchain.deinit(ctx);

    // recreate renderpass
    ctx.destroyRenderPass(self.render_pass);
    self.render_pass = try ctx.createRenderPass(self.swapchain.format);
    errdefer ctx.destroyRenderPass(self.render_pass);
    self.render_pass_begin_info.render_pass = self.render_pass;

    // recreate framebuffers
    for (self.gfx_pipeline.framebuffers) |framebuffer| {
        ctx.vkd.destroyFramebuffer(ctx.logical_device, framebuffer, null);
    }
    self.gfx_pipeline.framebuffers = try render.pipeline.createFramebuffers(self.allocator, ctx, &self.swapchain, self.render_pass, self.gfx_pipeline.framebuffers);
    errdefer {
        for (framebuffers) |buffer| {
            ctx.vkd.destroyFramebuffer(ctx.logical_device, buffer, null);
        }
        self.allocator.free(framebuffers);
    }

    self.gui.handleRescale(@intToFloat(f32, window_size.width), @intToFloat(f32, window_size.height));
}

/// prepare gfx_pipeline + imgui_pipeline command buffer
fn recordCommandBuffers(self: Pipeline, ctx: Context) !void {
    // copy begin info
    var begin_info = self.render_pass_begin_info;
    for (self.gfx_pipeline.command_buffers) |_, i| {
        try self.recordCommandBuffer(ctx, i, &begin_info);
    }
}

// TODO: properly handling of errors
fn recordCommandBuffer(self: Pipeline, ctx: Context, index: usize, begin_info: *vk.RenderPassBeginInfo) !void {
    const record_zone = tracy.ZoneN(@src(), "record gfx & imgui commands");
    defer record_zone.End();

    const command_buffer = self.gfx_pipeline.command_buffers[index];
    try ctx.vkd.beginCommandBuffer(command_buffer, &command_buffer_info);

    // make sure that compute shader writes are finished before sampling from the texture
    const image_barrier = vk.ImageMemoryBarrier{
        .src_access_mask = .{ .shader_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
        .old_layout = .general,
        .new_layout = .shader_read_only_optimal,
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.graphics,
        .image = self.compute_image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    ctx.vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .compute_shader_bit = true },
        .{ .fragment_shader_bit = true },
        .{},
        0,
        undefined,
        0,
        undefined,
        1,
        @ptrCast([*]const vk.ImageMemoryBarrier, &image_barrier),
    );

    // set target framebuffer
    begin_info.framebuffer = self.gfx_pipeline.framebuffers[index];
    ctx.vkd.cmdBeginRenderPass(command_buffer, begin_info, .@"inline");

    {
        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @intToFloat(f32, self.swapchain.extent.width),
            .height = @intToFloat(f32, self.swapchain.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        ctx.vkd.cmdSetViewport(
            command_buffer,
            0,
            1,
            @ptrCast([*]const vk.Viewport, &viewport),
        );
    }

    {
        const scissor = vk.Rect2D{
            .offset = .{
                .x = 0,
                .y = 0,
            },
            .extent = self.swapchain.extent,
        };
        ctx.vkd.cmdSetScissor(command_buffer, 0, 1, @ptrCast([*]const vk.Rect2D, &scissor));
    }

    ctx.vkd.cmdPushConstants(
        command_buffer,
        self.gfx_pipeline.pipeline_layout,
        .{ .fragment_bit = true },
        0,
        @sizeOf(GraphicsPipeline.PushConstant),
        self.gfx_pipeline.shader_constants,
    );

    ctx.vkd.cmdBindDescriptorSets(
        command_buffer,
        .graphics,
        self.gfx_pipeline.pipeline_layout,
        0,
        1,
        @ptrCast([*]const vk.DescriptorSet, &self.gfx_pipeline.descriptor_set),
        0,
        undefined,
    );
    ctx.vkd.cmdBindPipeline(command_buffer, .graphics, self.gfx_pipeline.pipeline);
    ctx.vkd.cmdBindVertexBuffers(
        command_buffer,
        0,
        1,
        @ptrCast([*]const vk.Buffer, &self.vertex_index_buffer.buffer),
        &vertex_zero_offset,
    );
    ctx.vkd.cmdBindIndexBuffer(command_buffer, self.vertex_index_buffer.buffer, GraphicsPipeline.vertex_size, .uint16);
    ctx.vkd.cmdDrawIndexed(command_buffer, GraphicsPipeline.indices.len, 1, 0, 0, 0);

    try self.imgui_pipeline.recordCommandBuffer(
        ctx,
        command_buffer,
        self.gfx_pipeline.bytes_used_in_buffer,
        self.vertex_index_buffer,
    );

    ctx.vkd.cmdEndRenderPass(command_buffer);

    try ctx.vkd.endCommandBuffer(command_buffer);
}

const command_buffer_info = vk.CommandBufferBeginInfo{
    .flags = .{
        .one_time_submit_bit = true,
    },
    .p_inheritance_info = null,
};
const clear_values = [_]vk.ClearValue{
    .{
        .color = .{ .float_32 = .{ 0.025, 0.025, 0.025, 1.0 } },
    },
    .{
        .depth_stencil = .{ .depth = 1.0, .stencil = 0.0 },
    },
};
const vertex_zero_offset = [_]vk.DeviceSize{0};
