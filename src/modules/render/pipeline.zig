const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const vk = @import("vulkan");
const glfw = @import("glfw");

const constants = @import("consts.zig");
const swapchain = @import("swapchain.zig");
const vertex = @import("vertex.zig");
const descriptor = @import("descriptor.zig");
const utils = @import("../utils.zig");
const dispatch = @import("dispatch.zig");

const GpuBufferMemory = @import("GpuBufferMemory.zig");
const Texture = @import("Texture.zig");
const Context = @import("Context.zig");

pub const RecordCmdBufferError = dispatch.BeginCommandBufferError;
pub const PipelineBuildError = error{
    MissingPipelines,
};

pub fn PipelineTypesFn(comptime RecordCommandUserDataType: type) type {
    const T = RecordCommandUserDataType;
    return struct {
        const ParentType = @This();

        pub const PipelineBuilder = struct {
            allocator: Allocator,
            ctx: Context,
            sc_data: *swapchain.Data,
            instance_count: u32,
            view: *swapchain.ViewportScissor,
            sync_descript: *descriptor.SyncDescriptor,
            render_pass: vk.RenderPass,
            pipeline_layout: vk.PipelineLayout,
            user_data: T,
            recordCmdBufferFn: fn (ctx: Context, pipeline: *ParentType.Pipeline) RecordCmdBufferError!void,

            // intermediate builder state
            pipelines: ArrayList(vk.Pipeline),
            exe_path: ?[]u8,

            pub fn init(
                allocator: Allocator,
                ctx: Context,
                sc_data: *swapchain.Data,
                instance_count: u32,
                view: *swapchain.ViewportScissor,
                sync_descript: *descriptor.SyncDescriptor,
                user_data: T,
                recordCmdBufferFn: fn (ctx: Context, pipeline: *ParentType.Pipeline) RecordCmdBufferError!void,
            ) !PipelineBuilder {
                // TODO: should be from addPipeline
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

                return PipelineBuilder{
                    .allocator = allocator,
                    .ctx = ctx,
                    .sc_data = sc_data,
                    .instance_count = instance_count,
                    .view = view,
                    .sync_descript = sync_descript,
                    .render_pass = render_pass,
                    .pipeline_layout = pipeline_layout,
                    .user_data = user_data,
                    .recordCmdBufferFn = recordCmdBufferFn,
                    .pipelines = ArrayList(vk.Pipeline).init(allocator),
                    .exe_path = null,
                };
            }

            pub fn addPipeline(self: *PipelineBuilder, vert_shader_path: []const u8, frag_shader_path: []const u8) !void {
                self.exe_path = self.exe_path orelse (try std.fs.selfExePathAlloc(self.allocator));

                // TODO: function in context for shader stage creation?
                const vert_code = blk1: {
                    const path = blk2: {
                        const join_path = [_][]const u8{ self.exe_path.?, vert_shader_path };
                        break :blk2 try std.fs.path.resolve(self.allocator, join_path[0..]);
                    };
                    defer self.allocator.destroy(path.ptr);

                    break :blk1 try utils.readFile(self.allocator, path);
                };
                defer vert_code.deinit();

                const vert_module = try self.ctx.createShaderModule(vert_code.items[0..]);
                defer self.ctx.destroyShaderModule(vert_module);

                const vert_stage = vk.PipelineShaderStageCreateInfo{ .flags = .{}, .stage = .{ .vertex_bit = true }, .module = vert_module, .p_name = "main", .p_specialization_info = null };
                const frag_code = blk1: {
                    const path = blk2: {
                        const join_path = [_][]const u8{ self.exe_path.?, frag_shader_path };
                        break :blk2 try std.fs.path.resolve(self.allocator, join_path[0..]);
                    };
                    defer self.allocator.destroy(path.ptr);

                    break :blk1 try utils.readFile(self.allocator, path);
                };
                defer frag_code.deinit();

                const frag_module = try self.ctx.createShaderModule(frag_code.items[0..]);
                defer self.ctx.destroyShaderModule(frag_module);

                const frag_stage = vk.PipelineShaderStageCreateInfo{ .flags = .{}, .stage = .{ .fragment_bit = true }, .module = frag_module, .p_name = "main", .p_specialization_info = null };
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
                    .viewport_count = self.view.viewport.len,
                    .p_viewports = @ptrCast(?[*]const vk.Viewport, &self.view.viewport),
                    .scissor_count = self.view.scissor.len,
                    .p_scissors = @ptrCast(?[*]const vk.Rect2D, &self.view.scissor),
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
                    .layout = self.pipeline_layout,
                    .render_pass = self.render_pass,
                    .subpass = 0,
                    .base_pipeline_handle = .null_handle,
                    .base_pipeline_index = -1,
                };
                const pipeline = try self.ctx.createGraphicsPipeline(pipeline_info);
                try self.pipelines.append(pipeline);
            }

            // TODO: correctness if build fail, clean up resources created with errdefer
            /// initialize a graphics pipe line, caller must make sure to call deinit
            /// sc_data, view and ubo needs a lifetime that is atleast as long as created pipeline
            pub fn build(self: *PipelineBuilder) !ParentType.Pipeline {
                if (self.pipelines.items.len == 0) {
                    return PipelineBuildError.MissingPipelines; // addPipeline was never called
                }

                self.allocator.destroy(self.exe_path.?.ptr);

                const framebuffers = try createFramebuffers(self.allocator, self.ctx, self.sc_data, self.render_pass, null);
                errdefer self.allocator.free(framebuffers);

                const vertex_buffer = try vertex.createDefaultVertexBuffer(self.ctx, self.ctx.gfx_cmd_pool);
                errdefer vertex_buffer.deinit(self.ctx);

                const indices_buffer = try vertex.createDefaultIndicesBuffer(self.ctx, self.ctx.gfx_cmd_pool);
                errdefer indices_buffer.deinit(self.ctx);

                const command_buffers = try createCmdBuffers(self.allocator, self.ctx, self.ctx.gfx_cmd_pool, framebuffers.len, null);
                errdefer self.allocator.free(command_buffers);

                const images_in_flight = blk: {
                    var images_in_flight = try self.allocator.alloc(vk.Fence, self.sc_data.images.len);
                    var i: usize = 0;
                    while (i < images_in_flight.len) : (i += 1) {
                        images_in_flight[i] = .null_handle;
                    }
                    break :blk images_in_flight;
                };
                errdefer self.allocator.free(images_in_flight);

                const image_available_s = try self.allocator.alloc(vk.Semaphore, constants.max_frames_in_flight);
                errdefer self.allocator.free(image_available_s);

                const renderer_finished_s = try self.allocator.alloc(vk.Semaphore, constants.max_frames_in_flight);
                errdefer self.allocator.free(renderer_finished_s);

                const in_flight_fences = try self.allocator.alloc(vk.Fence, constants.max_frames_in_flight);
                errdefer self.allocator.free(in_flight_fences);

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
                        const image_sem = try self.ctx.vkd.createSemaphore(self.ctx.logical_device, &semaphore_info, null);
                        image_available_s[i] = image_sem;

                        const finish_sem = try self.ctx.vkd.createSemaphore(self.ctx.logical_device, &semaphore_info, null);
                        renderer_finished_s[i] = finish_sem;

                        const fence = try self.ctx.vkd.createFence(self.ctx.logical_device, &fence_info, null);
                        in_flight_fences[i] = fence;
                    }
                }

                var pipeline = Pipeline{
                    .allocator = self.allocator,
                    .view = self.view,
                    .render_pass = self.render_pass,
                    .pipeline_layout = self.pipeline_layout,
                    .pipelines = self.pipelines.toOwnedSlice(),
                    .framebuffers = framebuffers,
                    .command_buffers = command_buffers,
                    .image_available_s = image_available_s,
                    .renderer_finished_s = renderer_finished_s,
                    .in_flight_fences = in_flight_fences,
                    .images_in_flight = images_in_flight,
                    .vertex_buffer = vertex_buffer,
                    .indices_buffer = indices_buffer,
                    .sc_data = self.sc_data,
                    .sync_descript = self.sync_descript,
                    .instance_count = self.instance_count,
                    .user_data = self.user_data,
                    .recordCmdBufferFn = self.recordCmdBufferFn,
                };
                try self.recordCmdBufferFn(self.ctx, &pipeline);
                return pipeline;
            }
        };

        pub const Pipeline = struct {
            const Self = @This();

            allocator: Allocator,

            render_pass: vk.RenderPass,
            pipeline_layout: vk.PipelineLayout,
            pipelines: []vk.Pipeline,
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

            // user data, attach any data to the pipeline
            // this data can be used in recordCmdBufferFn or any
            // other function that accepts pipelines
            user_data: T,
            recordCmdBufferFn: fn (ctx: Context, pipeline: *ParentType.Pipeline) RecordCmdBufferError!void,

            /// Draw using pipeline
            /// transfer_fn can be used to update any relevant storage buffers or other data that are timing critical according to rendering
            pub fn draw(self: *Self, ctx: Context, comptime transfer_fn: fn (image_index: usize, user_ctx: anytype) void, user_ctx: anytype) !void {
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
            fn rescalePipeline(self: *Self, allocator: Allocator, ctx: Context) !void {
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
                self.framebuffers = try createFramebuffers(allocator, ctx, self.sc_data, self.render_pass, self.framebuffers);

                self.command_buffers = try createCmdBuffers(allocator, ctx, ctx.gfx_cmd_pool, self.framebuffers.len, self.command_buffers);
                try self.recordCmdBufferFn(ctx, self);
            }

            pub fn deinit(self: Self, ctx: Context) void {
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
                self.allocator.free(self.pipelines);
            }

            inline fn wait_idle(self: Self, ctx: Context) void {
                _ = ctx.vkd.waitForFences(ctx.logical_device, @intCast(u32, self.in_flight_fences.len), self.in_flight_fences.ptr, vk.TRUE, std.math.maxInt(u64)) catch |err| {
                    std.io.getStdErr().writer().print("waiting for fence failed: {}", .{err}) catch |e| switch (e) {
                        else => {}, // Discard print errors
                    };
                };
            }
        };
    };
}

