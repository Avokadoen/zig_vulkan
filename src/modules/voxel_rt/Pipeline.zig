const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const render = @import("../render.zig");
const Context = render.Context;
const Texture = render.Texture;

// TODO: move pipelines to ./internal/render/
const ComputePipeline = @import("ComputePipeline.zig");
const GraphicsPipeline = @import("GraphicsPipeline.zig");
const ImguiPipeline = @import("ImguiPipeline.zig");

const ImguiGui = @import("ImguiGui.zig");

const Camera = @import("Camera.zig");
const GridState = @import("brick/State.zig");
const gpu_types = @import("gpu_types.zig");

pub const Config = struct {
    material_buffer: u64 = 256,
    albedo_buffer: u64 = 256,
    metal_buffer: u64 = 256,
    dielectric_buffer: u64 = 256,

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
target_texture: *Texture,
swapchain: render.swapchain.Data,
render_pass: vk.RenderPass,
render_pass_begin_info: vk.RenderPassBeginInfo,

compute_complete_semaphore: vk.Semaphore,
compute_complete_fence: vk.Fence,

present_complete_semaphore: vk.Semaphore,
render_complete_semaphore: vk.Semaphore,
render_complete_fence: vk.Fence,

compute_pipeline: ComputePipeline,
// TODO: rename pipeline
gfx_pipeline: GraphicsPipeline,
imgui_pipeline: ImguiPipeline,

camera: *Camera,
gui: ImguiGui,

pub fn init(ctx: Context, allocator: Allocator, internal_render_resolution: vk.Extent2D, grid_state: GridState, camera: *Camera, config: Config) !Pipeline {
    const target_texture = try allocator.create(Texture);
    errdefer allocator.destroy(target_texture);

    // use graphics and compute index
    // if they are the same, then we use that index
    const indices = [_]u32{ ctx.queue_indices.graphics, ctx.queue_indices.compute };
    const indices_len: usize = if (ctx.queue_indices.graphics == ctx.queue_indices.compute) 1 else 2;
    target_texture.* = blk: {
        const texture_config = Texture.Config(Pixel){
            .data = null,
            .width = internal_render_resolution.width,
            .height = internal_render_resolution.height,
            .usage = .{ .sampled_bit = true, .storage_bit = true },
            .queue_family_indices = indices[0..indices_len],
            .format = .r8g8b8a8_unorm,
        };
        break :blk try Texture.init(ctx, ctx.gfx_cmd_pool, .general, Pixel, texture_config);
    };
    errdefer target_texture.deinit(ctx);

    const swapchain = try render.swapchain.Data.init(allocator, ctx, null);
    errdefer swapchain.deinit(ctx);

    const render_pass = try ctx.createRenderPass(swapchain.format);
    errdefer ctx.destroyRenderPass(render_pass);

    const semaphore_info = vk.SemaphoreCreateInfo{ .flags = .{} };
    const compute_complete_semaphore = try ctx.vkd.createSemaphore(ctx.logical_device, &semaphore_info, null);
    errdefer ctx.vkd.destroySemaphore(ctx.logical_device, compute_complete_semaphore, null);
    const present_complete_semaphore = try ctx.vkd.createSemaphore(ctx.logical_device, &semaphore_info, null);
    errdefer ctx.vkd.destroySemaphore(ctx.logical_device, present_complete_semaphore, null);
    const render_complete_semaphore = try ctx.vkd.createSemaphore(ctx.logical_device, &semaphore_info, null);
    errdefer ctx.vkd.destroySemaphore(ctx.logical_device, render_complete_semaphore, null);

    const fence_info = vk.FenceCreateInfo{
        .flags = .{
            .signaled_bit = true,
        },
    };
    const compute_complete_fence = try ctx.vkd.createFence(ctx.logical_device, &fence_info, null);
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

        break :blk try ComputePipeline.init(allocator, ctx, "brick_raytracer.comp.spv", target_texture, state_configs);
    };
    errdefer compute_pipeline.deinit(ctx);

    try compute_pipeline.recordCommandBuffers(ctx, camera.*);

    const gfx_pipeline = try GraphicsPipeline.init(allocator, ctx, swapchain, render_pass, target_texture, config.gfx_pipeline_config);
    errdefer gfx_pipeline.deinit(allocator, ctx);

    const imgui_pipeline = try ImguiPipeline.init(ctx, allocator, render_pass, swapchain.images.len);
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
        .gfx_pipeline_shader_constants = gfx_pipeline.shader_constants,
    };
    const gui = ImguiGui.init(
        @intToFloat(f32, swapchain.extent.width),
        @intToFloat(f32, swapchain.extent.height),
        state_binding,
        .{},
    );

    return Pipeline{
        .allocator = allocator,
        .target_texture = target_texture,
        .swapchain = swapchain,
        .render_pass = render_pass,
        .render_pass_begin_info = render_pass_begin_info,
        .compute_complete_semaphore = compute_complete_semaphore,
        .compute_complete_fence = compute_complete_fence,
        .present_complete_semaphore = present_complete_semaphore,
        .render_complete_semaphore = render_complete_semaphore,
        .render_complete_fence = render_complete_fence,
        .compute_pipeline = compute_pipeline,
        .gfx_pipeline = gfx_pipeline,
        .imgui_pipeline = imgui_pipeline,
        .camera = camera,
        .gui = gui,
    };
}

