const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const vk = @import("vulkan");
const glfw = @import("glfw");

const utils = @import("../utils.zig");

const render = @import("../render.zig");
const constants = render.consts;
const swapchain = render.swapchain;
const vertex = render.vertex;
const descriptor = render.descriptor;
const dispatch = render.dispatch;

const GpuBufferMemory = render.GpuBufferMemory;
const Texture = render.Texture;
const Context = render.Context;

pub const RecordCmdBufferError = dispatch.BeginCommandBufferError;

const Pipeline = @This();

const PipeType = enum(usize) {
    sprite = 0,
};
const pipe_type_count = @typeInfo(PipeType).Enum.fields.len;

allocator: Allocator,

render_pass: vk.RenderPass,
pipeline_layout: vk.PipelineLayout,
pipelines: [pipe_type_count]vk.Pipeline,
framebuffers: []vk.Framebuffer,

// TODO: command buffers should be according to what we draw, and not directly related to pipeline?
command_buffers: []vk.CommandBuffer,

image_available_s: []vk.Semaphore,
renderer_finished_s: []vk.Semaphore,
in_flight_fences: []vk.Fence,
images_in_flight: []vk.Fence,

requested_rescale_pipeline: bool = false,

// TODO seperate vertex/index buffers from pipeline
vertex_buffer: GpuBufferMemory,
indices_buffer: GpuBufferMemory,

sc_data: *swapchain.Data,
view: *swapchain.ViewportScissor,

sync_descript: *descriptor.SyncDescriptor,

instance_count: u32,

pub fn init(
    allocator: Allocator,
    ctx: Context,
    sc_data: *swapchain.Data,
    instance_count: u32,
    view: *swapchain.ViewportScissor,
    sync_descript: *descriptor.SyncDescriptor,
) !Pipeline {
    const pipeline_layout = blk: {
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &sync_descript.ubo.descriptor_set_layout),
            .push_constant_range_count = 0,
            .p_push_constant_ranges = undefined,
        };
        break :blk try ctx.createPipelineLayout(pipeline_layout_info);
    };
    const render_pass = try ctx.createRenderPass(sc_data.format);

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    var pipelines: [pipe_type_count]vk.Pipeline = undefined;
    comptime std.debug.assert(pipe_type_count == 1); // code needs to be modified if pipeline type enum is changed!

    try definePipeline(
        allocator,
        ctx,
        exe_path,
        view,
        pipeline_layout,
        render_pass,
        "../../render2d_sprite.vert.spv",
        "../../render2d_common.frag.spv",
        &pipelines[0],
    );

    const framebuffers = try render.pipeline.createFramebuffers(allocator, ctx, sc_data, render_pass, null);
    errdefer allocator.free(framebuffers);

    const vertex_buffer = try vertex.createDefaultVertexBuffer(ctx, ctx.gfx_cmd_pool);
    errdefer vertex_buffer.deinit(ctx);

    const indices_buffer = try vertex.createDefaultIndicesBuffer(ctx, ctx.gfx_cmd_pool);
    errdefer indices_buffer.deinit(ctx);

    const command_buffers = try render.pipeline.createCmdBuffers(allocator, ctx, ctx.gfx_cmd_pool, framebuffers.len, null);
    errdefer allocator.free(command_buffers);

    const images_in_flight = blk: {
        var images_in_flight = try allocator.alloc(vk.Fence, sc_data.images.len);
        var i: usize = 0;
        while (i < images_in_flight.len) : (i += 1) {
            images_in_flight[i] = .null_handle;
        }
        break :blk images_in_flight;
    };
    errdefer allocator.free(images_in_flight);

    const image_available_s = try allocator.alloc(vk.Semaphore, constants.max_frames_in_flight);
    errdefer allocator.free(image_available_s);

    const renderer_finished_s = try allocator.alloc(vk.Semaphore, constants.max_frames_in_flight);
    errdefer allocator.free(renderer_finished_s);

    const in_flight_fences = try allocator.alloc(vk.Fence, constants.max_frames_in_flight);
    errdefer allocator.free(in_flight_fences);

    const semaphore_info = vk.SemaphoreCreateInfo{
        .flags = .{},
    };
    const fence_info = vk.FenceCreateInfo{
        .flags = .{
            .signaled_bit = true,
        },
    };
    {
        var i: usize = 0;
        while (i < constants.max_frames_in_flight) : (i += 1) {
            const image_sem = try ctx.vkd.createSemaphore(ctx.logical_device, &semaphore_info, null);
            image_available_s[i] = image_sem;

            const finish_sem = try ctx.vkd.createSemaphore(ctx.logical_device, &semaphore_info, null);
            renderer_finished_s[i] = finish_sem;

            const fence = try ctx.vkd.createFence(ctx.logical_device, &fence_info, null);
            in_flight_fences[i] = fence;
        }
    }

    var pipeline = Pipeline{
        .allocator = allocator,
        .view = view,
        .render_pass = render_pass,
        .pipeline_layout = pipeline_layout,
        .pipelines = pipelines,
        .framebuffers = framebuffers,
        .command_buffers = command_buffers,
        .image_available_s = image_available_s,
        .renderer_finished_s = renderer_finished_s,
        .in_flight_fences = in_flight_fences,
        .images_in_flight = images_in_flight,
        .vertex_buffer = vertex_buffer,
        .indices_buffer = indices_buffer,
        .sc_data = sc_data,
        .sync_descript = sync_descript,
        .instance_count = instance_count,
    };
    try recordCmdBuffers(ctx, &pipeline);
    return pipeline;
}

