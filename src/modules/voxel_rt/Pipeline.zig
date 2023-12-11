const std = @import("std");
const Allocator = std.mem.Allocator;

const glfw = @import("mach-glfw");

const tracy = @import("ztracy");

const shaders = @import("shaders");

const vk = @import("vulkan");
const render = @import("../render.zig");
const Context = render.Context;
const texture = render.texture;
const vk_utils = render.vk_utils;
const memory = render.memory;

const ray_pipeline_types = @import("ray_pipeline_types.zig");

// TODO: move pipelines to ./internal/render/
const RayDeviceResources = @import("RayDeviceResources.zig");
const EmitRayPipeline = @import("EmitRayPipeline.zig");
const TraverseRayPipeline = @import("TraverseRayPipeline.zig");
const BubbleSortPipeline = @import("gpu_sort/BubbleSortPipeline.zig");
const ScatterRayPipeline = @import("ScatterRayPipeline.zig");
const MissRayPipeline = @import("MissRayPipeline.zig");
const DrawRayPipeline = @import("DrawRayPipeline.zig");
const BrickHeartbeatPipeline = @import("BrickHeartbeatPipeline.zig");
const BrickUnloadPipeline = @import("BrickUnloadPipeline.zig");

const BrickStream = @import("brick/BrickStream.zig");
const HostBrickState = @import("brick/HostBrickState.zig");

const GraphicsPipeline = @import("GraphicsPipeline.zig");
const ImguiPipeline = @import("ImguiPipeline.zig");
const StagingRamp = render.StagingRamp;
const GpuBufferMemory = render.GpuBufferMemory;

const ImguiGui = @import("ImguiGui.zig");

const Camera = @import("Camera.zig");
const Sun = @import("Sun.zig");
const gpu_types = @import("gpu_types.zig");

