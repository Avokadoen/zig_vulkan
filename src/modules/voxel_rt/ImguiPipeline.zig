const std = @import("std");
const Allocator = std.mem.Allocator;

// based on sascha's imgui example

// this code does not use most of the codebase abstractions because a MVP is the goal and its
// easier to directly adapt the original code without out it :)

/// gamekit imgui wrapper
const imgui = @import("imgui");
const vk = @import("vulkan");
const za = @import("zalgebra");
const tracy = @import("../../tracy.zig");

const render = @import("../render.zig");
const GpuBufferMemory = render.GpuBufferMemory;
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

vertex_buffer: GpuBufferMemory,
vertex_buffer_len: c_int,
index_buffer: GpuBufferMemory,
index_buffer_len: c_int,

font_memory: vk.DeviceMemory,
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

pub fn init(ctx: Context, allocator: Allocator, render_pass: vk.RenderPass, swapchain_image_count: usize) !ImguiPipeline {
    // initialize imgui
    _ = imgui.igCreateContext(null);
    var io = imgui.igGetIO();

    // Create font texture
    var width: i32 = undefined;
    var height: i32 = undefined;
    var bytes_per_pixel: i32 = undefined;
    var pixels: [*c]u8 = undefined;
    imgui.ImFontAtlas_GetTexDataAsRGBA32(io.Fonts, &pixels, &width, &height, &bytes_per_pixel);

    const font_image = blk: {
        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = .{
                .width = @intCast(u32, width),
                .height = @intCast(u32, height),
                .depth = @intCast(u32, 1),
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
            .initial_layout = .@"undefined",
        };
        break :blk try ctx.vkd.createImage(ctx.logical_device, &image_info, null);
    };
    errdefer ctx.vkd.destroyImage(ctx.logical_device, font_image, null);

    const font_memory = blk: {
        const memory_requirements = ctx.vkd.getImageMemoryRequirements(ctx.logical_device, font_image);
        const memory_type_index = try render.vk_utils.findMemoryTypeIndex(
            ctx,
            memory_requirements.memory_type_bits,
            .{ .device_local_bit = true },
        );
        const mem_alloc_info = vk.MemoryAllocateInfo{
            .allocation_size = memory_requirements.size,
            .memory_type_index = memory_type_index,
        };
        break :blk try ctx.vkd.allocateMemory(ctx.logical_device, &mem_alloc_info, null);
    };
    errdefer ctx.vkd.freeMemory(ctx.logical_device, font_memory, null);
    try ctx.vkd.bindImageMemory(ctx.logical_device, font_image, font_memory, 0);

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
    {
        const upload_size = width * height * bytes_per_pixel;
        var staging_buffer = try GpuBufferMemory.init(
            ctx,
            @intCast(u64, upload_size),
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging_buffer.deinit(ctx); // deinit buffer in any scope exit scenario

        try staging_buffer.transferToDevice(ctx, u8, 0, pixels[0..@intCast(usize, width * height * bytes_per_pixel)]);
        try Texture.transitionImageLayout(ctx, ctx.gfx_cmd_pool, font_image, .@"undefined", .transfer_dst_optimal);
        try Texture.copyBufferToImage(
            ctx,
            ctx.gfx_cmd_pool,
            font_image,
            staging_buffer.buffer,
            .{
                .width = @intCast(u32, width),
                .height = @intCast(u32, height),
            },
        );
        try Texture.transitionImageLayout(ctx, ctx.gfx_cmd_pool, font_image, .transfer_dst_optimal, .shader_read_only_optimal);
    }

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
            .@"type" = .combined_image_sampler,
            .descriptor_count = 1, // TODO: swap image size ?
        }};
        const descriptor_pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = @intCast(u32, swapchain_image_count),
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = @ptrCast([*]const vk.DescriptorPoolSize, &pool_sizes),
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
            .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, &set_layout_bindings),
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
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &descriptor_set_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast([*]const vk.PushConstantRange, &push_constant_range),
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
        .p_attachments = @ptrCast([*]const vk.PipelineColorBlendAttachmentState, &blend_mode),
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

    const vert = try render.pipeline.loadShaderStage(ctx, allocator, null, "ui.vert.spv", .{ .vertex_bit = true }, null);
    errdefer ctx.vkd.destroyShaderModule(ctx.logical_device, vert.module, null);
    const frag = try render.pipeline.loadShaderStage(ctx, allocator, null, "ui.frag.spv", .{ .fragment_bit = true }, null);
    errdefer ctx.vkd.destroyShaderModule(ctx.logical_device, frag.module, null);
    const shader_stages = [_]vk.PipelineShaderStageCreateInfo{ vert, frag };

    const vertex_input_bindings = [_]vk.VertexInputBindingDescription{.{
        .binding = 0,
        .stride = @sizeOf(imgui.ImDrawVert),
        .input_rate = .vertex,
    }};
    const vertex_input_attributes = [_]vk.VertexInputAttributeDescription{ .{
        .location = 0,
        .binding = 0,
        .format = .r32g32_sfloat,
        .offset = @offsetOf(imgui.ImDrawVert, "pos"),
    }, .{
        .location = 1,
        .binding = 0,
        .format = .r32g32_sfloat,
        .offset = @offsetOf(imgui.ImDrawVert, "uv"),
    }, .{
        .location = 2,
        .binding = 0,
        .format = .r8g8b8a8_unorm,
        .offset = @offsetOf(imgui.ImDrawVert, "col"),
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
        @ptrCast([*]const vk.GraphicsPipelineCreateInfo, &pipeline_create_info),
        null,
        @ptrCast([*]vk.Pipeline, &pipeline),
    );
    errdefer ctx.vkd.destroyPipeline(ctx.logical_device, pipeline, null);

    return ImguiPipeline{
        .sampler = sampler,
        .vertex_buffer = GpuBufferMemory.@"undefined"(),
        .vertex_buffer_len = 0,
        .index_buffer = GpuBufferMemory.@"undefined"(),
        .index_buffer_len = 0,
        .font_memory = font_memory,
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
    ctx.vkd.freeMemory(ctx.logical_device, self.font_memory, null);

    self.vertex_buffer.deinit(ctx);
    self.index_buffer.deinit(ctx);
}

/// record a command buffer that can draw current frame
pub fn recordCommandBuffer(self: ImguiPipeline, ctx: Context, command_buffer: vk.CommandBuffer) !void {
    const record_zone = tracy.ZoneN(@src(), "imgui commands");
    defer record_zone.End();

    var io = imgui.igGetIO();

    ctx.vkd.cmdBindDescriptorSets(
        command_buffer,
        .graphics,
        self.pipeline_layout,
        0,
        1,
        @ptrCast([*]const vk.DescriptorSet, &self.descriptor_set),
        0,
        undefined,
    );
    ctx.vkd.cmdBindPipeline(command_buffer, .graphics, self.pipeline);
    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = io.DisplaySize.x,
        .height = io.DisplaySize.y,
        .min_depth = 0,
        .max_depth = 1,
    };
    ctx.vkd.cmdSetViewport(command_buffer, 0, 1, @ptrCast([*]const vk.Viewport, &viewport));

    // UI scale and translate via push constants
    const push_constant = PushConstant{
        .scale = [2]f32{ 2 / io.DisplaySize.x, 2 / io.DisplaySize.y },
        .translate = [2]f32{ -1, -1 },
    };
    ctx.vkd.cmdPushConstants(command_buffer, self.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(PushConstant), &push_constant);

    // Render commands
    const im_draw_data = imgui.igGetDrawData();
    var vertex_offset: c_uint = 0;
    var index_offset: c_uint = 0;

    if (im_draw_data.CmdListsCount > 0) {
        const offsets = [_]vk.DeviceSize{0};
        ctx.vkd.cmdBindVertexBuffers(
            command_buffer,
            0,
            1,
            @ptrCast([*]const vk.Buffer, &self.vertex_buffer.buffer),
            &offsets,
        );
        ctx.vkd.cmdBindIndexBuffer(command_buffer, self.index_buffer.buffer, 0, .uint16);

        const draw_cmd_list_count = @intCast(usize, im_draw_data.CmdListsCount);
        var i: usize = 0;
        while (i < draw_cmd_list_count) : (i += 1) {
            const cmd_list = im_draw_data.CmdLists[i];
            const cmd_draw_size = @intCast(usize, cmd_list.CmdBuffer.Size);
            var j: usize = 0;
            while (j < cmd_draw_size) : (j += 1) {
                const draw_cmd = &cmd_list.CmdBuffer.Data[j];
                const scissor_rect = vk.Rect2D{
                    .offset = .{
                        .x = std.math.max(@floatToInt(i32, draw_cmd.ClipRect.x), 0),
                        .y = std.math.max(@floatToInt(i32, draw_cmd.ClipRect.y), 0),
                    },
                    .extent = .{
                        .width = @floatToInt(u32, draw_cmd.ClipRect.z - draw_cmd.ClipRect.x),
                        .height = @floatToInt(u32, draw_cmd.ClipRect.w - draw_cmd.ClipRect.y),
                    },
                };
                ctx.vkd.cmdSetScissor(command_buffer, 0, 1, @ptrCast([*]const vk.Rect2D, &scissor_rect));
                ctx.vkd.cmdDrawIndexed(
                    command_buffer,
                    draw_cmd.ElemCount,
                    1,
                    @intCast(u32, index_offset),
                    @intCast(i32, vertex_offset),
                    0,
                );
                index_offset += draw_cmd.ElemCount;
            }
            vertex_offset += @intCast(c_uint, cmd_list.VtxBuffer.Size);
        }
    }
}