/// Draw using pipeline
/// transfer_fn can be used to update any relevant storage buffers or other data that are timing critical according to rendering
pub fn draw(self: *Pipeline, ctx: Context, comptime transfer_fn: fn (image_index: usize, user_ctx: anytype) void, user_ctx: anytype) !void {
    const state = struct {
        var current_frame: usize = 0;
    };
    const max_u64 = std.math.maxInt(u64);

    const in_flight_fence_p = @ptrCast([*]const vk.Fence, &self.in_flight_fences[state.current_frame]);
    _ = try ctx.vkd.waitForFences(ctx.logical_device, 1, in_flight_fence_p, vk.TRUE, max_u64);

    var image_index: u32 = undefined;
    if (ctx.vkd.acquireNextImageKHR(ctx.logical_device, self.sc_data.swapchain, max_u64, self.image_available_s[state.current_frame], .null_handle)) |ok| switch (ok.result) {
        .success => {
            image_index = ok.image_index;
        },
        .suboptimal_khr => {
            self.requested_rescale_pipeline = true;
            image_index = ok.image_index;
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

    if (self.images_in_flight[image_index] != .null_handle) {
        const p_fence = @ptrCast([*]const vk.Fence, &self.images_in_flight[image_index]);
        _ = try ctx.vkd.waitForFences(ctx.logical_device, 1, p_fence, vk.TRUE, max_u64);
    }
    self.images_in_flight[image_index] = self.in_flight_fences[state.current_frame];

    // if ubo is dirty
    if (self.sync_descript.ubo.is_dirty[image_index]) {
        // transfer data to gpu
        var ubo_arr = [_]descriptor.Uniform{self.sync_descript.ubo.uniform_data};
        // TODO: only transfer dirty part of data
        try self.sync_descript.ubo.uniform_buffers[image_index].transferToDevice(ctx, descriptor.Uniform, 0, ubo_arr[0..]);
        self.sync_descript.ubo.is_dirty[image_index] = false;
    }

    transfer_fn(image_index, user_ctx);

    const wait_stages = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &self.image_available_s[state.current_frame]),
        .p_wait_dst_stage_mask = @ptrCast([*]const vk.PipelineStageFlags, &wait_stages),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.command_buffers[image_index]),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast([*]const vk.Semaphore, &self.renderer_finished_s[state.current_frame]),
    };
    const p_submit_info = @ptrCast([*]const vk.SubmitInfo, &submit_info);
    _ = try ctx.vkd.resetFences(ctx.logical_device, 1, in_flight_fence_p);
    try ctx.vkd.queueSubmit(ctx.graphics_queue, 1, p_submit_info, self.in_flight_fences[state.current_frame]);

    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &self.renderer_finished_s[state.current_frame]),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast([*]const vk.SwapchainKHR, &self.sc_data.swapchain),
        .p_image_indices = @ptrCast([*]const u32, &image_index),
        .p_results = null,
    };
    if (ctx.vkd.queuePresentKHR(ctx.present_queue, &present_info)) |_| {
        // TODO:
    } else |_| {
        // TODO:
    }

    if (self.requested_rescale_pipeline == true) {
        try self.rescalePipeline(self.allocator, ctx);
    }

    state.current_frame = (state.current_frame + 1) % constants.max_frames_in_flight;
}