pub fn deinit(self: Pipeline, ctx: Context) void {
    _ = ctx.vkd.waitForFences(
        ctx.logical_device,
        1,
        @ptrCast([*]const vk.Fence, &self.compute_complete_fence),
        vk.TRUE,
        std.math.maxInt(u64),
    ) catch |err| std.debug.print("failed to wait for gfx fence, err: {any}", .{err});

    _ = ctx.vkd.waitForFences(
        ctx.logical_device,
        1,
        @ptrCast([*]const vk.Fence, &self.render_complete_fence),
        vk.TRUE,
        std.math.maxInt(u64),
    ) catch |err| std.debug.print("failed to wait for compute fence, err: {any}", .{err});

    ctx.vkd.destroySemaphore(ctx.logical_device, self.compute_complete_semaphore, null);
    ctx.vkd.destroySemaphore(ctx.logical_device, self.present_complete_semaphore, null);
    ctx.vkd.destroySemaphore(ctx.logical_device, self.render_complete_semaphore, null);
    ctx.vkd.destroyFence(ctx.logical_device, self.compute_complete_fence, null);
    ctx.vkd.destroyFence(ctx.logical_device, self.render_complete_fence, null);

    self.imgui_pipeline.deinit(ctx);
    self.gfx_pipeline.deinit(self.allocator, ctx);
    self.compute_pipeline.deinit(ctx);
    ctx.destroyRenderPass(self.render_pass);
    self.swapchain.deinit(ctx);

    self.target_texture.deinit(ctx);
    self.allocator.destroy(self.target_texture);
}

pub fn draw(self: *Pipeline, ctx: Context) !void {
    // wait for previous compute dispatch to complete
    _ = try ctx.vkd.waitForFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.compute_complete_fence), vk.TRUE, std.math.maxInt(u64));
    try ctx.vkd.resetFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.compute_complete_fence));

    try self.compute_pipeline.recordCommandBuffers(ctx, self.camera.*);

    // perform the compute ray tracing, draw to target texture
    const compute_submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.compute_pipeline.command_buffer),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast([*]const vk.Semaphore, &self.compute_complete_semaphore),
    };
    try ctx.vkd.queueSubmit(ctx.compute_queue, 1, @ptrCast([*]const vk.SubmitInfo, &compute_submit_info), self.compute_complete_fence);

    const aquire_result = try ctx.vkd.acquireNextImageKHR(
        ctx.logical_device,
        self.swapchain.swapchain,
        std.math.maxInt(u64),
        self.present_complete_semaphore,
        .null_handle,
    ); // TODO: handle out of date khr: rescale pipeline
    if (aquire_result.result == .suboptimal_khr) {
        // TODO: request rescale pipeline(s)!
    }
    const image_index = aquire_result.image_index;

    // wait for previous texture draw before updating buffers and command buffers
    _ = try ctx.vkd.waitForFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.render_complete_fence), vk.TRUE, std.math.maxInt(u64));
    try ctx.vkd.resetFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.render_complete_fence));

    self.gui.newFrame(ctx, self, image_index == 0);
    try self.imgui_pipeline.updateBuffers(ctx);

    // re-record command buffer to update any state
    var begin_info = self.render_pass_begin_info;
    try self.recordCommandBuffer(ctx, image_index, &begin_info);

    const stage_masks = [_]vk.PipelineStageFlags{ .{ .vertex_input_bit = true }, .{ .color_attachment_output_bit = true } };
    const wait_semaphores = [stage_masks.len]vk.Semaphore{ self.compute_complete_semaphore, self.present_complete_semaphore };
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
    const queue_result = try ctx.vkd.queuePresentKHR(ctx.graphics_queue, &present_info);
    _ = queue_result; // TODO: perform resize here if out of date reported by queuePresentKHR

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
pub inline fn transferGridState(self: Pipeline, ctx: Context, grid: GridState) !void {
    const grid_data = [_]GridState.Device{grid.device_state};
    try self.compute_pipeline.uniform_buffers[0].transferToDevice(ctx, GridState.Device, 0, grid_data[0..]);
}