// TODO: do not make new buffers if buffer is larger than total count
pub fn updateBuffers(self: *ImguiPipeline, ctx: Context) !void {
    const update_buffers_zone = tracy.ZoneN(@src(), "imgui: vertex & index update");
    defer update_buffers_zone.End();

    const draw_data = imgui.igGetDrawData();

    const vertex_buffer_size = draw_data.TotalVtxCount * @sizeOf(imgui.ImDrawVert);
    const index_buffer_size = draw_data.TotalIdxCount * @sizeOf(imgui.ImDrawIdx);
    if (index_buffer_size == 0 or vertex_buffer_size == 0) return; // nothing to draw

    { // update vertex buffer size accordingly
        if (self.vertex_buffer.buffer == .null_handle or self.vertex_buffer_len != draw_data.TotalVtxCount) {
            self.vertex_buffer.unmap(ctx);
            self.vertex_buffer.deinit(ctx);
            self.vertex_buffer = try GpuBufferMemory.init(
                ctx,
                @intCast(vk.DeviceSize, vertex_buffer_size),
                .{ .vertex_buffer_bit = true },
                .{ .host_visible_bit = true },
            );
            self.vertex_buffer_len = draw_data.TotalVtxCount;
            try self.vertex_buffer.map(ctx, 0, vk.WHOLE_SIZE);
        }
    }
    { // update index buffer size accordingly
        if (self.index_buffer.buffer == .null_handle or self.index_buffer_len != draw_data.TotalIdxCount) {
            self.index_buffer.unmap(ctx);
            self.index_buffer.deinit(ctx);
            self.index_buffer = try GpuBufferMemory.init(
                ctx,
                @intCast(vk.DeviceSize, index_buffer_size),
                .{ .index_buffer_bit = true },
                .{ .host_visible_bit = true },
            );
            self.index_buffer_len = draw_data.TotalIdxCount;
            try self.index_buffer.map(ctx, 0, vk.WHOLE_SIZE);
        }
    }

    var vertex_dest = @ptrCast([*]imgui.ImDrawVert, @alignCast(@alignOf(imgui.ImDrawVert), self.vertex_buffer.mapped) orelse unreachable);
    var vertex_offset: usize = 0;

    var index_dest = @ptrCast([*]imgui.ImDrawIdx, @alignCast(@alignOf(imgui.ImDrawIdx), self.index_buffer.mapped) orelse unreachable);
    var index_offset: usize = 0;

    var i: usize = 0;
    const cmd_list_count = draw_data.CmdListsCount;
    {
        // runtime safety is turned off for performance
        @setRuntimeSafety(false);
        while (i < cmd_list_count) : (i += 1) {
            const cmd_list = draw_data.CmdLists[i];

            // transfer vertex data
            var j: usize = 0;
            const vertex_count = @intCast(usize, cmd_list.VtxBuffer.Size);
            while (j < vertex_count) : (j += 1) {
                vertex_dest[vertex_offset + j] = cmd_list.VtxBuffer.Data[j];
            }
            vertex_offset += vertex_count;

            // transfer index data
            j = 0;
            const index_count = @intCast(usize, cmd_list.IdxBuffer.Size);
            while (j < index_count) : (j += 1) {
                index_dest[index_offset + j] = cmd_list.IdxBuffer.Data[j];
            }
            index_offset += index_count;
        }
    }

    // send changes to GPU
    try self.vertex_buffer.flush(ctx, 0, vk.WHOLE_SIZE);
    try self.index_buffer.flush(ctx, 0, vk.WHOLE_SIZE);
}
