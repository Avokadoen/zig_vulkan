const std = @import("std");
const Allocator = std.mem.Allocator;

// based on sascha's imgui example

// this code does not use most of the codebase abstractions because a MVP is the goal and its
// easier to directly adapt the original code without out it :)

const zgui = @import("zgui");
const vk = @import("vulkan");
const za = @import("zalgebra");
const tracy = @import("ztracy");

const render = @import("../render.zig");
const GpuBufferMemory = render.GpuBufferMemory;
const StagingRamp = render.StagingRamp;
const Context = render.Context;
const Texture = render.Texture;

/// application imgui vulkan render wrapper
/// this should not be used directly by user code and should only be used by internal code
const ImguiPipeline = @This();

pub const PushConstant = struct {
    scale: [2]f32,
    translate: [2]f32,
};

sampler: vk.Sampler,

vertex_index_buffer_offset: vk.DeviceSize,
vertex_size: vk.DeviceSize,
vertex_buffer_len: c_int,
index_buffer_len: c_int,

font_image: vk.Image,
font_view: vk.ImageView,

pipeline_cache: vk.PipelineCache,
pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,
descriptor_pool: vk.DescriptorPool,
descriptor_set_layout: vk.DescriptorSetLayout,
descriptor_set: vk.DescriptorSet,

// shader modules stored for cleanup
shader_modules: [2]vk.ShaderModule,

