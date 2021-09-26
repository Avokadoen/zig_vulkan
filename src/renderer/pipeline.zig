const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const vk = @import("vulkan");
const glfw = @import("glfw");

const constants = @import("consts.zig");
const swapchain = @import("swapchain.zig");
const vertex = @import("vertex.zig");
const tb = @import("transform_buffer.zig");
const utils = @import("../utils.zig");

const GpuBufferMemory = @import("gpu_buffer_memory.zig").GpuBufferMemory;
const Context = @import("context.zig").Context;

pub const GfxPipeline = struct {
    const Self = @This();

    allocator: *Allocator,

    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    pipeline: *vk.Pipeline,
    framebuffers: ArrayList(vk.Framebuffer),

    command_buffers: ArrayList(vk.CommandBuffer),

    image_available_s: ArrayList(vk.Semaphore),
    renderer_finished_s: ArrayList(vk.Semaphore),
    in_flight_fences: ArrayList(vk.Fence),
    images_in_flight: ArrayList(vk.Fence),

    requested_rescale_pipeline: bool,

    // TODO seperate vertex/index buffers from pipeline
    vertex_buffer: GpuBufferMemory,
    indices_buffer: GpuBufferMemory,

    sc_data: *const swapchain.Data,
    view: *const swapchain.ViewportScissor,
    subo: *const tb.SyncUniformBuffer,

    // TODO: correctness if init fail, clean up resources created with errdefer
    /// initialize a graphics pipe line, caller must make sure to call deinit
    /// sc_data, view and ubo needs a lifetime that is atleast as long as created pipeline
    pub fn init(allocator: *Allocator, ctx: Context, sc_data: *const swapchain.Data, view: *const swapchain.ViewportScissor, subo: *const tb.SyncUniformBuffer) !Self {
        var self: Self = undefined; 
        self.allocator = allocator;
        self.sc_data = sc_data;
        self.view = view;
        self.subo = subo;
       
        self.pipeline_layout = blk: {
            const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = 1,
                .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &self.subo.ubo.descriptor_set_layout),
                .push_constant_range_count = 0,
                .p_push_constant_ranges = undefined,
            };
            break :blk try ctx.createPipelineLayout(pipeline_layout_info);
        };
        self.render_pass = try ctx.createRenderPass(sc_data.format);
        self.pipeline = blk: {
            const self_path = try std.fs.selfExePathAlloc(allocator);
            defer ctx.allocator.destroy(self_path.ptr);

            // TODO: function in context for shader stage creation?
            const vert_code = blk1: {
                const path = blk2: {
                    const join_path = [_][]const u8{ self_path, "../../pass.vert.spv" };
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

            const vert_stage = vk.PipelineShaderStageCreateInfo{ 
                .flags = .{}, 
                .stage = .{ .vertex_bit = true }, 
                .module = vert_module, 
                .p_name = "main", 
                .p_specialization_info = null 
            };
            const frag_code = blk1: {
                const path = blk2: {
                    const join_path = [_][]const u8{ self_path, "../../pass.frag.spv" };
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

            const frag_stage = vk.PipelineShaderStageCreateInfo{ 
                .flags = .{}, 
                .stage = .{ .fragment_bit = true }, 
                .module = frag_module, 
                .p_name = "main", 
                .p_specialization_info = null 
            };
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
            break :blk try ctx.createGraphicsPipelines(allocator, pipeline_info);
        };

        self.framebuffers = try createFramebuffers(allocator, ctx, sc_data, self.render_pass);
        errdefer self.framebuffers.deinit();

        self.vertex_buffer = try vertex.createDefaultVertexBuffer(ctx, ctx.gfx_cmd_pool);
        errdefer self.vertex_buffer.deinit(ctx);

        self.indices_buffer = try vertex.createDefaultIndicesBuffer(ctx, ctx.gfx_cmd_pool);
        errdefer self.indices_buffer.deinit(ctx);

        self.command_buffers = try createCmdBuffers(allocator, ctx, ctx.gfx_cmd_pool, self.framebuffers);
        errdefer self.command_buffers.deinit();

        self.images_in_flight = blk: {
            var images_in_flight = try ArrayList(vk.Fence).initCapacity(allocator, sc_data.images.items.len);
            var i: usize = 0;
            while(i < images_in_flight.capacity) : (i += 1) {
                images_in_flight.appendAssumeCapacity(.null_handle);
            }
            break :blk images_in_flight;
        };
        errdefer self.images_in_flight.deinit();

        self.image_available_s = try ArrayList(vk.Semaphore).initCapacity(allocator, constants.max_frames_in_flight);
        errdefer self.image_available_s.deinit();

        self.renderer_finished_s = try ArrayList(vk.Semaphore).initCapacity(allocator, constants.max_frames_in_flight);
        errdefer self.renderer_finished_s.deinit();

        self.in_flight_fences = try ArrayList(vk.Fence).initCapacity(allocator, constants.max_frames_in_flight);
        errdefer self.in_flight_fences.deinit();

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
                self.image_available_s.appendAssumeCapacity(image_sem);

                const finish_sem = try ctx.vkd.createSemaphore(ctx.logical_device, semaphore_info, null);
                self.renderer_finished_s.appendAssumeCapacity(finish_sem);

                const fence = try ctx.vkd.createFence(ctx.logical_device, fence_info, null);
                self.in_flight_fences.appendAssumeCapacity(fence);
            }
        }

        // self is sufficiently defined to record command buffer
        try recordGfxCmdBuffers(ctx, &self); 

        return Self{
            .allocator = self.allocator,
            .view = self.view,
            .render_pass = self.render_pass,
            .pipeline_layout = self.pipeline_layout,
            .pipeline = self.pipeline,
            .framebuffers = self.framebuffers,
            .command_buffers = self.command_buffers,
            .image_available_s = self.image_available_s,
            .renderer_finished_s = self.renderer_finished_s,
            .in_flight_fences = self.in_flight_fences,
            .images_in_flight = self.images_in_flight,
            .requested_rescale_pipeline = false,
            .vertex_buffer = self.vertex_buffer,
            .indices_buffer = self.indices_buffer,
            .sc_data = sc_data,
            .subo = subo,
        };
    }

    pub fn draw(self: *Self, ctx: Context) !void {
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

        var image_index: u32 = undefined;
        if (ctx.vkd.acquireNextImageKHR(
            ctx.logical_device, 
            self.sc_data.swapchain, 
            max_u64, 
            self.image_available_s.items[state.current_frame],
            .null_handle
        )) |ok| switch(ok.result) {
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
            }
        } else |err| switch(err) {
            error.OutOfDateKHR => {
                self.requested_rescale_pipeline = true;
                return;
            },
            else => {
                return err;
            },
        }
        
        if (self.images_in_flight.items[image_index] != .null_handle) {
            const p_fence = @ptrCast([*]const vk.Fence, &self.images_in_flight.items[image_index]);
            _ = try ctx.vkd.waitForFences(ctx.logical_device, 1, p_fence, vk.TRUE, max_u64);
        }
        self.images_in_flight.items[image_index] = self.in_flight_fences.items[state.current_frame];

        // TODO: only transfer if "dirty", only transfer section of buffer that changed
        var ubo_slice = [_]tb.TransformBuffer{self.subo.ubo.data};
        try self.subo.ubo.buffers[image_index].transferData(ctx, tb.TransformBuffer, ubo_slice[0..]);

        const wait_stages = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &self.image_available_s.items[state.current_frame]),
            .p_wait_dst_stage_mask = @ptrCast([*]const vk.PipelineStageFlags, &wait_stages),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.command_buffers.items[image_index]),
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
            .p_swapchains = @ptrCast([*]const vk.SwapchainKHR, &self.sc_data.swapchain),
            .p_image_indices = @ptrCast([*]const u32, &image_index),
            .p_results = null,
        };
        
        if (ctx.vkd.queuePresentKHR(ctx.present_queue, present_info)) |_| {
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
    fn rescalePipeline(self: *Self, allocator: *Allocator, ctx: Context) !void {
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
        for (self.framebuffers.items) |framebuffer| {
            ctx.vkd.destroyFramebuffer(ctx.logical_device, framebuffer, null);
        }
        // TODO: this container can be reused in createFramebuffers!
        self.framebuffers.deinit();
        ctx.vkd.freeCommandBuffers(
            ctx.logical_device, 
            ctx.gfx_cmd_pool, 
            @intCast(u32, self.command_buffers.items.len), 
            @ptrCast([*]const vk.CommandBuffer, self.command_buffers.items.ptr)
        );
        // TODO: this container can be reused in createCmdBuffers!
        self.command_buffers.deinit(); 
        ctx.destroyRenderPass(self.render_pass);

        // recreate renderpass and framebuffers
        self.render_pass = try ctx.createRenderPass(self.sc_data.format);
        self.framebuffers = try createFramebuffers(allocator, ctx, self.sc_data, self.render_pass);

        self.command_buffers = try createCmdBuffers(allocator, ctx, ctx.gfx_cmd_pool, self.framebuffers);
        try recordGfxCmdBuffers(ctx, self);
    }

    pub fn deinit(self: Self, ctx: Context) void {
        self.wait_idle(ctx);
        {
            var i: usize = 0;
            while (i < constants.max_frames_in_flight) : (i += 1) {
                ctx.vkd.destroySemaphore(ctx.logical_device, self.image_available_s.items[i], null);
                ctx.vkd.destroySemaphore(ctx.logical_device, self.renderer_finished_s.items[i], null);
                ctx.vkd.destroyFence(ctx.logical_device, self.in_flight_fences.items[i], null);
            }
        }
       
        self.vertex_buffer.deinit(ctx);
        self.indices_buffer.deinit(ctx);

        self.image_available_s.deinit();
        self.renderer_finished_s.deinit();
        self.in_flight_fences.deinit();
        self.images_in_flight.deinit();

        self.command_buffers.deinit();

        for (self.framebuffers.items) |framebuffer| {
            ctx.vkd.destroyFramebuffer(ctx.logical_device, framebuffer, null);
        }
        self.framebuffers.deinit();

        ctx.destroyPipelineLayout(self.pipeline_layout);
        ctx.destroyRenderPass(self.render_pass);
        ctx.destroyPipeline(self.pipeline);

        self.allocator.destroy(self.pipeline);
    }

    inline fn wait_idle(self: Self, ctx: Context) void {
        _ = ctx.vkd.waitForFences(
            ctx.logical_device, 
            @intCast(u32, self.in_flight_fences.items.len),
            self.in_flight_fences.items.ptr,
            vk.TRUE,
            std.math.maxInt(u64) 
        ) catch |err| {
            ctx.writers.stderr.print("waiting for fence failed: {}", .{err}) catch |e| switch (e) {
                else => {}, // Discard print errors ...
            };
        };
    }
};

