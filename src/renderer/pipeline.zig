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
const texture = @import("texture.zig");

const GpuBufferMemory = @import("gpu_buffer_memory.zig").GpuBufferMemory;
const Texture = texture.Texture;
const Context = @import("context.zig").Context;

pub const Pipeline2D = struct {
    const Self = @This();

    allocator: *Allocator,

    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    pipeline: *vk.Pipeline,
    framebuffers: ArrayList(vk.Framebuffer),

    // TODO: command buffers should be according to what we draw, and not directly related to pipeline?
    command_buffers: ArrayList(vk.CommandBuffer),

    image_available_s: ArrayList(vk.Semaphore),
    renderer_finished_s: ArrayList(vk.Semaphore),
    in_flight_fences: ArrayList(vk.Fence),
    images_in_flight: ArrayList(vk.Fence),

    requested_rescale_pipeline: bool = false,

    // TODO seperate vertex/index buffers from pipeline
    vertex_buffer: GpuBufferMemory,
    indices_buffer: GpuBufferMemory,

    sc_data: *const swapchain.Data,
    view: *const swapchain.ViewportScissor,

    sync_descript: *descriptor.SyncDescriptor,

    instance_count: u32,

    // TODO: correctness if init fail, clean up resources created with errdefer
    /// initialize a graphics pipe line, caller must make sure to call deinit
    /// sc_data, view and ubo needs a lifetime that is atleast as long as created pipeline
    pub fn init(allocator: *Allocator, ctx: Context, sc_data: *const swapchain.Data, instance_count: u32, view: *const swapchain.ViewportScissor, sync_descript: *descriptor.SyncDescriptor) !Self {
        var self: Self = undefined; 
        self.allocator = allocator;
        self.sc_data = sc_data;
        self.view = view;
        self.sync_descript = sync_descript;
        self.instance_count = instance_count;
    
        self.pipeline_layout = blk: {
            const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = 1,
                .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &self.sync_descript.ubo.descriptor_set_layout),
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
            defer vert_code.deinit();

            const vert_module = try ctx.createShaderModule(vert_code.items[0..]);
            defer ctx.destroyShaderModule(vert_module);

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
            defer frag_code.deinit();

            const frag_module = try ctx.createShaderModule(frag_code.items[0..]);
            defer ctx.destroyShaderModule(frag_module);

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
            break :blk try ctx.createGraphicsPipeline(allocator, pipeline_info);
        };

        self.framebuffers = try createFramebuffers(allocator, ctx, sc_data, self.render_pass);
        errdefer self.framebuffers.deinit();

        self.vertex_buffer = try vertex.createDefaultVertexBuffer(ctx, ctx.gfx_cmd_pool);
        errdefer self.vertex_buffer.deinit(ctx);

        self.indices_buffer = try vertex.createDefaultIndicesBuffer(ctx, ctx.gfx_cmd_pool);
        errdefer self.indices_buffer.deinit(ctx);

        self.command_buffers = try createCmdBuffers(allocator, ctx, ctx.gfx_cmd_pool, self.framebuffers.items.len);
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
            .vertex_buffer = self.vertex_buffer,
            .indices_buffer = self.indices_buffer,
            .sc_data = sc_data,
            .sync_descript = sync_descript,
            .instance_count = self.instance_count,
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

        // if ubo is dirty
        if (self.sync_descript.ubo.is_dirty[image_index]) {
            // transfer data to gpu
            var ubo_arr = [_]descriptor.Uniform{self.sync_descript.ubo.uniform_data};
            // TODO: only transfer dirty part of data
            try self.sync_descript.ubo.uniform_buffers[image_index].transferData(ctx, descriptor.Uniform, ubo_arr[0..]);
            self.sync_descript.ubo.is_dirty[image_index] = false;
        }

        // TODO: we might used dynamic dispatch for this part (currently hardcoded sprite transfer ...)
        // {
        //     const zlm = @import("zlm");
        //     try self.sync_descript.ubo.storage_buffers[image_index][0].transferData(ctx, zlm.Vec2, self.sync_descript.ubo.storage_data.member_0[0..]);
        //     try self.sync_descript.ubo.storage_buffers[image_index][1].transferData(ctx, i32, self.sync_descript.ubo.storage_data.member_1[0..]);
        // }
    
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

        self.command_buffers = try createCmdBuffers(allocator, ctx, ctx.gfx_cmd_pool, self.framebuffers.items.len);
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
                    else => {}, // Discard print errors
                };
            };
        }
};