pub fn init(
    ctx: Context,
    allocator: std.mem.Allocator,
    render_pass: vk.RenderPass,
    swapchain_image_count: usize,
    staging_buffers: *StagingRamp,
    vertex_index_buffer_offset: vk.DeviceSize,
    image_memory_type: u32,
    image_memory: vk.DeviceMemory,
    image_memory_capacity: vk.DeviceSize,
    image_memory_size: *vk.DeviceSize,
) !ImguiPipeline {
    // initialize zgui
    zgui.init(allocator);
    errdefer zgui.deinit();

    zgui.plot.init();
    errdefer zgui.plot.deinit();

    // Create font texture
    const text_data = zgui.io.getFontsTextDataAsRgba32();
    const pixels, const width, const height = unwrap_data_blk: {
        // TODO:
        // if (text_data.pixels) return error.FailedToGetFontsTextData;

        break :unwrap_data_blk .{
            text_data.pixels.?,
            text_data.width,
            text_data.height,
        };
    };

    const font_image = blk: {
        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = .{
                .width = @intCast(width),
                .height = @intCast(height),
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{
                .@"1_bit" = true,
            },
            .tiling = .optimal,
            .usage = .{
                .sampled_bit = true,
                .transfer_dst_bit = true,
            },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .initial_layout = .undefined,
        };
        break :blk try ctx.vkd.createImage(ctx.logical_device, &image_info, null);
    };
    errdefer ctx.vkd.destroyImage(ctx.logical_device, font_image, null);

    const memory_requirements = ctx.vkd.getImageMemoryRequirements(ctx.logical_device, font_image);
    const memory_type_index = try render.vk_utils.findMemoryTypeIndex(
        ctx,
        memory_requirements.memory_type_bits,
        .{ .device_local_bit = true },
    );
    // In the event that any of the asserts below fail, we should allocate more memory
    // we will not handle this for now, but a memory abstraction is needed sooner or later ...
    std.debug.assert(image_memory_type == memory_type_index);
    std.debug.assert(image_memory_size.* + memory_requirements.size < image_memory_capacity);
    try ctx.vkd.bindImageMemory(ctx.logical_device, font_image, image_memory, image_memory_size.*);
    image_memory_size.* += memory_requirements.size;

    const font_view = blk: {
        const view_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = font_image,
            .view_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        break :blk try ctx.vkd.createImageView(ctx.logical_device, &view_info, null);
    };
    errdefer ctx.vkd.destroyImageView(ctx.logical_device, font_view, null);

    // upload texture data to gpu
    try staging_buffers.transferToImage(
        ctx,
        .undefined,
        .shader_read_only_optimal,
        font_image,
        @intCast(width),
        @intCast(height),
        u32,
        pixels[0..@intCast(width * height)],
    );

    const sampler = blk: {
        const sampler_info = vk.SamplerCreateInfo{
            .flags = .{},
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0,
            .anisotropy_enable = vk.FALSE,
            .max_anisotropy = 0,
            .compare_enable = vk.FALSE,
            .compare_op = .never,
            .min_lod = 0,
            .max_lod = 0,
            .border_color = .float_opaque_white,
            .unnormalized_coordinates = vk.FALSE,
        };
        break :blk try ctx.vkd.createSampler(ctx.logical_device, &sampler_info, null);
    };
    errdefer ctx.vkd.destroySampler(ctx.logical_device, sampler, null);

    const descriptor_pool = blk: {
        const pool_sizes = [_]vk.DescriptorPoolSize{.{
            .type = .combined_image_sampler,
            .descriptor_count = 1, // TODO: swap image size ?
        }};
        const descriptor_pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = @intCast(swapchain_image_count),
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = @ptrCast(&pool_sizes),
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
            .p_bindings = @ptrCast(&set_layout_bindings),
        };
        break :blk try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &set_layout_info, null);
    };
    errdefer ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, descriptor_set_layout, null);

    const descriptor_set = blk: {
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
        };
        var descriptor_set_tmp: vk.DescriptorSet = undefined;
        try ctx.vkd.allocateDescriptorSets(
            ctx.logical_device,
            &alloc_info,
            @ptrCast(&descriptor_set_tmp),
        );
        break :blk descriptor_set_tmp;
    };

    {
        const descriptor_info = vk.DescriptorImageInfo{
            .sampler = sampler,
            .image_view = font_view,
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
        ctx.vkd.updateDescriptorSets(
            ctx.logical_device,
            write_descriptor_sets.len,
            @ptrCast(&write_descriptor_sets),
            0,
            undefined,
        );
    }

    const pipeline_cache = blk: {
        const pipeline_cache_info = vk.PipelineCacheCreateInfo{
            .flags = .{},
            .initial_data_size = 0,
            .p_initial_data = undefined,
        };
        break :blk try ctx.vkd.createPipelineCache(ctx.logical_device, &pipeline_cache_info, null);
    };
    errdefer ctx.vkd.destroyPipelineCache(ctx.logical_device, pipeline_cache, null);

    const pipeline_layout = blk: {
        const push_constant_range = vk.PushConstantRange{
            .stage_flags = .{ .vertex_bit = true },
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
    const blend_mode = vk.PipelineColorBlendAttachmentState{
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
        .p_attachments = @ptrCast(&blend_mode),
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
        const ui_vert_spv align(@alignOf(u32)) = @embedFile("ui_vert_spv").*;

        const create_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .p_code = @ptrCast(&ui_vert_spv),
            .code_size = ui_vert_spv.len,
        };
        const module = try ctx.vkd.createShaderModule(ctx.logical_device, &create_info, null);

        break :blk vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = .{ .vertex_bit = true },
            .module = module,
            .p_name = "main",
            .p_specialization_info = null,
        };
    };
    errdefer ctx.vkd.destroyShaderModule(ctx.logical_device, vert.module, null);

    const frag = blk: {
        const ui_frag_spv align(@alignOf(u32)) = @embedFile("ui_frag_spv").*;

        const create_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .p_code = @ptrCast(&ui_frag_spv),
            .code_size = ui_frag_spv.len,
        };
        const module = try ctx.vkd.createShaderModule(ctx.logical_device, &create_info, null);

        break :blk vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = .{ .fragment_bit = true },
            .module = module,
            .p_name = "main",
            .p_specialization_info = null,
        };
    };
    errdefer ctx.vkd.destroyShaderModule(ctx.logical_device, frag.module, null);
    const shader_stages = [_]vk.PipelineShaderStageCreateInfo{ vert, frag };

    const vertex_input_bindings = [_]vk.VertexInputBindingDescription{.{
        .binding = 0,
        .stride = @sizeOf(zgui.DrawVert),
        .input_rate = .vertex,
    }};
    const vertex_input_attributes = [_]vk.VertexInputAttributeDescription{ .{
        .location = 0,
        .binding = 0,
        .format = .r32g32_sfloat,
        .offset = @offsetOf(zgui.DrawVert, "pos"),
    }, .{
        .location = 1,
        .binding = 0,
        .format = .r32g32_sfloat,
        .offset = @offsetOf(zgui.DrawVert, "uv"),
    }, .{
        .location = 2,
        .binding = 0,
        .format = .r8g8b8a8_unorm,
        .offset = @offsetOf(zgui.DrawVert, "color"),
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
    _ = try ctx.vkd.createGraphicsPipelines(
        ctx.logical_device,
        pipeline_cache,
        1,
        @ptrCast(&pipeline_create_info),
        null,
        @ptrCast(&pipeline),
    );
    errdefer ctx.vkd.destroyPipeline(ctx.logical_device, pipeline, null);

    return ImguiPipeline{
        .sampler = sampler,
        .vertex_index_buffer_offset = vertex_index_buffer_offset,
        .vertex_size = 0,
        .vertex_buffer_len = 0,
        .index_buffer_len = 0,
        .font_image = font_image,
        .font_view = font_view,
        .pipeline_cache = pipeline_cache,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .descriptor_pool = descriptor_pool,
        .descriptor_set_layout = descriptor_set_layout,
        .descriptor_set = descriptor_set,
        .shader_modules = [2]vk.ShaderModule{ vert.module, frag.module },
    };
}

pub fn deinit(self: ImguiPipeline, ctx: Context) void {
    zgui.plot.deinit();
    zgui.deinit();

    ctx.vkd.destroyPipeline(ctx.logical_device, self.pipeline, null);
    ctx.vkd.destroyPipelineLayout(ctx.logical_device, self.pipeline_layout, null);
    ctx.vkd.destroyPipelineCache(ctx.logical_device, self.pipeline_cache, null);
    ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.descriptor_pool, null);
    ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.descriptor_set_layout, null);
    ctx.vkd.destroyShaderModule(ctx.logical_device, self.shader_modules[0], null);
    ctx.vkd.destroyShaderModule(ctx.logical_device, self.shader_modules[1], null);
    ctx.vkd.destroyImageView(ctx.logical_device, self.font_view, null);
    ctx.vkd.destroySampler(ctx.logical_device, self.sampler, null);
    ctx.vkd.destroyImage(ctx.logical_device, self.font_image, null);
}

