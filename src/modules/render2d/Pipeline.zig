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
pub const PipelineBuildError = error{
    MissingPipelines,
};

/// Vulkan pipeline code specific to render2d functionality
/// pipeline with generic user data 
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

                const framebuffers = try render.pipeline.createFramebuffers(self.allocator, self.ctx, self.sc_data, self.render_pass, null);
                errdefer self.allocator.free(framebuffers);

                const vertex_buffer = try vertex.createDefaultVertexBuffer(self.ctx, self.ctx.gfx_cmd_pool);
                errdefer vertex_buffer.deinit(self.ctx);

                const indices_buffer = try vertex.createDefaultIndicesBuffer(self.ctx, self.ctx.gfx_cmd_pool);
                errdefer indices_buffer.deinit(self.ctx);

                const command_buffers = try render.pipeline.createCmdBuffers(self.allocator, self.ctx, self.ctx.gfx_cmd_pool, framebuffers.len, null);
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
                try self.recordCmdBufferFn(ctx, self);
            }

            pub fn deinit(self: Pipeline, ctx: Context) void {
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

            inline fn wait_idle(self: Pipeline, ctx: Context) void {
                _ = ctx.vkd.waitForFences(ctx.logical_device, @intCast(u32, self.in_flight_fences.len), self.in_flight_fences.ptr, vk.TRUE, std.math.maxInt(u64)) catch |err| {
                    std.io.getStdErr().writer().print("waiting for fence failed: {}", .{err}) catch |e| switch (e) {
                        else => {}, // Discard print errors
                    };
                };
            }
        };
    };
}