pub const Config = struct {
    material_buffer: u64 = 256,
    albedo_buffer: u64 = 256,
    metal_buffer: u64 = 256,
    dielectric_buffer: u64 = 256,

    staging_buffers: usize = 1,
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
staging_buffers: StagingRamp,

swapchain: render.swapchain.Data,
render_pass: vk.RenderPass,

present_complete_semaphore: vk.Semaphore,
render_complete_semaphore: vk.Semaphore,
render_complete_fence: vk.Fence,

ray_command_pool: vk.CommandPool,
// TODO: this should be an array
ray_command_buffers: vk.CommandBuffer,
ray_device_resources: *RayDeviceResources,
emit_ray_pipeline: EmitRayPipeline,
traverse_ray_pipeline: TraverseRayPipeline,
scatter_ray_pipeline: ScatterRayPipeline,
miss_ray_pipeline: MissRayPipeline,
draw_ray_pipeline: DrawRayPipeline,

brick_heartbeat_pipeline: BrickHeartbeatPipeline,
brick_unload_pipeline: BrickUnloadPipeline,

ray_pipeline_complete_semaphore: vk.Semaphore,

brick_stream: BrickStream,

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

pub fn init(
    ctx: Context,
    allocator: Allocator,
    internal_render_resolution: vk.Extent2D,
    camera: *Camera,
    sun: *Sun,
    host_brick_state: *HostBrickState,
    config: Config,
) !Pipeline {
    const zone = tracy.ZoneN(@src(), @typeName(Pipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    const pool_info = vk.CommandPoolCreateInfo{
        .flags = .{ .transient_bit = true },
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
            .queue_family_index_count = @as(u32, @intCast(indices_len)),
            .p_queue_family_indices = &indices,
            .initial_layout = .undefined,
        };
        break :blk try ctx.vkd.createImage(ctx.logical_device, &image_info, null);
    };
    errdefer ctx.vkd.destroyImage(ctx.logical_device, compute_image, null);

    // Allocate memory for all pipeline images
    const memory_requirements = ctx.vkd.getImageMemoryRequirements(ctx.logical_device, compute_image);
    const image_memory_type_index = try vk_utils.findMemoryTypeIndex(ctx, memory_requirements.memory_type_bits, .{
        .device_local_bit = true,
    });
    const image_memory_capacity = 250 * render.memory.bytes_in_mb;
    const image_alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = image_memory_capacity,
        .memory_type_index = image_memory_type_index,
    };
    const image_memory = try ctx.vkd.allocateMemory(ctx.logical_device, &image_alloc_info, null);
    errdefer ctx.vkd.freeMemory(ctx.logical_device, image_memory, null);

    try ctx.vkd.bindImageMemory(ctx.logical_device, compute_image, image_memory, 0);
    var image_memory_size = memory_requirements.size;

    // Transition from undefined -> general -> shader_read_only_optimal. This is to silence validation layers (compared to undefined to read only which would be invalid)
    // The image will be transitioned back to general when we render with a compute job, and then to shader_read_only_optimal as it is sampled in a fragment shader.
    try texture.transitionImageLayout(ctx, init_command_pool, compute_image, .undefined, .general);
    try texture.transitionImageLayout(ctx, init_command_pool, compute_image, .general, .shader_read_only_optimal);

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
    const ray_pipeline_complete_semaphore = try ctx.vkd.createSemaphore(ctx.logical_device, &semaphore_info, null);
    errdefer ctx.vkd.destroySemaphore(ctx.logical_device, ray_pipeline_complete_semaphore, null);

    const fence_info = vk.FenceCreateInfo{
        .flags = .{
            .signaled_bit = true,
        },
    };
    const render_complete_fence = try ctx.vkd.createFence(ctx.logical_device, &fence_info, null);

    var staging_buffers = try StagingRamp.init(ctx, allocator, config.staging_buffers);
    errdefer staging_buffers.deinit(ctx, allocator);

    const ray_command_pool = blk: {
        const ray_pool_info = vk.CommandPoolCreateInfo{
            .flags = .{},
            .queue_family_index = ctx.queue_indices.compute,
        };
        break :blk try ctx.vkd.createCommandPool(ctx.logical_device, &ray_pool_info, null);
    };
    errdefer ctx.vkd.destroyCommandPool(ctx.logical_device, ray_command_pool, null);

    const ray_command_buffers = try render.pipeline.createCmdBuffer(ctx, ray_command_pool);
    errdefer ctx.vkd.freeCommandBuffers(
        ctx.logical_device,
        ray_command_pool,
        @as(u32, @intCast(1)),
        @as([*]const vk.CommandBuffer, @ptrCast(&ray_command_buffers)),
    );

    var ray_device_resources = try allocator.create(RayDeviceResources);
    errdefer allocator.destroy(ray_device_resources);

    const target_image_info = ray_pipeline_types.ImageInfo{
        .width = @as(f32, @floatFromInt(internal_render_resolution.width)),
        .height = @as(f32, @floatFromInt(internal_render_resolution.height)),
        .image = compute_image,
        .sampler = sampler,
        .image_view = compute_image_view,
    };
    ray_device_resources.* = try RayDeviceResources.init(
        allocator,
        ctx,
        target_image_info,
        init_command_pool,
        &staging_buffers,
        host_brick_state,
    );
    errdefer ray_device_resources.deinit(ctx);

    var traverse_ray_pipeline = try TraverseRayPipeline.init(ctx, ray_device_resources);
    errdefer traverse_ray_pipeline.deinit(ctx);

    const emit_ray_pipeline = try EmitRayPipeline.init(ctx, ray_device_resources);
    errdefer emit_ray_pipeline.deinit(ctx);

    const scatter_ray_pipeline = try ScatterRayPipeline.init(ctx, ray_device_resources);
    errdefer scatter_ray_pipeline.deinit(ctx);

    const miss_ray_pipeline = try MissRayPipeline.init(ctx, ray_device_resources);
    errdefer miss_ray_pipeline.deinit(ctx);

    const draw_ray_pipeline = try DrawRayPipeline.init(ctx, ray_device_resources);
    errdefer draw_ray_pipeline.deinit(ctx);

    const brick_heartbeat_pipeline = try BrickHeartbeatPipeline.init(ctx, ray_device_resources);
    errdefer brick_heartbeat_pipeline.deinit(ctx);

    const brick_unload_pipeline = try BrickUnloadPipeline.init(ctx, ray_device_resources);
    errdefer brick_heartbeat_pipeline.deinit(ctx);

    const brick_stream = try BrickStream.init(allocator, host_brick_state.brick_limits);
    errdefer brick_stream.deinit();

    var vertex_index_buffer = try GpuBufferMemory.init(
        ctx,
        memory.bytes_in_mb * 64,
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
        image_memory_type_index,
        image_memory,
        image_memory_capacity,
        &image_memory_size,
    );
    errdefer imgui_pipeline.deinit(ctx);

    const state_binding = ImguiGui.StateBinding{
        .camera_ptr = camera,
        .sun_ptr = sun,
        .gfx_pipeline_shader_constants = gfx_pipeline.shader_constants,
        .brick_grid_metadata = &host_brick_state.grid_metadata,
    };
    const gui = ImguiGui.init(
        ctx,
        @as(f32, @floatFromInt(swapchain.extent.width)),
        @as(f32, @floatFromInt(swapchain.extent.height)),
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
        .present_complete_semaphore = present_complete_semaphore,
        .render_complete_semaphore = render_complete_semaphore,
        .render_complete_fence = render_complete_fence,
        .ray_command_pool = ray_command_pool,
        .ray_command_buffers = ray_command_buffers,
        .ray_device_resources = ray_device_resources,
        .emit_ray_pipeline = emit_ray_pipeline,
        .traverse_ray_pipeline = traverse_ray_pipeline,
        .scatter_ray_pipeline = scatter_ray_pipeline,
        .miss_ray_pipeline = miss_ray_pipeline,
        .draw_ray_pipeline = draw_ray_pipeline,
        .brick_heartbeat_pipeline = brick_heartbeat_pipeline,
        .brick_unload_pipeline = brick_unload_pipeline,
        .ray_pipeline_complete_semaphore = ray_pipeline_complete_semaphore,
        .brick_stream = brick_stream,
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
    const zone = tracy.ZoneN(@src(), @typeName(Pipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    ctx.vkd.queueWaitIdle(ctx.compute_queue) catch {};
    ctx.vkd.queueWaitIdle(ctx.graphics_queue) catch {};
    ctx.vkd.queueWaitIdle(ctx.present_queue) catch {};

    ctx.vkd.destroySemaphore(ctx.logical_device, self.present_complete_semaphore, null);
    ctx.vkd.destroySemaphore(ctx.logical_device, self.render_complete_semaphore, null);
    ctx.vkd.destroySemaphore(ctx.logical_device, self.ray_pipeline_complete_semaphore, null);
    ctx.vkd.destroyFence(ctx.logical_device, self.render_complete_fence, null);

    // wait for staging buffer transfer to finish before deinit staging buffer and
    // any potential src buffers
    self.staging_buffers.waitIdle(ctx) catch {};
    self.staging_buffers.deinit(ctx, self.allocator);

    self.draw_ray_pipeline.deinit(ctx);
    self.miss_ray_pipeline.deinit(ctx);
    self.scatter_ray_pipeline.deinit(ctx);
    self.traverse_ray_pipeline.deinit(ctx);
    self.emit_ray_pipeline.deinit(ctx);
    self.ray_device_resources.deinit(ctx);
    self.brick_heartbeat_pipeline.deinit(ctx);
    self.brick_unload_pipeline.deinit(ctx);

    self.brick_stream.deinit();

    self.allocator.destroy(self.ray_device_resources);

    ctx.vkd.freeCommandBuffers(
        ctx.logical_device,
        self.ray_command_pool,
        @as(u32, @intCast(1)),
        @as([*]const vk.CommandBuffer, @ptrCast(&self.ray_command_buffers)),
    );
    ctx.vkd.destroyCommandPool(ctx.logical_device, self.ray_command_pool, null);

    self.imgui_pipeline.deinit(ctx);
    self.gfx_pipeline.deinit(self.allocator, ctx);
    // self.compute_pipeline.deinit(ctx);
    ctx.destroyRenderPass(self.render_pass);
    self.swapchain.deinit(ctx);
    self.vertex_index_buffer.deinit(ctx);

    ctx.vkd.destroyCommandPool(ctx.logical_device, self.init_command_pool, null);

    ctx.vkd.destroySampler(ctx.logical_device, self.sampler, null);
    ctx.vkd.destroyImageView(ctx.logical_device, self.compute_image_view, null);
    ctx.vkd.destroyImage(ctx.logical_device, self.compute_image, null);
    ctx.vkd.freeMemory(ctx.logical_device, self.image_memory, null);
}

// TODO: split these into multiple errors
pub const DrawError = error{
    DeviceLost,
    FullScreenExclusiveModeLostEXT,
    OutOfDateKHR,
    OutOfDeviceMemory,
    OutOfHostMemory,
    SurfaceLostKHR,
    UnhandledAcquireResult,
    Unknown,
    InsufficientMemory,
    MemoryMapFailed,
    FailedToMapGPUMem,
    PlatformError,
    APIUnavailable,
    CursorUnavailable,
    FeatureUnavailable,
    FeatureUnimplemented,
    FormatUnavailable,
    InvalidEnum,
    InvalidValue,
    NoCurrentContext,
    NoWindowContext,
    NotInitialized,
    OutOfMemory,
    PlatformUnavailable,
    VersionUnavailable,
    InitializationFailed,
    NativeWindowInUseKHR,
    NoSurfaceFormatsSupported,
    NoPresentModesSupported,
    StagingBuffersFull,
    DestOutOfDeviceMemory,
    StageOutOfDeviceMemory,
    OutOfRegions,
};
/// draw a new frame, delta time is only used by gui
pub fn draw(self: *Pipeline, ctx: Context, host_brick_state: *HostBrickState, dt: f32) DrawError!void {
    const zone = tracy.ZoneN(@src(), @typeName(Pipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    // const compute_semaphore = try self.compute_pipeline.dispatch(ctx, self.camera.*, self.sun.*);

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
        _ = try ctx.vkd.waitForFences(ctx.logical_device, 1, @as([*]const vk.Fence, @ptrCast(&self.render_complete_fence)), vk.TRUE, std.math.maxInt(u64));
        try ctx.vkd.resetFences(ctx.logical_device, 1, @as([*]const vk.Fence, @ptrCast(&self.render_complete_fence)));
    }

    // grab any new brick requests
    load_bricks_blk: {
        try self.ray_device_resources.mapBrickRequestData(ctx);
        defer self.ray_device_resources.request_buffer.unmap(ctx);

        const snapshot = try self.brick_stream.takeSnapshot(
            ctx,
            self.ray_device_resources,
        );

        if (snapshot.brick_limits.load_request_count == 0) {
            break :load_bricks_blk;
        }

        // TODO: remove alloc, alloc on init
        const new_bricks = try self.allocator.alloc(ray_pipeline_types.Brick, snapshot.brick_limits.load_request_count);
        defer self.allocator.free(new_bricks);

        std.debug.assert(snapshot.brick_limits.max_active_bricks >= snapshot.brick_limits.active_bricks);
        std.debug.assert(snapshot.brick_limits.active_bricks >= 0);

        const load_req_count: usize = @intCast(@min(
            snapshot.brick_limits.load_request_count,
            snapshot.brick_limits.max_active_bricks - @as(c_uint, @intCast(snapshot.brick_limits.active_bricks)),
        ));

        for (snapshot.brick_load_requests[0..load_req_count], new_bricks) |load_index, *new_brick| {
            new_brick.* = host_brick_state.bricks[load_index];
            std.debug.print("{any}\n", .{new_brick.*});
        }

        host_brick_state.brick_limits = snapshot.brick_limits;
    }

    // The pipeline has the following stages:
    //
    //         emit
    //           |
    //           v
    //       traverse<--\
    //           |       |
    //      sort_active  |
    //          / \      |
    //         v   v     |-([1] no)
    //       miss  hit   |
    //        |      x---|
    //        \     / \- - - -([1] reached max bounce?)
    //         \   /\
    //           v   ([1] yes)
    //          draw
    //
    //
    const ray_tracing_pipeline_complete_semaphore = blk: {
        const max_bounces = @as(u32, @intCast(self.camera.d_camera.max_bounce));

        try ctx.vkd.resetCommandPool(ctx.logical_device, self.ray_command_pool, .{});

        const command_begin_info = vk.CommandBufferBeginInfo{
            .flags = .{
                .one_time_submit_bit = true,
            },
            .p_inheritance_info = null,
        };
        try ctx.vkd.beginCommandBuffer(self.ray_command_buffers, &command_begin_info);

        // // putt all to all barrier i mellom hver pipeline
        // TODO: pipeline barrier expressed here between the appends:
        self.emit_ray_pipeline.appendPipelineCommands(ctx, self.camera.*, self.ray_command_buffers);
        // TODO: specify read only vs write only buffer elements (maybe actually loop buffer infos ?)
        const ray_buffer_memory_barrier = vk.BufferMemoryBarrier{
            .src_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
            .src_queue_family_index = ctx.queue_indices.compute,
            .dst_queue_family_index = ctx.queue_indices.compute,
            .buffer = self.ray_device_resources.ray_buffer.buffer,
            .offset = 0,
            .size = vk.WHOLE_SIZE,
        };
        const frame_mem_barriers = [_]vk.BufferMemoryBarrier{ray_buffer_memory_barrier};
        ctx.vkd.cmdPipelineBarrier(
            self.ray_command_buffers,
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

        for (0..max_bounces + 1) |bounce_index| {
            if (bounce_index > 0) {
                self.ray_device_resources.resetRayLimits(ctx, self.ray_command_buffers);
            }
            self.traverse_ray_pipeline.appendPipelineCommands(ctx, bounce_index, self.ray_command_buffers);
            self.scatter_ray_pipeline.appendPipelineCommands(ctx, bounce_index, self.ray_command_buffers);

            self.miss_ray_pipeline.appendPipelineCommands(ctx, bounce_index, self.ray_command_buffers);
            self.draw_ray_pipeline.appendPipelineCommands(ctx, bounce_index, .draw_miss, bounce_index == 0, self.ray_command_buffers);
        }
        self.draw_ray_pipeline.appendPipelineCommands(
            ctx,
            max_bounces,
            .draw_hit,
            false,
            self.ray_command_buffers,
        );

        self.brick_heartbeat_pipeline.appendPipelineCommands(ctx, self.ray_command_buffers);
        self.brick_unload_pipeline.appendPipelineCommands(ctx, self.ray_command_buffers);

        try ctx.vkd.endCommandBuffer(self.ray_command_buffers);

        {
            @setRuntimeSafety(false);
            const semo_null_ptr: [*c]const vk.Semaphore = null;
            const wait_null_ptr: [*c]const vk.PipelineStageFlags = null;
            // perform the compute ray tracing, draw to target texture
            const submit_info = vk.SubmitInfo{
                .wait_semaphore_count = 0,
                .p_wait_semaphores = semo_null_ptr,
                .p_wait_dst_stage_mask = wait_null_ptr,
                .command_buffer_count = 1,
                .p_command_buffers = @as([*]const vk.CommandBuffer, @ptrCast(&self.ray_command_buffers)),
                .signal_semaphore_count = 1,
                .p_signal_semaphores = @as([*]const vk.Semaphore, @ptrCast(&self.ray_pipeline_complete_semaphore)),
            };
            try ctx.vkd.queueSubmit(ctx.compute_queue, 1, @as([*]const vk.SubmitInfo, @ptrCast(&submit_info)), .null_handle);
        }

        break :blk self.ray_pipeline_complete_semaphore;
    };

    self.gui.newFrame(ctx, self, image_index == 0, dt);
    try self.imgui_pipeline.updateBuffers(
        ctx,
        self.gfx_pipeline.bytes_used_in_buffer,
        &self.vertex_index_buffer,
    );

    // re-record command buffer to update any state
    try ctx.vkd.resetCommandPool(ctx.logical_device, self.gfx_pipeline.command_pools[image_index], .{});
    try self.recordCommandBuffer(ctx, image_index);

    const stage_masks = [_]vk.PipelineStageFlags{
        .{ .fragment_shader_bit = true },
        .{ .color_attachment_output_bit = true },
    };
    const wait_semaphores = [stage_masks.len]vk.Semaphore{
        ray_tracing_pipeline_complete_semaphore,
        self.present_complete_semaphore,
    };
    const render_submit_info = vk.SubmitInfo{
        .wait_semaphore_count = wait_semaphores.len,
        .p_wait_semaphores = &wait_semaphores,
        .p_wait_dst_stage_mask = &stage_masks,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&self.gfx_pipeline.command_buffers[image_index]),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&self.render_complete_semaphore),
    };

    try ctx.vkd.queueSubmit(
        ctx.graphics_queue,
        1,
        @as([*]const vk.SubmitInfo, @ptrCast(&render_submit_info)),
        self.render_complete_fence,
    );

    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @as([*]const vk.Semaphore, @ptrCast(&self.render_complete_semaphore)),
        .swapchain_count = 1,
        .p_swapchains = @as([*]const vk.SwapchainKHR, @ptrCast(&self.swapchain.swapchain)),
        .p_image_indices = @as([*]const u32, @ptrCast(&image_index)),
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

    // transfer any pending transfers
    try self.staging_buffers.flush(ctx);
}

pub fn setDenoiseSampleCount(self: *Pipeline, sample_count: i32) void {
    const zone = tracy.ZoneN(@src(), @typeName(Pipeline) ++ " " ++ @src().fn_name);
    defer zone.End();
    self.gfx_pipeline.shader_constants.samples = sample_count;
}

pub fn setDenoiseDistributionBias(self: *Pipeline, distribution_bias: f32) void {
    const zone = tracy.ZoneN(@src(), @typeName(Pipeline) ++ " " ++ @src().fn_name);
    defer zone.End();
    self.gfx_pipeline.shader_constants.distribution_bias = distribution_bias;
}

pub fn setDenoiseInverseHueTolerance(self: *Pipeline, inverse_hue_tolerance: f32) void {
    const zone = tracy.ZoneN(@src(), @typeName(Pipeline) ++ " " ++ @src().fn_name);
    defer zone.End();
    self.gfx_pipeline.shader_constants.inverse_hue_tolerance = inverse_hue_tolerance;
}

pub fn setDenoisePixelMultiplier(self: *Pipeline, pixel_multiplier: f32) void {
    const zone = tracy.ZoneN(@src(), @typeName(Pipeline) ++ " " ++ @src().fn_name);
    defer zone.End();
    self.gfx_pipeline.shader_constants.pixel_multiplier = pixel_multiplier;
}

/// Flush the current ray_device_resource brick grid state to the GPU
pub fn transferCurrentBrickGridState(self: *Pipeline, ctx: Context) !void {
    const zone = tracy.ZoneN(@src(), @typeName(Pipeline) ++ " " ++ @src().fn_name);
    defer zone.End();
    try self.staging_buffers.transferToBuffer(
        ctx,
        &self.ray_device_resources.voxel_scene_buffer,
        0,
        ray_pipeline_types.BrickGridMetadata,
        &[1]ray_pipeline_types.BrickGridMetadata{self.ray_device_resources.host_brick_state.grid_metadata},
    );
}

// TODO: make allow to multithread this
/// Used to update the pipeline according to changes in the window spec
/// This functions should only be called from the main thread (see glfwGetFramebufferSize)
fn rescalePipeline(self: *Pipeline, ctx: Context) !void {
    const zone = tracy.ZoneN(@src(), @typeName(Pipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    var window_size = ctx.window_ptr.*.getFramebufferSize();
    if (window_size.width == 0 or window_size.height == 0) {
        window_size = ctx.window_ptr.*.getFramebufferSize();
        glfw.waitEvents();
    }

    self.requested_rescale_pipeline = false;

    // // Wait for pipeline to become idle
    // {
    //     _ = ctx.vkd.waitForFences(
    //         ctx.logical_device,
    //         1,
    //         @ptrCast([*]vk.Fence, &self.compute_pipeline.complete_fence),
    //         vk.TRUE,
    //         std.math.maxInt(u64),
    //     ) catch |err| std.debug.print("failed to wait for compute fences, err: {any}", .{err});
    //     // wait for previous texture draw before updating buffers and command buffers
    //     _ = try ctx.vkd.waitForFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.render_complete_fence), vk.TRUE, std.math.maxInt(u64));
    // }

    // recreate swapchain utilizing the old one
    const old_swapchain = self.swapchain;
    defer old_swapchain.deinit(ctx);

    self.swapchain = try render.swapchain.Data.init(self.allocator, ctx, self.init_command_pool, old_swapchain.swapchain);
    errdefer self.swapchain.deinit(ctx);

    // recreate renderpass
    ctx.destroyRenderPass(self.render_pass);
    self.render_pass = try ctx.createRenderPass(self.swapchain.format);
    errdefer ctx.destroyRenderPass(self.render_pass);

    // recreate framebuffers
    for (self.gfx_pipeline.framebuffers) |framebuffer| {
        ctx.vkd.destroyFramebuffer(ctx.logical_device, framebuffer, null);
    }
    self.gfx_pipeline.framebuffers = try render.pipeline.createFramebuffers(self.allocator, ctx, &self.swapchain, self.render_pass, self.gfx_pipeline.framebuffers);
    errdefer {
        for (self.gfx_pipeline.framebuffers) |buffer| {
            ctx.vkd.destroyFramebuffer(ctx.logical_device, buffer, null);
        }
        self.allocator.free(self.gfx_pipeline.framebuffers);
    }

    self.gui.handleRescale(@as(f32, @floatFromInt(window_size.width)), @as(f32, @floatFromInt(window_size.height)));
}

/// prepare gfx_pipeline + imgui_pipeline command buffer
fn recordCommandBuffers(self: Pipeline, ctx: Context) !void {
    const zone = tracy.ZoneN(@src(), @typeName(Pipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    // copy begin info
    for (0..self.gfx_pipeline.command_buffers.len) |i| {
        try self.recordCommandBuffer(ctx, i);
    }
}

// TODO: properly handling of errors
fn recordCommandBuffer(self: Pipeline, ctx: Context, index: usize) !void {
    const zone = tracy.ZoneN(@src(), @typeName(Pipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

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
        @as([*]const vk.ImageMemoryBarrier, @ptrCast(&image_barrier)),
    );

    const render_pass_begin_info = vk.RenderPassBeginInfo{
        .render_pass = self.render_pass,
        .framebuffer = self.gfx_pipeline.framebuffers[index],
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain.extent,
        },
        .clear_value_count = 0,
        .p_clear_values = undefined,
    };
    ctx.vkd.cmdBeginRenderPass(command_buffer, &render_pass_begin_info, .@"inline");

    {
        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @as(f32, @floatFromInt(self.swapchain.extent.width)),
            .height = @as(f32, @floatFromInt(self.swapchain.extent.height)),
            .min_depth = 0,
            .max_depth = 1,
        };
        ctx.vkd.cmdSetViewport(
            command_buffer,
            0,
            1,
            @as([*]const vk.Viewport, @ptrCast(&viewport)),
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
        ctx.vkd.cmdSetScissor(command_buffer, 0, 1, @as([*]const vk.Rect2D, @ptrCast(&scissor)));
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
        @as([*]const vk.DescriptorSet, @ptrCast(&self.gfx_pipeline.descriptor_set)),
        0,
        undefined,
    );
    ctx.vkd.cmdBindPipeline(command_buffer, .graphics, self.gfx_pipeline.pipeline);
    ctx.vkd.cmdBindVertexBuffers(
        command_buffer,
        0,
        1,
        @as([*]const vk.Buffer, @ptrCast(&self.vertex_index_buffer.buffer)),
        &vertex_zero_offset,
    );
    ctx.vkd.cmdBindIndexBuffer(command_buffer, self.vertex_index_buffer.buffer, GraphicsPipeline.vertex_size, .uint16);
    ctx.vkd.cmdDrawIndexed(command_buffer, GraphicsPipeline.indices.len, 1, 0, 0, 0);

    try self.imgui_pipeline.recordCommandBuffer(
        ctx,
        command_buffer,
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
const vertex_zero_offset = [_]vk.DeviceSize{0};
