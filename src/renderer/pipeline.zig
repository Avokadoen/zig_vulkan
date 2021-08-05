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

    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    pipeline: *vk.Pipeline,
    framebuffers: ArrayList(vk.Framebuffer),

    command_pool: vk.CommandPool,
    command_buffers: ArrayList(vk.CommandBuffer),

    allocator: *Allocator,

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

        return Self{
            .render_pass = render_pass,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .framebuffers = framebuffers,
            .command_pool = command_pool,
            .command_buffers = command_buffers,
            .allocator = allocator,
        };
    }

    pub fn draw(self: Self, ctx: Context) void {
        _ = self;
        _ = ctx;
    }

    pub fn deinit(self: Self, ctx: Context) void {
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