/// Used to update the pipeline according to changes in the window spec
/// This functions should only be called from the main thread (see glfwGetFramebufferSize)
fn rescalePipeline(self: *Pipeline, allocator: Allocator, ctx: Context) !void {
    var window_size = try ctx.window_ptr.*.getFramebufferSize();
    while (window_size.width == 0 or window_size.height == 0) {
        window_size = try ctx.window_ptr.*.getFramebufferSize();
        try glfw.waitEvents();
    }

    self.requested_rescale_pipeline = false;
    // TODO: swapchain can be recreated without waiting and so waiting in the top of the
    //       functions is wasteful
    // Wait for pipeline to become idle
    self.wait_idle(ctx);

    // destroy outdated pipeline state
    for (self.framebuffers) |framebuffer| {
        ctx.vkd.destroyFramebuffer(ctx.logical_device, framebuffer, null);
    }
    ctx.vkd.freeCommandBuffers(ctx.logical_device, ctx.gfx_cmd_pool, @intCast(u32, self.command_buffers.len), @ptrCast([*]const vk.CommandBuffer, self.command_buffers.ptr));
    ctx.destroyRenderPass(self.render_pass);

    // recreate swapchain utilizing the old one
    const old_swapchain = self.sc_data.*;
    self.sc_data.* = swapchain.Data.init(self.allocator, ctx, old_swapchain.swapchain) catch |err| {
        std.debug.panic("failed to resize swapchain, err {any}", .{err}) catch unreachable;
    };
    old_swapchain.deinit(ctx);

    // recreate view from swapchain extent
    self.view.* = swapchain.ViewportScissor.init(self.sc_data.*.extent);

    // recreate renderpass and framebuffers
    self.render_pass = try ctx.createRenderPass(self.sc_data.format);
    self.framebuffers = try render.pipeline.createFramebuffers(allocator, ctx, self.sc_data, self.render_pass, self.framebuffers);

    self.command_buffers = try render.pipeline.createCmdBuffers(allocator, ctx, ctx.gfx_cmd_pool, self.framebuffers.len, self.command_buffers);
    try recordCmdBuffers(ctx, self);
}

pub fn deinit(self: *Pipeline, ctx: Context) void {
    self.wait_idle(ctx);
    {
        var i: usize = 0;
        while (i < constants.max_frames_in_flight) : (i += 1) {
            ctx.vkd.destroySemaphore(ctx.logical_device, self.image_available_s[i], null);
            ctx.vkd.destroySemaphore(ctx.logical_device, self.renderer_finished_s[i], null);
            ctx.vkd.destroyFence(ctx.logical_device, self.in_flight_fences[i], null);
        }
    }

    self.vertex_buffer.deinit(ctx);
    self.indices_buffer.deinit(ctx);

    self.allocator.free(self.image_available_s);
    self.allocator.free(self.renderer_finished_s);
    self.allocator.free(self.in_flight_fences);
    self.allocator.free(self.images_in_flight);

    self.allocator.free(self.command_buffers);

    for (self.framebuffers) |framebuffer| {
        ctx.vkd.destroyFramebuffer(ctx.logical_device, framebuffer, null);
    }
    self.allocator.free(self.framebuffers);

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyRenderPass(self.render_pass);

    for (self.pipelines) |*pipeline| {
        ctx.destroyPipeline(pipeline);
    }
}