/// record a command buffer that can draw current frame
pub fn recordCommandBuffer(
    self: ImguiPipeline,
    ctx: Context,
    command_buffer: vk.CommandBuffer,
    buffer_offset: vk.DeviceSize,
    vertex_index_buffer: GpuBufferMemory,
) !void {
    const record_zone = tracy.ZoneN(@src(), "imgui commands");
    defer record_zone.End();

    ctx.vkd.cmdBindDescriptorSets(
        command_buffer,
        .graphics,
        self.pipeline_layout,
        0,
        1,
        @ptrCast(&self.descriptor_set),
        0,
        undefined,
    );
    ctx.vkd.cmdBindPipeline(command_buffer, .graphics, self.pipeline);

    const display_size = zgui.io.getDisplaySize();
    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = display_size[0],
        .height = display_size[1],
        .min_depth = 0,
        .max_depth = 1,
    };
    ctx.vkd.cmdSetViewport(command_buffer, 0, 1, @ptrCast(&viewport));

    // UI scale and translate via push constants
    const push_constant = PushConstant{
        .scale = [2]f32{ 2 / display_size[0], 2 / display_size[1] },
        .translate = [2]f32{ -1, -1 },
    };
    ctx.vkd.cmdPushConstants(command_buffer, self.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(PushConstant), &push_constant);

    // Render commands
    const im_draw_data = zgui.getDrawData();
    var vertex_offset: c_uint = 0;
    var index_offset: c_uint = 0;

    if (im_draw_data.cmd_lists_count > 0) {
        const vertex_offsets = [_]vk.DeviceSize{buffer_offset};
        ctx.vkd.cmdBindVertexBuffers(
            command_buffer,
            0,
            1,
            @ptrCast(&vertex_index_buffer.buffer),
            &vertex_offsets,
        );
        ctx.vkd.cmdBindIndexBuffer(command_buffer, vertex_index_buffer.buffer, buffer_offset + self.vertex_size, .uint16);

        for (im_draw_data.cmd_lists.items[0..@intCast(im_draw_data.cmd_lists.len)]) |command_list| {
            const command_buffer_length = command_list.getCmdBufferLength();
            const command_buffer_data = command_list.getCmdBufferData();

            for (command_buffer_data[0..@intCast(command_buffer_length)]) |draw_command| {
                const scissor_rect = vk.Rect2D{
                    .offset = .{
                        .x = @intFromFloat(@max(draw_command.clip_rect[0], 0)),
                        .y = @intFromFloat(@max(draw_command.clip_rect[1], 0)),
                    },
                    .extent = .{
                        .width = @intFromFloat(draw_command.clip_rect[2] - draw_command.clip_rect[0]),
                        .height = @intFromFloat(draw_command.clip_rect[3] - draw_command.clip_rect[1]),
                    },
                };
                ctx.vkd.cmdSetScissor(command_buffer, 0, 1, @ptrCast(&scissor_rect));
                ctx.vkd.cmdDrawIndexed(
                    command_buffer,
                    draw_command.elem_count,
                    1,
                    @intCast(index_offset),
                    @intCast(vertex_offset),
                    0,
                );
                index_offset += draw_command.elem_count;
            }
            vertex_offset += @intCast(command_list.getVertexBufferLength());
        }
    }
}