inline fn createFramebuffers(allocator: *Allocator, ctx: Context, swapchain_data: *const swapchain.Data, render_pass: vk.RenderPass) !ArrayList(vk.Framebuffer) {
    const image_views = swapchain_data.image_views;
    var framebuffers = try ArrayList(vk.Framebuffer).initCapacity(allocator, image_views.items.len);
    for (image_views.items) |view| {
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
        const framebuffer = try ctx.vkd.createFramebuffer(ctx.logical_device, framebuffer_info, null);
        framebuffers.appendAssumeCapacity(framebuffer);
    }
    return framebuffers;
}

/// create a command buffer relative to the framebuffer
inline fn createCmdBuffers(allocator: *Allocator, ctx: Context, command_pool: vk.CommandPool, framebuffers: ArrayList(vk.Framebuffer)) !ArrayList(vk.CommandBuffer) {
    var command_buffers = try ArrayList(vk.CommandBuffer).initCapacity(allocator, framebuffers.items.len);
    const alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = vk.CommandBufferLevel.primary,
        .command_buffer_count = @intCast(u32, command_buffers.capacity),
    };

    try ctx.vkd.allocateCommandBuffers(ctx.logical_device, alloc_info, command_buffers.items.ptr);
    command_buffers.items.len = command_buffers.capacity;

    return command_buffers;
}