inline fn wait_idle(self: Pipeline, ctx: Context) void {
    _ = ctx.vkd.waitForFences(ctx.logical_device, @intCast(u32, self.in_flight_fences.len), self.in_flight_fences.ptr, vk.TRUE, std.math.maxInt(u64)) catch |err| {
        std.io.getStdErr().writer().print("waiting for fence failed: {}", .{err}) catch |e| switch (e) {
            else => {}, // Discard print errors
        };
    };
}

/// record commands for the pipeline
inline fn recordCmdBuffers(ctx: render.Context, pipeline: *Pipeline) dispatch.BeginCommandBufferError!void {
    const image = pipeline.sync_descript.ubo.my_texture.image;
    const image_use = render.Texture.getImageTransitionBarrier(image, .general, .general);
    const clear_color = [_]vk.ClearColorValue{
        .{
            .float_32 = [_]f32{ 0.0, 0.0, 0.0, 1.0 },
        },
    };
    for (pipeline.command_buffers) |command_buffer, i| {
        const command_begin_info = vk.CommandBufferBeginInfo{
            .flags = .{},
            .p_inheritance_info = null,
        };
        try ctx.vkd.beginCommandBuffer(command_buffer, &command_begin_info);

        // make sure compute shader complet writer before beginning render pass
        ctx.vkd.cmdPipelineBarrier(command_buffer, image_use.transition.src_stage, image_use.transition.dst_stage, vk.DependencyFlags{}, 0, undefined, 0, undefined, 1, @ptrCast([*]const vk.ImageMemoryBarrier, &image_use.barrier));
        const render_begin_info = vk.RenderPassBeginInfo{
            .render_pass = pipeline.render_pass,
            .framebuffer = pipeline.framebuffers[i],
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = pipeline.sc_data.extent },
            .clear_value_count = clear_color.len,
            .p_clear_values = @ptrCast([*]const vk.ClearValue, &clear_color),
        };
        ctx.vkd.cmdSetViewport(command_buffer, 0, pipeline.view.viewport.len, &pipeline.view.viewport);
        ctx.vkd.cmdSetScissor(command_buffer, 0, pipeline.view.scissor.len, &pipeline.view.scissor);
        ctx.vkd.cmdBindPipeline(command_buffer, vk.PipelineBindPoint.graphics, pipeline.pipelines[0]);
        ctx.vkd.cmdBeginRenderPass(command_buffer, &render_begin_info, vk.SubpassContents.@"inline");

        const buffer_offsets = [_]vk.DeviceSize{0};
        ctx.vkd.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast([*]const vk.Buffer, &pipeline.vertex_buffer.buffer), @ptrCast([*]const vk.DeviceSize, &buffer_offsets));
        ctx.vkd.cmdBindIndexBuffer(command_buffer, pipeline.indices_buffer.buffer, 0, .uint32);
        // TODO: Race Condition: sync_descript is not synced here
        ctx.vkd.cmdBindDescriptorSets(command_buffer, .graphics, pipeline.pipeline_layout, 0, 1, @ptrCast([*]const vk.DescriptorSet, &pipeline.sync_descript.ubo.descriptor_sets[i]), 0, undefined);

        ctx.vkd.cmdDrawIndexed(command_buffer, pipeline.indices_buffer.len, pipeline.instance_count, 0, 0, 0);
        ctx.vkd.cmdEndRenderPass(command_buffer);
        try ctx.vkd.endCommandBuffer(command_buffer);
    }
}