// TODO: do not make new buffers if buffer is larger than total count
pub fn updateBuffers(
    self: *ImguiPipeline,
    ctx: Context,
    vertex_index_buffer: *GpuBufferMemory,
) !void {
    const update_buffers_zone = tracy.ZoneN(@src(), "imgui: vertex & index update");
    defer update_buffers_zone.End();

    const draw_data = zgui.getDrawData();
    if (draw_data.valid == false) {
        return;
    }

    self.vertex_size = @intCast(draw_data.total_vtx_count * @sizeOf(zgui.DrawVert));
    const index_size: vk.DeviceSize = @intCast(draw_data.total_idx_count * @sizeOf(zgui.DrawIdx));
    self.vertex_buffer_len = draw_data.total_vtx_count;
    self.index_buffer_len = draw_data.total_idx_count;
    if (index_size == 0 or self.vertex_size == 0) return; // nothing to draw
    std.debug.assert(self.vertex_size + index_size < vertex_index_buffer.size);

    try vertex_index_buffer.map(ctx, self.vertex_index_buffer_offset, self.vertex_size + index_size);
    defer vertex_index_buffer.unmap(ctx);

    const vertex_dest_align: [*]align(1) zgui.DrawVert = @ptrCast(vertex_index_buffer.mapped);
    var vertex_dest: [*]zgui.DrawVert = @alignCast(vertex_dest_align);
    var vertex_offset: usize = 0;

    // map index_dest to be the buffer memory + vertex byte offset
    const index_addr = @intFromPtr(vertex_index_buffer.mapped) + self.vertex_size;
    const index_dest_aling: [*]align(1) zgui.DrawIdx = @ptrCast(@as(?*anyopaque, @ptrFromInt(index_addr)));
    var index_dest: [*]zgui.DrawIdx = @alignCast(index_dest_aling);

    var index_offset: usize = 0;
    for (draw_data.cmd_lists.items[0..@intCast(draw_data.cmd_lists.len)]) |command_list| {
        // transfer vertex data
        {
            const vertex_buffer_length: usize = @intCast(command_list.getVertexBufferLength());
            const vertex_buffer_data = command_list.getVertexBufferData()[0..vertex_buffer_length];
            @memcpy(
                vertex_dest[vertex_offset .. vertex_offset + vertex_buffer_data.len],
                vertex_buffer_data,
            );
            vertex_offset += vertex_buffer_data.len;
        }

        // transfer index data
        {
            const index_buffer_length: usize = @intCast(command_list.getIndexBufferLength());
            const index_buffer_data = command_list.getIndexBufferData()[0..index_buffer_length];
            @memcpy(
                index_dest[index_offset .. index_offset + index_buffer_data.len],
                index_buffer_data,
            );
            index_offset += index_buffer_data.len;
        }
    }

    // send changes to GPU
    try vertex_index_buffer.flush(ctx, self.vertex_index_buffer_offset, self.vertex_size + index_size);
}