inline fn createFramebuffers(allocator: Allocator, ctx: Context, swapchain_data: *const swapchain.Data, render_pass: vk.RenderPass, prev_framebuffer: ?[]vk.Framebuffer) ![]vk.Framebuffer {
    const image_views = swapchain_data.image_views;
    var framebuffers = prev_framebuffer orelse try allocator.alloc(vk.Framebuffer, image_views.len);
    for (image_views) |view, i| {
        const attachments = [_]vk.ImageView{
            view,
        };
        const framebuffer_info = vk.FramebufferCreateInfo{
            .flags = .{},
            .render_pass = render_pass,
            .attachment_count = attachments.len,
            .p_attachments = @ptrCast([*]const vk.ImageView, &attachments),
            .width = swapchain_data.extent.width,
            .height = swapchain_data.extent.height,
            .layers = 1,
        };
        const framebuffer = try ctx.vkd.createFramebuffer(ctx.logical_device, &framebuffer_info, null);
        framebuffers[i] = framebuffer;
    }
    return framebuffers;
}

/// create a command buffers with sizeof buffer_count, caller must deinit returned list
inline fn createCmdBuffers(allocator: Allocator, ctx: Context, command_pool: vk.CommandPool, buffer_count: usize, prev_buffer: ?[]vk.CommandBuffer) ![]vk.CommandBuffer {
    var command_buffers = prev_buffer orelse try allocator.alloc(vk.CommandBuffer, buffer_count);
    const alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = vk.CommandBufferLevel.primary,
        .command_buffer_count = @intCast(u32, buffer_count),
    };
    try ctx.vkd.allocateCommandBuffers(ctx.logical_device, &alloc_info, command_buffers.ptr);
    command_buffers.len = buffer_count;

    return command_buffers;
}