/// Transfer material data to GPU
pub inline fn transferMaterials(self: Pipeline, ctx: Context, offset: usize, materials: []const gpu_types.Material) !void {
    try self.compute_pipeline.storage_buffers[0].transferToDevice(ctx, gpu_types.Material, offset, materials);
}

/// Transfer albedo data to GPU
pub inline fn transferAlbedos(self: Pipeline, ctx: Context, offset: usize, albedo: []const gpu_types.Albedo) !void {
    try self.compute_pipeline.storage_buffers[1].transferToDevice(ctx, gpu_types.Albedo, offset, albedo);
}

/// Transfer metal data to GPU
pub inline fn transferMetals(self: Pipeline, ctx: Context, offset: usize, metals: []const gpu_types.Metal) !void {
    try self.compute_pipeline.storage_buffers[2].transferToDevice(ctx, gpu_types.Metal, offset, metals);
}

/// Transfer dielectric data to GPU
pub inline fn transferDielectrics(self: Pipeline, ctx: Context, offset: usize, dielectrics: []const gpu_types.Dielectric) !void {
    try self.compute_pipeline.storage_buffers[3].transferToDevice(ctx, gpu_types.Dielectric, offset, dielectrics);
}

/// Transfer higher order grid data to GPU
pub inline fn transferHigherOrderGrid(self: Pipeline, ctx: Context, offset: usize, higher_order_grid: []const u8) !void {
    try self.compute_pipeline.storage_buffers[4].transferToDevice(ctx, u8, offset, higher_order_grid);
}

/// Transfer dielectric data to GPU
pub inline fn transferGridEntries(self: Pipeline, ctx: Context, offset: usize, grid_entries: []const GridState.GridEntry) !void {
    try self.compute_pipeline.storage_buffers[5].transferToDevice(ctx, GridState.GridEntry, offset, grid_entries);
}

/// Transfer dielectric data to GPU
pub inline fn transferBricks(self: Pipeline, ctx: Context, offset: usize, bricks: []const GridState.Brick) !void {
    try self.compute_pipeline.storage_buffers[6].transferToDevice(ctx, GridState.Brick, offset, bricks);
}

/// Transfer dielectric data to GPU
pub inline fn transferMaterialIndices(self: Pipeline, ctx: Context, offset: usize, material_indices: []const u8) !void {
    try self.compute_pipeline.storage_buffers[7].transferToDevice(ctx, u8, offset, material_indices);
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
    const command_buffer = self.gfx_pipeline.command_buffers[index];
    try ctx.vkd.beginCommandBuffer(command_buffer, &command_buffer_info);

    // make sure that compute shader writes are finished before sampling from the texture
    const image_barrier = vk.ImageMemoryBarrier{
        .src_access_mask = .{ .shader_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
        .old_layout = .general,
        .new_layout = .general,
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.graphics,
        .image = self.target_texture.image,
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
        @ptrCast([*]const vk.Buffer, &self.gfx_pipeline.vertex_buffer.buffer),
        &vertex_zero_offset,
    );
    ctx.vkd.cmdBindIndexBuffer(command_buffer, self.gfx_pipeline.index_buffer.buffer, 0, .uint16);
    ctx.vkd.cmdDrawIndexed(command_buffer, self.gfx_pipeline.index_buffer.len, 1, 0, 0, 0);

    try self.imgui_pipeline.recordCommandBuffer(ctx, command_buffer);

    ctx.vkd.cmdEndRenderPass(command_buffer);

    try ctx.vkd.endCommandBuffer(command_buffer);
}

const command_buffer_info = vk.CommandBufferBeginInfo{
    .flags = .{},
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