// TODO: move gfx specific functions inside the gfx scope

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

/// create a command buffers with sizeof buffer_count, caller must deinit returned list
inline fn createCmdBuffers(allocator: *Allocator, ctx: Context, command_pool: vk.CommandPool, buffer_count: usize) !ArrayList(vk.CommandBuffer) {
    var command_buffers = try ArrayList(vk.CommandBuffer).initCapacity(allocator, buffer_count);
    const alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = vk.CommandBufferLevel.primary,
        .command_buffer_count = @intCast(u32, command_buffers.capacity),
    };

    try ctx.vkd.allocateCommandBuffers(ctx.logical_device, alloc_info, command_buffers.items.ptr);
    command_buffers.items.len = command_buffers.capacity;

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
    try ctx.vkd.allocateCommandBuffers(ctx.logical_device, alloc_info, @ptrCast([*]vk.CommandBuffer, &command_buffer));

    return command_buffer;
}


/// record default commands to the command buffer
fn recordGfxCmdBuffers(ctx: Context, pipeline: *Pipeline2D) !void {
    const image = pipeline.sync_descript.ubo.my_texture.image;
    const image_use = texture.getImageTransitionBarrier(image, .general, .general);
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

        // make sure compute shader complet writer before beginning render pass
        ctx.vkd.cmdPipelineBarrier(
            command_buffer,
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
        const render_begin_info = vk.RenderPassBeginInfo{
            .render_pass = pipeline.render_pass,
            .framebuffer = pipeline.framebuffers.items[i],
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = pipeline.sc_data.extent },
            .clear_value_count = clear_color.len,
            .p_clear_values = @ptrCast([*]const vk.ClearValue, &clear_color),
        };
        ctx.vkd.cmdSetViewport(command_buffer, 0, pipeline.view.viewport.len, &pipeline.view.viewport);
        ctx.vkd.cmdSetScissor(command_buffer, 0, pipeline.view.scissor.len, &pipeline.view.scissor);
        ctx.vkd.cmdBindPipeline(command_buffer, vk.PipelineBindPoint.graphics, pipeline.pipeline.*);
        ctx.vkd.cmdBeginRenderPass(command_buffer, render_begin_info, vk.SubpassContents.@"inline");

        const buffer_offsets = [_]vk.DeviceSize{ 0 };
        ctx.vkd.cmdBindVertexBuffers(
            command_buffer, 
            0, 
            1, 
            @ptrCast([*]const vk.Buffer, &pipeline.vertex_buffer.buffer), 
            @ptrCast([*]const vk.DeviceSize, &buffer_offsets)
        );
        ctx.vkd.cmdBindIndexBuffer(command_buffer, pipeline.indices_buffer.buffer, 0, .uint32);
        // TODO: Race Condition: sync_descript is not synced here 
        ctx.vkd.cmdBindDescriptorSets(
            command_buffer, 
            .graphics, 
            pipeline.pipeline_layout, 
            0, 
            1, 
            @ptrCast([*]const vk.DescriptorSet, &pipeline.sync_descript.ubo.descriptor_sets[i]),
            0,
            undefined
        );
        
        // TODO temp solution: call draw for each instance, should be cheap since this is a cmd buffer ?
        //                     alternative solution: fill indices buffer with duplicate data according to instance_count
        var j: u32 = 0;
        while (j < pipeline.instance_count) : (j += 1) {
            ctx.vkd.cmdDrawIndexed(command_buffer, pipeline.indices_buffer.len, 1, 0, 0, j);
        }
        ctx.vkd.cmdEndRenderPass(command_buffer);
        try ctx.vkd.endCommandBuffer(command_buffer);
    }
}

