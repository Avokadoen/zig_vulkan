const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const vk = @import("vulkan");

const constants = @import("constants.zig");
const swapchain = @import("swapchain.zig");
const Context = @import("context.zig").Context;
const utils = @import("../utils.zig");

pub const ApplicationPipeline = struct {
    // TODO: https://www.khronos.org/registry/vulkan/specs/1.2-extensions/man/html/VkRayTracingPipelineCreateInfoKHR.html
    const Self = @This();

    allocator: *Allocator,

    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    pipeline: *vk.Pipeline,
    framebuffers: ArrayList(vk.Framebuffer),

    command_pool: vk.CommandPool,
    command_buffers: ArrayList(vk.CommandBuffer),

    image_available_s: ArrayList(vk.Semaphore),
    renderer_finished_s: ArrayList(vk.Semaphore),
    in_flight_fences: ArrayList(vk.Fence),
    images_in_flight: ArrayList(vk.Fence),

    /// initialize a graphics pipe line 
    pub fn init(allocator: *Allocator, ctx: Context) !Self {
        const pipeline_layout = blk: {
            const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = 0,
                .p_set_layouts = undefined,
                .push_constant_range_count = 0,
                .p_push_constant_ranges = undefined,
            };
            break :blk try ctx.createPipelineLayout(pipeline_layout_info);
        };
        const render_pass = try ctx.createRenderPass();

        const pipeline = blk: {
            const self_path = try std.fs.selfExePathAlloc(allocator);
            defer ctx.allocator.destroy(self_path.ptr);

            // TODO: function in context for shader stage creation?
            const vert_code = blk1: {
                const path = blk2: {
                    const join_path = [_][]const u8{ self_path, "../../triangle.vert.spv" };
                    break :blk2 try std.fs.path.resolve(allocator, join_path[0..]);
                };
                defer allocator.destroy(path.ptr);

                break :blk1 try utils.readFile(allocator, path);
            };
            const vert_module = try ctx.createShaderModule(vert_code.items[0..]);
            defer {
                ctx.destroyShaderModule(vert_module);
                vert_code.deinit();
            }

            const vert_stage = vk.PipelineShaderStageCreateInfo{ .flags = .{}, .stage = .{ .vertex_bit = true }, .module = vert_module, .p_name = "main", .p_specialization_info = null };

            const frag_code = blk1: {
                const path = blk2: {
                    const join_path = [_][]const u8{ self_path, "../../triangle.frag.spv" };
                    break :blk2 try std.fs.path.resolve(allocator, join_path[0..]);
                };
                defer allocator.destroy(path.ptr);

                break :blk1 try utils.readFile(allocator, path);
            };
            const frag_module = try ctx.createShaderModule(frag_code.items[0..]);
            defer {
                ctx.destroyShaderModule(frag_module);
                frag_code.deinit();
            }

            const frag_stage = vk.PipelineShaderStageCreateInfo{ .flags = .{}, .stage = .{ .fragment_bit = true }, .module = frag_module, .p_name = "main", .p_specialization_info = null };
            const shader_stages_info = [_]vk.PipelineShaderStageCreateInfo{ vert_stage, frag_stage };

            const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
                .flags = .{},
                .vertex_binding_description_count = 0,
                .p_vertex_binding_descriptions = undefined,
                .vertex_attribute_description_count = 0,
                .p_vertex_attribute_descriptions = undefined,
            };
            const input_assembley_info = vk.PipelineInputAssemblyStateCreateInfo{
                .flags = .{},
                .topology = vk.PrimitiveTopology.triangle_list,
                .primitive_restart_enable = vk.FALSE,
            };
            const view = ctx.createViewportScissors();
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
                .cull_mode = .{ .back_bit = true },
                .front_face = .clockwise,
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
                    .blend_enable = vk.FALSE,
                    .src_color_blend_factor = .one,
                    .dst_color_blend_factor = .zero,
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
            // TODO: allocate view struct and store pointer in this struct
            // const dynamic_states = [_]vk.DynamicState{
            //     .viewport,
            //     .scissor,
            // };
            const dynamic_state_info = vk.PipelineDynamicStateCreateInfo{
                .flags = .{},
                .dynamic_state_count = 0, // dynamic_states.len,
                .p_dynamic_states = undefined, // @ptrCast([*]const vk.DynamicState, &dynamic_states),
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
                .layout = pipeline_layout,
                .render_pass = render_pass,
                .subpass = 0,
                .base_pipeline_handle = .null_handle,
                .base_pipeline_index = -1,
            };
            break :blk try ctx.createGraphicsPipelines(allocator, pipeline_info);
        };

        var framebuffers = try ArrayList(vk.Framebuffer).initCapacity(allocator, ctx.swapchain_data.views.items.len);
        for (ctx.swapchain_data.views.items) |view| {
            const attachments = [_]vk.ImageView{
                view,
            };
            const framebuffer_info = vk.FramebufferCreateInfo{
                .flags = .{},
                .render_pass = render_pass,
                .attachment_count = attachments.len,
                .p_attachments = @ptrCast([*]const vk.ImageView, &attachments),
                .width = ctx.swapchain_data.extent.width,
                .height = ctx.swapchain_data.extent.height,
                .layers = 1,
            };
            const framebuffer = try ctx.vkd.createFramebuffer(ctx.logical_device, framebuffer_info, null);
            framebuffers.appendAssumeCapacity(framebuffer);
        }

        const command_pool = blk: {
            const pool_info = vk.CommandPoolCreateInfo{
                .flags = .{},
                .queue_family_index = ctx.queue_indices.graphics,
            };

            break :blk try ctx.vkd.createCommandPool(ctx.logical_device, pool_info, null);
        };

        const command_buffers = blk: {
            var buffers = try ArrayList(vk.CommandBuffer).initCapacity(allocator, framebuffers.items.len);
            const alloc_info = vk.CommandBufferAllocateInfo{
                .command_pool = command_pool,
                .level = vk.CommandBufferLevel.primary,
                .command_buffer_count = @intCast(u32, buffers.capacity),
            };

            try ctx.vkd.allocateCommandBuffers(ctx.logical_device, alloc_info, buffers.items.ptr);
            buffers.items.len = buffers.capacity;

            break :blk buffers;
        };

        const clear_color = [_]vk.ClearColorValue{
            .{
                .float_32 = [_]f32{ 0.0, 0.0, 0.0, 1.0 },
            },
        };
        for (command_buffers.items) |command_buffer, i| {
            const command_begin_info = vk.CommandBufferBeginInfo{
                .flags = .{},
                .p_inheritance_info = null,
            };
            try ctx.vkd.beginCommandBuffer(command_buffer, command_begin_info);

            const render_begin_info = vk.RenderPassBeginInfo{
                .render_pass = render_pass,
                .framebuffer = framebuffers.items[i],
                .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = ctx.swapchain_data.extent },
                .clear_value_count = clear_color.len,
                .p_clear_values = @ptrCast([*]const vk.ClearValue, &clear_color),
            };

            ctx.vkd.cmdBeginRenderPass(command_buffer, render_begin_info, vk.SubpassContents.@"inline");
            ctx.vkd.cmdBindPipeline(command_buffer, vk.PipelineBindPoint.graphics, pipeline.*);
            ctx.vkd.cmdDraw(command_buffer, 3, 1, 0, 0);
            ctx.vkd.cmdEndRenderPass(command_buffer);
            try ctx.vkd.endCommandBuffer(command_buffer);
        }

        const images_in_flight = blk: {
            var images_in_flight = try ArrayList(vk.Fence).initCapacity(allocator, ctx.swapchain_data.images.items.len);
            var i: usize = 0;
            while(i < images_in_flight.capacity) : (i += 1) {
                images_in_flight.appendAssumeCapacity(.null_handle);
            }
            break :blk images_in_flight;
        };   
        var image_available_s = try ArrayList(vk.Semaphore).initCapacity(allocator, constants.max_frames_in_flight);
        var renderer_finished_s = try ArrayList(vk.Semaphore).initCapacity(allocator, constants.max_frames_in_flight);
        var in_flight_fences = try ArrayList(vk.Fence).initCapacity(allocator, constants.max_frames_in_flight);
        const semaphore_info = vk.SemaphoreCreateInfo{
            .flags = .{},
        };
        const fence_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = true, },
        };
        {
            var i: usize = 0;
            while (i < constants.max_frames_in_flight) : (i += 1) {
                const image_sem = try ctx.vkd.createSemaphore(ctx.logical_device, semaphore_info, null);
                image_available_s.appendAssumeCapacity(image_sem);

                const finish_sem = try ctx.vkd.createSemaphore(ctx.logical_device, semaphore_info, null);
                renderer_finished_s.appendAssumeCapacity(finish_sem);

                const fence = try ctx.vkd.createFence(ctx.logical_device, fence_info, null);
                in_flight_fences.appendAssumeCapacity(fence);
            }
        }

        return Self{
            .allocator = allocator,
            .render_pass = render_pass,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .framebuffers = framebuffers,
            .command_pool = command_pool,
            .command_buffers = command_buffers,
            .image_available_s = image_available_s,
            .renderer_finished_s = renderer_finished_s,
            .in_flight_fences = in_flight_fences,
            .images_in_flight = images_in_flight,
        };
    }

    pub fn draw(self: Self, ctx: Context) !void {
        const state = struct {
            var current_frame: usize = 0;
        };
        const max_u64 = std.math.maxInt(u64); 

        const in_flight_fence_p = @ptrCast([*]const vk.Fence, &self.in_flight_fences.items[state.current_frame]);
        _ = try ctx.vkd.waitForFences(
            ctx.logical_device, 
            1, 
            in_flight_fence_p, 
            vk.TRUE, 
            max_u64
        );
        const acquire_result = try ctx.vkd.acquireNextImageKHR(
            ctx.logical_device, 
            ctx.swapchain_data.swapchain, 
            max_u64, 
            self.image_available_s.items[state.current_frame],
            .null_handle
        );
        if (acquire_result.result != vk.Result.success) {
            // TODO: actual errors ...
            // Possible errors codes:
            // - timeout (not possible with current use)
            // - not_ready
            // - suboptimal_khr
            // https://www.khronos.org/registry/vulkan/specs/1.2-extensions/man/html/vkAcquireNextImageKHR.html#_description
            return error.AcquireCError; 
        }
        // TODO: refactor so we always wait 
        if (self.images_in_flight.items[acquire_result.image_index] != .null_handle) {
            const p_fence = @ptrCast([*]const vk.Fence, &self.images_in_flight.items[acquire_result.image_index]);
            _ = try ctx.vkd.waitForFences(ctx.logical_device, 1, p_fence, vk.TRUE, max_u64);
        }
        self.images_in_flight.items[acquire_result.image_index] = self.in_flight_fences.items[state.current_frame];

        const wait_stages = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &self.image_available_s.items[state.current_frame]),
            .p_wait_dst_stage_mask = @ptrCast([*]const vk.PipelineStageFlags, &wait_stages),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.command_buffers.items[acquire_result.image_index]),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast([*]const vk.Semaphore, &self.renderer_finished_s.items[state.current_frame]),
        };
        const p_submit_info = @ptrCast([*]const vk.SubmitInfo, &submit_info);
        _ = try ctx.vkd.resetFences(
            ctx.logical_device, 
            1, 
            in_flight_fence_p
        );
        try ctx.vkd.queueSubmit(
            ctx.graphics_queue, 
            1, 
            p_submit_info, 
            self.in_flight_fences.items[state.current_frame]
        );

        const present_info = vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &self.renderer_finished_s.items[state.current_frame]),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast([*]const vk.SwapchainKHR, &ctx.swapchain_data.swapchain),
            .p_image_indices = @ptrCast([*]const u32, &acquire_result.image_index),
            .p_results = null,
        };
        
        if (ctx.vkd.queuePresentKHR(ctx.present_queue, present_info)) |_| {
            // TODO:
        } else |_| {
            // TODO:
        }

        state.current_frame = (state.current_frame + 1) % constants.max_frames_in_flight;
    }

    pub fn deinit(self: Self, ctx: Context) void {
        {
            var i: usize = 0;
            while (i < constants.max_frames_in_flight) : (i += 1) {
                ctx.vkd.destroySemaphore(ctx.logical_device, self.image_available_s.items[i], null);
                ctx.vkd.destroySemaphore(ctx.logical_device, self.renderer_finished_s.items[i], null);
                ctx.vkd.destroyFence(ctx.logical_device, self.in_flight_fences.items[i], null);
            }
        }
        self.image_available_s.deinit();
        self.renderer_finished_s.deinit();
        self.in_flight_fences.deinit();
        self.images_in_flight.deinit();

        self.command_buffers.deinit();
        ctx.vkd.destroyCommandPool(ctx.logical_device, self.command_pool, null);

        for (self.framebuffers.items) |framebuffer| {
            ctx.vkd.destroyFramebuffer(ctx.logical_device, framebuffer, null);
        }
        self.framebuffers.deinit();

        ctx.destroyPipelineLayout(self.pipeline_layout);
        ctx.destroyRenderPass(self.render_pass);
        ctx.destroyPipeline(self.pipeline);
        self.allocator.destroy(self.pipeline);
    }
};