/// create a command buffers with sizeof buffer_count, caller must destroy returned buffer with allocator
inline fn createCmdBuffer(ctx: Context, command_pool: vk.CommandPool) !vk.CommandBuffer {
    const alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = vk.CommandBufferLevel.primary,
        .command_buffer_count = @intCast(u32, 1),
    };
    var command_buffer: vk.CommandBuffer = undefined;
    try ctx.vkd.allocateCommandBuffers(ctx.logical_device, &alloc_info, @ptrCast([*]vk.CommandBuffer, &command_buffer));

    return command_buffer;
}

// TODO: at this point pipelines should have their own internal module!

/// compute shader that draws to a target texture
pub const ComputeDrawPipeline = struct {
    // TODO: constant data
    // TODO: explicit binding ..
    pub const StateConfigs = struct {
        uniform_sizes: []const u64,
        storage_sizes: []const u64,
    };

    const Self = @This();

    allocator: Allocator,

    pipeline_layout: vk.PipelineLayout,
    pipeline: *vk.Pipeline,

    in_flight_fence: vk.Fence,
    command_buffer: vk.CommandBuffer,

    // TODO: move this out?
    // compute pipelines *currently* should write to a texture
    target_texture: *Texture,
    target_descriptor_layout: vk.DescriptorSetLayout,
    target_descriptor_pool: vk.DescriptorPool,
    target_descriptor_set: vk.DescriptorSet,

    requested_rescale_pipeline: bool = false,

    uniform_buffers: []GpuBufferMemory,
    storage_buffers: []GpuBufferMemory,

    // TODO: descriptor has a lot of duplicate code with init ...
    // TODO: refactor descriptor stuff to be configurable (loop array of config objects for buffer stuff)
    // TODO: correctness if init fail, clean up resources created with errdefer

    /// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
    /// texture should have a lifetime atleast the length of comptute pipeline
    pub fn init(allocator: Allocator, ctx: Context, shader_path: []const u8, target_texture: *Texture, state_config: StateConfigs) !Self {
        var self: Self = undefined;
        self.allocator = allocator;
        self.target_texture = target_texture;

        // TODO: descriptor set creation: one single for loop for each config instead of one for loop for each type

        // TODO: camera should be a push constant instead!
        const uniform_buffers = try allocator.alloc(GpuBufferMemory, state_config.uniform_sizes.len);
        errdefer allocator.free(uniform_buffers);
        for (state_config.uniform_sizes) |size, i| {
            // TODO: errdefer deinit
            uniform_buffers[i] = try GpuBufferMemory.init(ctx, size, .{ .uniform_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
        }

        const storage_buffers = try allocator.alloc(GpuBufferMemory, state_config.storage_sizes.len);
        errdefer allocator.free(storage_buffers);
        for (state_config.storage_sizes) |size, i| {
            // TODO: errdefer deinit
            storage_buffers[i] = try GpuBufferMemory.init(ctx, size, .{ .storage_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
        }

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
                .p_set_layouts = @ptrCast([*]vk.DescriptorSetLayout, &self.target_descriptor_layout),
            };
            try ctx.vkd.allocateDescriptorSets(ctx.logical_device, &descriptor_set_alloc_info, @ptrCast([*]vk.DescriptorSet, &self.target_descriptor_set));
        }

        {
            const buffer_infos = try allocator.alloc(vk.DescriptorBufferInfo, set_count - 1);
            defer allocator.free(buffer_infos);
            const write_descriptor_sets = try allocator.alloc(vk.WriteDescriptorSet, set_count);
            defer allocator.free(write_descriptor_sets);

            const image_info = vk.DescriptorImageInfo{
                .sampler = self.target_texture.sampler,
                .image_view = self.target_texture.image_view,
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
                    .buffer = uniform_buffers[i].buffer,
                    .offset = 0,
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
                    .buffer = storage_buffers[i].buffer,
                    .offset = 0,
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

            // zig fmt: off
            ctx.vkd.updateDescriptorSets(
                ctx.logical_device, 
                @intCast(u32, write_descriptor_sets.len), 
                @ptrCast([*]const vk.WriteDescriptorSet, write_descriptor_sets.ptr),
                0,
                undefined
            );
            // zig fmt: on
        }

        self.pipeline_layout = blk: {
            const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = 1, // TODO: see GfxPipeline
                .p_set_layouts = @ptrCast([*]vk.DescriptorSetLayout, &self.target_descriptor_layout),
                .push_constant_range_count = 0,
                .p_push_constant_ranges = undefined,
            };
            break :blk try ctx.createPipelineLayout(pipeline_layout_info);
        };
        self.pipeline = blk: {
            const self_path = try std.fs.selfExePathAlloc(allocator);
            defer ctx.allocator.destroy(self_path.ptr);

            const code = blk1: {
                const path = blk2: {
                    const join_path = [_][]const u8{ self_path, shader_path };
                    break :blk2 try std.fs.path.resolve(allocator, join_path[0..]);
                };
                defer allocator.destroy(path.ptr);

                break :blk1 try utils.readFile(allocator, path);
            };
            defer code.deinit();

            const module = try ctx.createShaderModule(code.items[0..]);
            defer ctx.destroyShaderModule(module);

            const stage = vk.PipelineShaderStageCreateInfo{ .flags = .{}, .stage = .{ .compute_bit = true }, .module = module, .p_name = "main", .p_specialization_info = null };

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

        const fence_info = vk.FenceCreateInfo{
            .flags = .{
                .signaled_bit = true,
            },
        };
        self.in_flight_fence = try ctx.vkd.createFence(ctx.logical_device, &fence_info, null);

        // TODO: we need to rescale pipeline dispatch
        self.command_buffer = try createCmdBuffer(ctx, ctx.comp_cmd_pool);
        errdefer ctx.vkd.freeCommandBuffers(ctx.logical_device, ctx.comp_cmd_pool, 1, @ptrCast([*]vk.CommandBuffer, &self.command_buffer));

        try self.recordCommands(ctx);

        // zig fmt: off
        return Self{ 
            .allocator = self.allocator, 
            .pipeline_layout = self.pipeline_layout, 
            .pipeline = self.pipeline, 
            .in_flight_fence = self.in_flight_fence, 
            .command_buffer = self.command_buffer, 
            .target_texture = self.target_texture, 
            .target_descriptor_layout = self.target_descriptor_layout, 
            .target_descriptor_pool = self.target_descriptor_pool, 
            .target_descriptor_set = self.target_descriptor_set, 
            .uniform_buffers = uniform_buffers,
            .storage_buffers = storage_buffers,
        };
        // zig fmt: on
    }

    // TODO: sync
    pub fn compute(self: Self, ctx: Context) !void {
        self.wait_idle(ctx);

        const wait_stages = vk.PipelineStageFlags{ .compute_shader_bit = true };
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = @ptrCast([*]const vk.PipelineStageFlags, &wait_stages),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        };
        const p_submit_info = @ptrCast([*]const vk.SubmitInfo, &submit_info);
        _ = try ctx.vkd.resetFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.in_flight_fence));
        try ctx.vkd.queueSubmit(
            ctx.compute_queue,
            1,
            p_submit_info,
            self.in_flight_fence,
        );
    }

    /// Used to update the pipeline according to changes in the window spec
    /// This functions should only be called from the main thread (see glfwGetFramebufferSize)
    fn rescalePipeline(self: *Self, ctx: Context) !void {
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

        ctx.vkd.freeCommandBuffers(ctx.logical_device, ctx.comp_cmd_pool, 1, @ptrCast([*]const vk.CommandBuffer, &self.command_buffer));

        self.command_buffer = try createCmdBuffer(ctx, ctx.comp_cmd_pool);

        try self.recordCommands(ctx);
    }

    pub fn deinit(self: Self, ctx: Context) void {
        self.wait_idle(ctx);

        ctx.vkd.destroyFence(ctx.logical_device, self.in_flight_fence, null);

        for (self.uniform_buffers) |buffer| {
            buffer.deinit(ctx);
        }
        self.allocator.free(self.uniform_buffers);
        for (self.storage_buffers) |buffer| {
            buffer.deinit(ctx);
        }
        self.allocator.free(self.storage_buffers);

        ctx.vkd.freeCommandBuffers(ctx.logical_device, ctx.comp_cmd_pool, 1, @ptrCast([*]const vk.CommandBuffer, &self.command_buffer));
        ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.target_descriptor_layout, null);
        ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

        ctx.destroyPipelineLayout(self.pipeline_layout);
        ctx.destroyPipeline(self.pipeline);

        self.allocator.destroy(self.pipeline);
    }

    /// Wait for fence to signal complete 
    pub inline fn wait_idle(self: Self, ctx: Context) void {
        _ = ctx.vkd.waitForFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.in_flight_fence), vk.TRUE, std.math.maxInt(u64)) catch |err| {
            // ctx.writers.stderr.print("waiting for fence failed: {}", .{err}) catch |e| switch (e) {
            //     else => {}, // Discard print errors ...
            // };
            std.io.getStdErr().writer().print("waiting for fence failed: {}", .{err}) catch {};
        };
    }

    inline fn recordCommands(self: Self, ctx: Context) !void {
        const image_use = Texture.getImageTransitionBarrier(self.target_texture.image, .general, .general);
        const command_begin_info = vk.CommandBufferBeginInfo{
            .flags = .{},
            .p_inheritance_info = null,
        };
        try ctx.vkd.beginCommandBuffer(self.command_buffer, &command_begin_info);
        ctx.vkd.cmdBindPipeline(self.command_buffer, vk.PipelineBindPoint.compute, self.pipeline.*);
        // zig fmt: off
        ctx.vkd.cmdPipelineBarrier(
            self.command_buffer, 
            image_use.transition.src_stage, 
            image_use.transition.dst_stage, 
            vk.DependencyFlags{}, 
            0, 
            undefined, 
            0, 
            undefined, 
            1, 
            @ptrCast([*]const vk.ImageMemoryBarrier, &image_use.barrier)
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
            undefined
        );
        // zig fmt: on
        // TODO: allow varying local thread size, error if x_ or y_ dispatch have decimal values
        // compute shader has 16 thread in x and y, we calculate inverse at compile time
        const local_thread_factor_x: f32 = comptime blk: {
            break :blk 1.0 / 32.0;
        };
        const local_thread_factor_y: f32 = comptime blk: {
            break :blk 1.0 / 32.0;
        };
        const img_width = self.target_texture.image_extent.width;
        const img_height = self.target_texture.image_extent.height;
        const x_dispatch = @ceil(@intToFloat(f32, img_width) * local_thread_factor_x);
        const y_dispatch = @ceil(@intToFloat(f32, img_height) * local_thread_factor_y);
        ctx.vkd.cmdDispatch(self.command_buffer, @floatToInt(u32, x_dispatch), @floatToInt(u32, y_dispatch), 1);
        try ctx.vkd.endCommandBuffer(self.command_buffer);
    }
};