inline fn definePipeline(
    allocator: Allocator,
    ctx: Context,
    exe_path: []const u8,
    view: *swapchain.ViewportScissor,
    layout: vk.PipelineLayout,
    render_pass: vk.RenderPass,
    vert_shader_path: []const u8,
    frag_shader_path: []const u8,
    pipeline: *vk.Pipeline,
) !void {
    const vert_stage = blk: {
        const vert_code = blk1: {
            const path = blk2: {
                const join_path = [_][]const u8{ exe_path, vert_shader_path };
                break :blk2 try std.fs.path.resolve(allocator, join_path[0..]);
            };
            defer allocator.destroy(path.ptr);

            break :blk1 try utils.readFile(allocator, path);
        };
        defer vert_code.deinit();
        const vert_module = try ctx.createShaderModule(vert_code.items[0..]);
        break :blk vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = .{ .vertex_bit = true },
            .module = vert_module,
            .p_name = "main",
            .p_specialization_info = null,
        };
    };
    defer ctx.destroyShaderModule(vert_stage.module);

    const frag_stage = blk: {
        const frag_code = blk1: {
            const path = blk2: {
                const join_path = [_][]const u8{ exe_path, frag_shader_path };
                break :blk2 try std.fs.path.resolve(allocator, join_path[0..]);
            };
            defer allocator.destroy(path.ptr);

            break :blk1 try utils.readFile(allocator, path);
        };
        defer frag_code.deinit();

        const frag_module = try ctx.createShaderModule(frag_code.items[0..]);
        break :blk vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = .{ .fragment_bit = true },
            .module = frag_module,
            .p_name = "main",
            .p_specialization_info = null,
        };
    };
    defer ctx.destroyShaderModule(frag_stage.module);

    const shader_stages_info = [_]vk.PipelineShaderStageCreateInfo{ vert_stage, frag_stage };

    const binding_desription = vertex.getBindingDescriptors();
    const attrib_desriptions = vertex.getAttribureDescriptions();
    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = binding_desription.len,
        .p_vertex_binding_descriptions = &binding_desription,
        .vertex_attribute_description_count = attrib_desriptions.len,
        .p_vertex_attribute_descriptions = &attrib_desriptions,
    };
    const input_assembley_info = vk.PipelineInputAssemblyStateCreateInfo{
        .flags = .{},
        .topology = vk.PrimitiveTopology.triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    const viewport_info = vk.PipelineViewportStateCreateInfo{
        .flags = .{},
        .viewport_count = view.viewport.len,
        .p_viewports = @ptrCast(?[*]const vk.Viewport, &view.viewport),
        .scissor_count = view.scissor.len,
        .p_scissors = @ptrCast(?[*]const vk.Rect2D, &view.scissor),
    };
    const rasterizer_info = vk.PipelineRasterizationStateCreateInfo{
        .flags = .{},
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = false }, // we should not need culling since we are currently rendering 2D
        .front_face = .counter_clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_slope_factor = 0.0,
        .line_width = 1.0,
    };
    const multisample_info = vk.PipelineMultisampleStateCreateInfo{
        .flags = .{},
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 1.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };
    const color_blend_attachments = [_]vk.PipelineColorBlendAttachmentState{
        .{
            .blend_enable = vk.TRUE,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        },
    };
    const color_blend_state = vk.PipelineColorBlendStateCreateInfo{
        .flags = .{},
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = color_blend_attachments.len,
        .p_attachments = @ptrCast([*]const vk.PipelineColorBlendAttachmentState, &color_blend_attachments),
        .blend_constants = [_]f32{0.0} ** 4,
    };
    const dynamic_states = [_]vk.DynamicState{
        .viewport,
        .scissor,
    };
    const dynamic_state_info = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = @ptrCast([*]const vk.DynamicState, &dynamic_states),
    };
    const pipeline_info = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = shader_stages_info.len,
        .p_stages = @ptrCast([*]const vk.PipelineShaderStageCreateInfo, &shader_stages_info),
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembley_info,
        .p_tessellation_state = null,
        .p_viewport_state = &viewport_info,
        .p_rasterization_state = &rasterizer_info,
        .p_multisample_state = &multisample_info,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &color_blend_state,
        .p_dynamic_state = &dynamic_state_info,
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };
    pipeline.* = try ctx.createGraphicsPipeline(pipeline_info);
}
