const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const render = @import("../render.zig");
const context = render.context;
const GpuBufferMemory = render.gpu_buffer_memory.components.GpuBufferMemory;
const SwapchainData = render.swapchain.components.SwapchainData;
const memory = render.memory;

const Vertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
};

pub const vertex_size = vertices.len * @sizeOf(Vertex);
pub const indices_size = indices.len * @sizeOf(u16);
pub const vertices = [_]Vertex{
    .{ .pos = .{ 1.0, 1.0, 0.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .pos = .{ -1.0, 1.0, 0.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .pos = .{ -1.0, -1.0, 0.0 }, .uv = .{ 0.0, 0.0 } },
    .{ .pos = .{ 1.0, -1.0, 0.0 }, .uv = .{ 1.0, 0.0 } },
};
pub const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };

pub const PushConstant = extern struct {
    samples: i32,
    distribution_bias: f32,
    pixel_multiplier: f32,
    inverse_hue_tolerance: f32,
};

pub const Config = struct {
    samples: i32 = 20, // HIGHER = NICER = SLOWER
    distribution_bias: f32 = 0.6, // between 0. and 1.
    pixel_multiplier: f32 = 1.5, // between 1. and 3. (keep low)
    inverse_hue_tolerance: f32 = 20, // (2. - 30.)
};

/// Pipeline to draw a single texture to screen
const GraphicsPipeline = @This();

bytes_used_in_buffer: vk.DeviceSize,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

descriptor_set_layout: vk.DescriptorSetLayout,
descriptor_set: vk.DescriptorSet,
descriptor_pool: vk.DescriptorPool,

current_frame: usize,
command_pools: []vk.CommandPool,
command_buffers: []vk.CommandBuffer,
framebuffers: []vk.Framebuffer,

shader_constants: *PushConstant,

pub fn init(
    allocator: Allocator,
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.Device,
    physical_device_properties: context.components.PhysicalDeviceProperties,
    queue_indices: context.components.QueueFamilyIndices,
    swapchain: SwapchainData,
    render_pass: vk.RenderPass,
    draw_sampler: vk.Sampler,
    draw_image_view: vk.ImageView,
    vertex_index_buffer: *GpuBufferMemory,
    config: Config,
) !GraphicsPipeline {
    const bytes_used_in_buffer = memory.nonCoherentAtomSize(physical_device_properties, vertex_size * indices_size);
    if (bytes_used_in_buffer > vertex_index_buffer.capacity) {
        return error.OutOfDeviceMemory;
    }

    const dev_vertices = vertex_index_buffer.typedMapAssumeMapped(Vertex, 0);
    @memcpy(dev_vertices[0..vertices.len], &vertices);

    const dev_indices = vertex_index_buffer.typedMapAssumeMapped(u16, vertex_size);
    @memcpy(dev_indices[0..indices.len], &indices);

    const descriptor_pool = blk: {
        const pool_sizes = [_]vk.DescriptorPoolSize{.{
            .type = .combined_image_sampler,
            .descriptor_count = 1, // TODO: swap image size ?
        }};
        const descriptor_pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = @intCast(swapchain.image_len),
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
        };
        break :blk try vkd.createDescriptorPool(logical_device.v, &descriptor_pool_info, null);
    };
    errdefer vkd.destroyDescriptorPool(logical_device.v, descriptor_pool, null);

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
        break :blk try vkd.createDescriptorSetLayout(logical_device.v, &set_layout_info, null);
    };
    errdefer vkd.destroyDescriptorSetLayout(logical_device.v, descriptor_set_layout, null);

    const descriptor_set = blk: {
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
        };
        var descriptor_set_tmp: vk.DescriptorSet = undefined;
        try vkd.allocateDescriptorSets(
            logical_device.v,
            &alloc_info,
            @ptrCast(&descriptor_set_tmp),
        );
        break :blk descriptor_set_tmp;
    };
    errdefer vkd.freeDescriptorSets(
        logical_device.v,
        descriptor_pool,
        1,
        @ptrCast(&descriptor_set),
    ) catch {};

    {
        const descriptor_info = vk.DescriptorImageInfo{
            .sampler = draw_sampler,
            .image_view = draw_image_view,
            .image_layout = .shader_read_only_optimal,
        };
        const write_descriptor_sets = [_]vk.WriteDescriptorSet{.{
            .dst_set = descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&descriptor_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }};
        vkd.updateDescriptorSets(
            logical_device.v,
            write_descriptor_sets.len,
            @ptrCast(&write_descriptor_sets),
            0,
            undefined,
        );
    }

    const pipeline_layout = blk: {
        const push_constant_range = vk.PushConstantRange{
            .stage_flags = .{ .fragment_bit = true },
            .offset = 0,
            .size = @sizeOf(PushConstant),
        };
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_constant_range),
        };
        break :blk try vkd.createPipelineLayout(logical_device.v, &pipeline_layout_info, null);
    };
    errdefer vkd.destroyPipelineLayout(logical_device.v, pipeline_layout, null);

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
        .p_attachments = @ptrCast(&blend_attachment_state),
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

    const vert = blk: {
        const image_vert_spv align(@alignOf(u32)) = @embedFile("image_vert_spv").*;

        const create_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .p_code = @ptrCast(&image_vert_spv),
            .code_size = image_vert_spv.len,
        };
        const module = try vkd.createShaderModule(logical_device.v, &create_info, null);

        break :blk vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = .{ .vertex_bit = true },
            .module = module,
            .p_name = "main",
            .p_specialization_info = null,
        };
    };
    defer vkd.destroyShaderModule(logical_device.v, vert.module, null);
    const frag = blk: {
        const image_frag_spv align(@alignOf(u32)) = @embedFile("image_frag_spv").*;

        const create_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .p_code = @ptrCast(&image_frag_spv),
            .code_size = image_frag_spv.len,
        };
        const module = try vkd.createShaderModule(logical_device.v, &create_info, null);

        break :blk vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = .{ .fragment_bit = true },
            .module = module,
            .p_name = "main",
            .p_specialization_info = null,
        };
    };
    defer vkd.destroyShaderModule(logical_device.v, frag.module, null);
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
    _ = try vkd.createGraphicsPipelines(
        logical_device.v,
        .null_handle,
        1,
        @ptrCast(&pipeline_create_info),
        null,
        @ptrCast(&pipeline),
    );
    errdefer vkd.destroyPipeline(logical_device.v, pipeline, null);

    const pool_info = vk.CommandPoolCreateInfo{
        .flags = .{ .transient_bit = true },
        .queue_family_index = queue_indices.graphics,
    };
    const command_pools = try allocator.alloc(vk.CommandPool, swapchain.image_len);
    errdefer allocator.free(command_pools);
    const command_buffers = try allocator.alloc(vk.CommandBuffer, swapchain.image_len);
    errdefer allocator.free(command_buffers);
    var initialized_pools: usize = 0;
    var initialized_buffers: usize = 0;
    for (command_pools, 0..) |*command_pool, i| {
        command_pool.* = try vkd.createCommandPool(logical_device.v, &pool_info, null);
        initialized_pools = i + 1;
        command_buffers[i] = try render.pipeline.createCmdBuffer(vkd, logical_device, command_pool.*);
        initialized_buffers = i + 1;
    }
    errdefer {
        var i: usize = 0;
        while (i < initialized_buffers) : (i += 1) {
            vkd.freeCommandBuffers(
                logical_device.v,
                command_pools[i],
                1,
                @ptrCast(&command_buffers[i]),
            );
        }
        i = 0;
        while (i < initialized_pools) : (i += 1) {
            vkd.destroyCommandPool(logical_device.v, command_pools[i], null);
        }
    }

    const framebuffers = try render.pipeline.createFramebuffers(
        allocator,
        vkd,
        logical_device,
        &swapchain,
        render_pass,
        null,
    );
    errdefer {
        for (framebuffers) |buffer| {
            vkd.destroyFramebuffer(logical_device.v, buffer, null);
        }
        allocator.free(framebuffers);
    }

    const shader_constants = try allocator.create(PushConstant);
    shader_constants.* = .{
        .samples = config.samples,
        .distribution_bias = config.distribution_bias,
        .pixel_multiplier = config.pixel_multiplier,
        .inverse_hue_tolerance = config.inverse_hue_tolerance,
    };

    return GraphicsPipeline{
        .bytes_used_in_buffer = bytes_used_in_buffer,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .descriptor_set_layout = descriptor_set_layout,
        .descriptor_set = descriptor_set,
        .descriptor_pool = descriptor_pool,
        .current_frame = 0,
        .command_pools = command_pools,
        .command_buffers = command_buffers,
        .framebuffers = framebuffers,
        .shader_constants = shader_constants,
    };
}

pub fn deinit(
    self: GraphicsPipeline,
    allocator: Allocator,
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.Device,
) void {
    for (self.framebuffers) |buffer| {
        vkd.destroyFramebuffer(logical_device.v, buffer, null);
    }
    allocator.free(self.framebuffers);

    for (self.command_buffers, 0..) |command_buffer, i| {
        vkd.freeCommandBuffers(
            logical_device.v,
            self.command_pools[i],
            1,
            @ptrCast(&command_buffer),
        );
    }
    for (self.command_pools) |command_pool| {
        vkd.destroyCommandPool(logical_device.v, command_pool, null);
    }
    allocator.free(self.command_pools);
    allocator.free(self.command_buffers);

    vkd.destroyPipeline(logical_device.v, self.pipeline, null);
    vkd.destroyPipelineLayout(logical_device.v, self.pipeline_layout, null);
    vkd.destroyDescriptorSetLayout(logical_device.v, self.descriptor_set_layout, null);
    vkd.destroyDescriptorPool(logical_device.v, self.descriptor_pool, null);

    allocator.destroy(self.shader_constants);
}
