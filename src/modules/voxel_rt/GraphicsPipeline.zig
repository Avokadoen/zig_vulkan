const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const render = @import("../render.zig");
const Context = render.Context;
const Texture = render.Texture;
const GpuBufferMemory = render.GpuBufferMemory;
const Swapchain = render.swapchain.Data;

const Vertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
};

/// Pipeline to draw a single texture to screen
const GraphicsPipeline = @This();

pipeline_cache: vk.PipelineCache,
pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

descriptor_set_layout: vk.DescriptorSetLayout,
descriptor_set: vk.DescriptorSet,
descriptor_pool: vk.DescriptorPool,

current_frame: usize,
command_buffers: []vk.CommandBuffer,
framebuffers: []vk.Framebuffer,

vertex_buffer: GpuBufferMemory,
index_buffer: GpuBufferMemory,

// shader modules stored for cleanup
shader_modules: [2]vk.ShaderModule,

texture: *const Texture,

pub fn init(allocator: Allocator, ctx: Context, swapchain: Swapchain, render_pass: vk.RenderPass, texture: *const Texture) !GraphicsPipeline {
    const vertices = [_]Vertex{
        .{ .pos = .{ 1.0, 1.0, 0.0 }, .uv = .{ 1.0, 1.0 } },
        .{ .pos = .{ -1.0, 1.0, 0.0 }, .uv = .{ 0.0, 1.0 } },
        .{ .pos = .{ -1.0, -1.0, 0.0 }, .uv = .{ 0.0, 0.0 } },
        .{ .pos = .{ 1.0, -1.0, 0.0 }, .uv = .{ 1.0, 0.0 } },
    };
    var vertex_buffer = try GpuBufferMemory.init(
        ctx,
        @sizeOf(Vertex) * vertices.len,
        .{ .vertex_buffer_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    );
    errdefer vertex_buffer.deinit(ctx);
    try vertex_buffer.transferToDevice(ctx, Vertex, 0, vertices[0..]);

    const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };
    var index_buffer = try GpuBufferMemory.init(
        ctx,
        @sizeOf(u16) * indices.len,
        .{ .index_buffer_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    );
    errdefer index_buffer.deinit(ctx);
    try index_buffer.transferToDevice(ctx, u16, 0, indices[0..]);

    const descriptor_pool = blk: {
        const pool_sizes = [_]vk.DescriptorPoolSize{.{
            .@"type" = .combined_image_sampler,
            .descriptor_count = 1, // TODO: swap image size ?
        }};
        const descriptor_pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = @intCast(u32, swapchain.images.len),
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
        };
        break :blk try ctx.vkd.createDescriptorPool(ctx.logical_device, &descriptor_pool_info, null);
    };
    errdefer ctx.vkd.destroyDescriptorPool(ctx.logical_device, descriptor_pool, null);

    const descriptor_set_layout = blk: {
        const set_layout_bindings = [_]vk.DescriptorSetLayoutBinding{.{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{
                .fragment_bit = true,
            },
            .p_immutable_samplers = null,
        }};
        const set_layout_info = vk.DescriptorSetLayoutCreateInfo{
            .flags = .{},
            .binding_count = set_layout_bindings.len,
            .p_bindings = &set_layout_bindings,
        };
        break :blk try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &set_layout_info, null);
    };
    errdefer ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, descriptor_set_layout, null);

    const descriptor_set = blk: {
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &descriptor_set_layout),
        };
        var descriptor_set_tmp: vk.DescriptorSet = undefined;
        try ctx.vkd.allocateDescriptorSets(
            ctx.logical_device,
            &alloc_info,
            @ptrCast([*]vk.DescriptorSet, &descriptor_set_tmp),
        );
        break :blk descriptor_set_tmp;
    };
    errdefer ctx.vkd.freeDescriptorSets(
        ctx.logical_device,
        descriptor_pool,
        1,
        @ptrCast([*]const vk.DescriptorSet, &descriptor_set),
    ) catch {};

    {
        const descriptor_info = vk.DescriptorImageInfo{
            .sampler = texture.sampler,
            .image_view = texture.image_view,
            .image_layout = .general,
        };
        const write_descriptor_sets = [_]vk.WriteDescriptorSet{.{
            .dst_set = descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast([*]const vk.DescriptorImageInfo, &descriptor_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }};
        ctx.vkd.updateDescriptorSets(
            ctx.logical_device,
            write_descriptor_sets.len,
            @ptrCast([*]const vk.WriteDescriptorSet, &write_descriptor_sets),
            0,
            undefined,
        );
    }

    const pipeline_layout = blk: {
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &descriptor_set_layout),
            .push_constant_range_count = 0,
            .p_push_constant_ranges = undefined,
        };
        break :blk try ctx.vkd.createPipelineLayout(ctx.logical_device, &pipeline_layout_info, null);
    };
    errdefer ctx.vkd.destroyPipelineLayout(ctx.logical_device, pipeline_layout, null);

    const input_assembly_state = vk.PipelineInputAssemblyStateCreateInfo{
        .flags = .{},
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };
    const rasterization_state = vk.PipelineRasterizationStateCreateInfo{
        .flags = .{},
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .cull_mode = .{},
        .front_face = .counter_clockwise,
        .depth_bias_enable = 0,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };
    const blend_attachment_state = vk.PipelineColorBlendAttachmentState{
        .blend_enable = vk.TRUE,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one_minus_src_alpha,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{
            .r_bit = true,
            .g_bit = true,
            .b_bit = true,
            .a_bit = true,
        },
    };
    const color_blend_state = vk.PipelineColorBlendStateCreateInfo{
        .flags = .{},
        .logic_op_enable = vk.FALSE,
        .logic_op = .clear,
        .attachment_count = 1,
        .p_attachments = @ptrCast([*]const vk.PipelineColorBlendAttachmentState, &blend_attachment_state),
        .blend_constants = [4]f32{ 0, 0, 0, 0 },
    };
    // TODO: deviation from guide. Validate that still valid!
    const depth_stencil_state: ?*vk.PipelineDepthStencilStateCreateInfo = null;

    const viewport_state = vk.PipelineViewportStateCreateInfo{
        .flags = .{},
        .viewport_count = 1,
        .p_viewports = null, // viewport is created on draw
        .scissor_count = 1,
        .p_scissors = null, // scissor is created on draw
    };
    const multisample_state = vk.PipelineMultisampleStateCreateInfo{
        .flags = .{},
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };
    const dynamic_state_enabled = [_]vk.DynamicState{
        .viewport,
        .scissor,
    };
    const dynamic_state = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynamic_state_enabled.len,
        .p_dynamic_states = &dynamic_state_enabled,
    };

    const vert = try render.pipeline.loadShaderStage(ctx, allocator, null, "image.vert.spv", .{ .vertex_bit = true });
    errdefer ctx.vkd.destroyShaderModule(ctx.logical_device, vert.module, null);
    const frag = try render.pipeline.loadShaderStage(ctx, allocator, null, "image.frag.spv", .{ .fragment_bit = true });
    errdefer ctx.vkd.destroyShaderModule(ctx.logical_device, frag.module, null);
    const shader_stages = [_]vk.PipelineShaderStageCreateInfo{ vert, frag };

    const vertex_input_bindings = [_]vk.VertexInputBindingDescription{.{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    }};
    const vertex_input_attributes = [_]vk.VertexInputAttributeDescription{ .{
        .location = 0,
        .binding = 0,
        .format = .r32g32_sfloat,
        .offset = @offsetOf(Vertex, "pos"),
    }, .{
        .location = 1,
        .binding = 0,
        .format = .r32g32_sfloat,
        .offset = @offsetOf(Vertex, "uv"),
    } };
    const vertex_input_state = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = vertex_input_bindings.len,
        .p_vertex_binding_descriptions = &vertex_input_bindings,
        .vertex_attribute_description_count = vertex_input_attributes.len,
        .p_vertex_attribute_descriptions = &vertex_input_attributes,
    };
    const pipeline_cache = blk: {
        const pipeline_cache_info = vk.PipelineCacheCreateInfo{
            .flags = .{},
            .initial_data_size = 0,
            .p_initial_data = undefined,
        };
        break :blk try ctx.vkd.createPipelineCache(ctx.logical_device, &pipeline_cache_info, null);
    };
    errdefer ctx.vkd.destroyPipelineCache(ctx.logical_device, pipeline_cache, null);

    const pipeline_create_info = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = shader_stages.len,
        .p_stages = &shader_stages,
        .p_vertex_input_state = &vertex_input_state,
        .p_input_assembly_state = &input_assembly_state,
        .p_tessellation_state = null,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &rasterization_state,
        .p_multisample_state = &multisample_state,
        .p_depth_stencil_state = depth_stencil_state,
        .p_color_blend_state = &color_blend_state,
        .p_dynamic_state = &dynamic_state,
        .layout = pipeline_layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = vk.Pipeline.null_handle,
        .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = undefined;
    _ = try ctx.vkd.createGraphicsPipelines(
        ctx.logical_device,
        pipeline_cache,
        1,
        @ptrCast([*]const vk.GraphicsPipelineCreateInfo, &pipeline_create_info),
        null,
        @ptrCast([*]vk.Pipeline, &pipeline),
    );
    errdefer ctx.vkd.destroyPipeline(ctx.logical_device, pipeline, null);

    const command_buffers = try render.pipeline.createCmdBuffers(allocator, ctx, ctx.gfx_cmd_pool, swapchain.images.len, null);
    errdefer {
        ctx.vkd.freeCommandBuffers(
            ctx.logical_device,
            ctx.gfx_cmd_pool,
            @intCast(u32, command_buffers.len),
            command_buffers.ptr,
        );
        allocator.free(command_buffers);
    }

    const framebuffers = try render.pipeline.createFramebuffers(allocator, ctx, &swapchain, render_pass, null);
    errdefer {
        for (framebuffers) |buffer| {
            ctx.vkd.destroyFramebuffer(ctx.logical_device, buffer, null);
        }
        allocator.free(framebuffers);
    }

    return GraphicsPipeline{
        .pipeline_cache = pipeline_cache,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .descriptor_set_layout = descriptor_set_layout,
        .descriptor_set = descriptor_set,
        .descriptor_pool = descriptor_pool,
        .current_frame = 0,
        .command_buffers = command_buffers,
        .framebuffers = framebuffers,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .shader_modules = [2]vk.ShaderModule{ vert.module, frag.module },
        .texture = texture,
    };
}

pub fn deinit(self: GraphicsPipeline, allocator: Allocator, ctx: Context) void {
    for (self.framebuffers) |buffer| {
        ctx.vkd.destroyFramebuffer(ctx.logical_device, buffer, null);
    }
    allocator.free(self.framebuffers);

    ctx.vkd.freeCommandBuffers(
        ctx.logical_device,
        ctx.gfx_cmd_pool,
        @intCast(u32, self.command_buffers.len),
        self.command_buffers.ptr,
    );
    allocator.free(self.command_buffers);
    ctx.vkd.destroyPipeline(ctx.logical_device, self.pipeline, null);
    ctx.vkd.destroyPipelineCache(ctx.logical_device, self.pipeline_cache, null);
    ctx.vkd.destroyShaderModule(ctx.logical_device, self.shader_modules[0], null);
    ctx.vkd.destroyShaderModule(ctx.logical_device, self.shader_modules[1], null);
    ctx.vkd.destroyPipelineLayout(ctx.logical_device, self.pipeline_layout, null);
    ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.descriptor_set_layout, null);
    ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.descriptor_pool, null);
    self.vertex_buffer.deinit(ctx);
    self.index_buffer.deinit(ctx);
}