/// record default commands to the command buffer
fn recordGfxCmdBuffers(ctx: Context, pipeline: *GfxPipeline) !void {
    const clear_color = [_]vk.ClearColorValue{
        .{
            .float_32 = [_]f32{ 0.0, 0.0, 0.0, 1.0 },
        },
    };
    for (pipeline.command_buffers.items) |command_buffer, i| {
        const command_begin_info = vk.CommandBufferBeginInfo{
            .flags = .{},
            .p_inheritance_info = null,
        };
        try ctx.vkd.beginCommandBuffer(command_buffer, command_begin_info);

        const render_begin_info = vk.RenderPassBeginInfo{
            .render_pass = pipeline.render_pass,
            .framebuffer = pipeline.framebuffers.items[i],
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = pipeline.sc_data.extent },
            .clear_value_count = clear_color.len,
            .p_clear_values = @ptrCast([*]const vk.ClearValue, &clear_color),
        };
        ctx.vkd.cmdSetViewport(command_buffer, 0, pipeline.view.viewport.len, &pipeline.view.viewport);
        ctx.vkd.cmdSetScissor(command_buffer, 0, pipeline.view.scissor.len, &pipeline.view.scissor);
        ctx.vkd.cmdBeginRenderPass(command_buffer, render_begin_info, vk.SubpassContents.@"inline");
        ctx.vkd.cmdBindPipeline(command_buffer, vk.PipelineBindPoint.graphics, pipeline.pipeline.*);

        const buffer_offsets = [_]vk.DeviceSize{ 0 };
        ctx.vkd.cmdBindVertexBuffers(
            command_buffer, 
            0, 
            1, 
            @ptrCast([*]const vk.Buffer, &pipeline.vertex_buffer.buffer), 
            @ptrCast([*]const vk.DeviceSize, &buffer_offsets)
        );
        ctx.vkd.cmdBindIndexBuffer(command_buffer, pipeline.indices_buffer.buffer, 0, .uint32);
        // TODO: RC: subo is not synced here 
        ctx.vkd.cmdBindDescriptorSets(
            command_buffer, 
            .graphics, 
            pipeline.pipeline_layout, 
            0, 
            1, 
            @ptrCast([*]const vk.DescriptorSet, &pipeline.subo.ubo.descriptor_sets[i]),
            0,
            undefined
        );
        ctx.vkd.cmdDrawIndexed(command_buffer, pipeline.indices_buffer.len, 1, 0, 0, 0);
        ctx.vkd.cmdEndRenderPass(command_buffer);
        try ctx.vkd.endCommandBuffer(command_buffer);
    }
}