// TODO: at this point pipelines should have their own internal module!

pub const ComputePipeline = struct {
    const Self = @This();

    allocator: *Allocator,

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

    // TODO: correctness if init fail, clean up resources created with errdefer
    /// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
    /// texture should have a lifetime atleast the lenght of comptute pipeline
    pub fn init(allocator: *Allocator, ctx: Context, shader_path: []const u8, target_texture: *Texture) !Self {
        var self: Self = undefined; 
        self.allocator = allocator;
        self.target_texture = target_texture;

        self.target_descriptor_layout = blk: {
            const sampler_layout_binding = vk.DescriptorSetLayoutBinding{
                .binding = 1,
                .descriptor_type = .storage_image, // TODO: validate correct type
                .descriptor_count = 1,
                .stage_flags = .{ .compute_bit = true, },
                .p_immutable_samplers = null,
            };
            const layout_bindings = [_]vk.DescriptorSetLayoutBinding{ sampler_layout_binding };
            const layout_info = vk.DescriptorSetLayoutCreateInfo{
                .flags = .{},
                .binding_count = layout_bindings.len,
                .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, &layout_bindings),
            };
            break :blk try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, layout_info, null);
        };
        errdefer ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.target_descriptor_layout, null);

        self.target_descriptor_pool = blk: {
            const sampler_pool_size = vk.DescriptorPoolSize{
                .@"type" = .storage_image,
                .descriptor_count = 1,
            };
            const pool_info = vk.DescriptorPoolCreateInfo{
                .flags = .{},
                .max_sets = 1,
                .pool_size_count = 1,
                .p_pool_sizes = @ptrCast([*]const vk.DescriptorPoolSize, &sampler_pool_size),
            };
            break :blk try ctx.vkd.createDescriptorPool(ctx.logical_device, pool_info, null);
        };
        errdefer ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

        const descriptor_set_alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = self.target_descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast([*]vk.DescriptorSetLayout, &self.target_descriptor_layout),
        };
        try ctx.vkd.allocateDescriptorSets(ctx.logical_device, descriptor_set_alloc_info, @ptrCast([*]vk.DescriptorSet, &self.target_descriptor_set));
        {
            const image_info = vk.DescriptorImageInfo{
                .sampler = self.target_texture.sampler,
                .image_view = self.target_texture.image_view,
                .image_layout = .general,
            };
            const image_write_descriptor_set = vk.WriteDescriptorSet{
                .dst_set = self.target_descriptor_set,
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_image,
                .p_image_info = @ptrCast([*]const vk.DescriptorImageInfo, &image_info),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };
            ctx.vkd.updateDescriptorSets(
                ctx.logical_device, 
                1, 
                @ptrCast([*]const vk.WriteDescriptorSet, &image_write_descriptor_set), 
                0, 
                undefined
            );
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
                    const join_path = [_][]const u8{ self_path, shader_path};
                    break :blk2 try std.fs.path.resolve(allocator, join_path[0..]);
                };
                defer allocator.destroy(path.ptr);

                break :blk1 try utils.readFile(allocator, path);
            };
            defer code.deinit();

            const module = try ctx.createShaderModule(code.items[0..]);
            defer ctx.destroyShaderModule(module);

            const stage = vk.PipelineShaderStageCreateInfo{ 
                .flags = .{}, 
                .stage = .{ .compute_bit = true }, 
                .module = module, 
                .p_name = "main", 
                .p_specialization_info = null 
            };

            // TOOD: read on defer_compile_bit_nv
            const pipeline_info = vk.ComputePipelineCreateInfo{
                .flags = .{},
                .stage = stage,
                .layout = self.pipeline_layout,
                .base_pipeline_handle = .null_handle, // TODO: GfxPipeline?
                .base_pipeline_index =  -1,
            };
            break :blk try ctx.createComputePipeline(allocator, pipeline_info);
        };

        // TODO: data(vertex/uniform/etc) buffers! (see GfxPipeline)

        const fence_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = true, },
        };
        self.in_flight_fence = try ctx.vkd.createFence(ctx.logical_device, fence_info, null);

        // TODO: we need to rescale pipeline dispatch 
        self.command_buffer = try createCmdBuffer(ctx, ctx.comp_cmd_pool);
        errdefer ctx.vkd.freeCommandBuffers(ctx.logical_device, ctx.comp_cmd_pool, 1, @ptrCast([*]vk.CommandBuffer, &self.command_buffer));

        try self.recordCommands(ctx);

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
        };
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
        _ = try ctx.vkd.resetFences(
            ctx.logical_device, 
            1, 
            @ptrCast([*]const vk.Fence, &self.in_flight_fence)
        );
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

        ctx.vkd.freeCommandBuffers(
            ctx.logical_device, 
            ctx.comp_cmd_pool, 
            1, 
            @ptrCast([*]const vk.CommandBuffer, &self.command_buffer)
        );

        self.command_buffer = try createCmdBuffer(ctx, ctx.comp_cmd_pool);

        try self.recordCommands(ctx);
    }

    pub fn deinit(self: Self, ctx: Context) void {
        self.wait_idle(ctx);

        ctx.vkd.destroyFence(ctx.logical_device, self.in_flight_fence, null);
        
        ctx.vkd.freeCommandBuffers(ctx.logical_device, ctx.comp_cmd_pool, 1, @ptrCast([*]const vk.CommandBuffer, &self.command_buffer));
        ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.target_descriptor_layout, null);
        ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

        ctx.destroyPipelineLayout(self.pipeline_layout);
        ctx.destroyPipeline(self.pipeline);

        self.allocator.destroy(self.pipeline);
    }

    /// Wait for fence to signal complete 
    pub inline fn wait_idle(self: Self, ctx: Context) void {
        _ = ctx.vkd.waitForFences(
            ctx.logical_device, 
            1,
            @ptrCast([*]const vk.Fence, &self.in_flight_fence),
            vk.TRUE,
            std.math.maxInt(u64) 
        ) catch |err| {
            ctx.writers.stderr.print("waiting for fence failed: {}", .{err}) catch |e| switch (e) {
                else => {}, // Discard print errors ...
            };
        };
    }

    inline fn recordCommands(self: Self, ctx: Context) !void {
        const image_use = texture.getImageTransitionBarrier(self.target_texture.image, .general, .general);
        const command_begin_info = vk.CommandBufferBeginInfo{
            .flags = .{},
            .p_inheritance_info = null,
        };
        try ctx.vkd.beginCommandBuffer(self.command_buffer, command_begin_info);
        ctx.vkd.cmdBindPipeline(self.command_buffer, vk.PipelineBindPoint.compute, self.pipeline.*);
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
        // TODO: allow varying local thread size, error if x_ or y_ dispatch have decimal values
        // compute shader has 16 thread in x and y, we calculate inverse at compile time 
        const local_thread_factor: f32 = comptime blk: { break :blk 1.0 / 16.0; };
        const x_dispatch = @intToFloat(f32, self.target_texture.image_extent.width) * local_thread_factor;
        const y_dispatch = @intToFloat(f32, self.target_texture.image_extent.height) * local_thread_factor;
        ctx.vkd.cmdDispatch(self.command_buffer, @floatToInt(u32, x_dispatch), @floatToInt(u32, y_dispatch), 1);
        try ctx.vkd.endCommandBuffer(self.command_buffer);
    }
};
