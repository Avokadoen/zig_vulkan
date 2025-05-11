const std = @import("std");
const vk = @import("vulkan");

const vk_utils = @import("vk_utils.zig");
const GpuBufferMemory = @import("GpuBufferMemory.zig");
const Context = @import("Context.zig");
const Allocator = std.mem.Allocator;

pub fn Config(comptime T: type) type {
    return struct {
        data: ?[]T,
        width: u32,
        height: u32,
        usage: vk.ImageUsageFlags,
        queue_family_indices: []const u32,
        format: vk.Format,
    };
}

const Texture = @This();

image_size: vk.DeviceSize,
image_extent: vk.Extent2D,

image: vk.Image,
image_view: vk.ImageView,
image_memory: vk.DeviceMemory,
format: vk.Format,
sampler: vk.Sampler,
layout: vk.ImageLayout,

// TODO: comptime send_to_device: bool to disable all useless transfer
pub fn init(ctx: Context, command_pool: vk.CommandPool, layout: vk.ImageLayout, comptime T: type, config: Config(T)) !Texture {
    const image_extent = vk.Extent2D{
        .width = config.width,
        .height = config.height,
    };

    const image = blk: {
        // TODO: make sure we use correct usage bits https://www.khronos.org/registry/vulkan/specs/1.2-extensions/man/html/VkImageUsageFlagBits.html
        // TODO: VK_IMAGE_CREATE_SPARSE_BINDING_BIT
        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = config.format,
            .extent = vk.Extent3D{
                .width = config.width,
                .height = config.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{
                .@"1_bit" = true,
            },
            .tiling = .optimal,
            .usage = config.usage,
            .sharing_mode = .exclusive, // TODO: concurrent if (queue_family_indices.len > 1)
            .queue_family_index_count = @intCast(config.queue_family_indices.len),
            .p_queue_family_indices = config.queue_family_indices.ptr,
            .initial_layout = .undefined,
        };
        break :blk try ctx.vkd.createImage(ctx.logical_device, &image_info, null);
    };

    const image_memory = blk: {
        const memory_requirements = ctx.vkd.getImageMemoryRequirements(ctx.logical_device, image);
        const alloc_info = vk.MemoryAllocateInfo{
            .allocation_size = memory_requirements.size,
            .memory_type_index = try vk_utils.findMemoryTypeIndex(ctx, memory_requirements.memory_type_bits, .{
                .device_local_bit = true,
            }),
        };
        break :blk try ctx.vkd.allocateMemory(ctx.logical_device, &alloc_info, null);
    };

    try ctx.vkd.bindImageMemory(ctx.logical_device, image, image_memory, 0);

    // TODO: set size according to image format
    const image_size: vk.DeviceSize = @intCast(config.width * config.height * @sizeOf(f32));

    // transfer texture data to gpu
    if (config.data) |data| {
        var staging_buffer = try GpuBufferMemory.init(ctx, image_size, .{
            .transfer_src_bit = true,
        }, .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        });
        defer staging_buffer.deinit(ctx);
        try staging_buffer.transferToDevice(ctx, T, 0, data);

        try transitionImageLayout(ctx, command_pool, image, .undefined, .transfer_dst_optimal);
        try copyBufferToImage(ctx, command_pool, image, staging_buffer.buffer, image_extent);
        try transitionImageLayout(ctx, command_pool, image, .transfer_dst_optimal, layout);
    } else {
        try transitionImageLayout(ctx, command_pool, image, .undefined, layout);
    }

    const image_view = blk: {
        // TODO: evaluate if this and swapchain should share logic (probably no)
        const image_view_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = config.format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{
                    .color_bit = true,
                },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        break :blk try ctx.vkd.createImageView(ctx.logical_device, &image_view_info, null);
    };

    const sampler = blk: {
        // const device_properties = ctx.vki.getPhysicalDeviceProperties(ctx.physical_device);
        const sampler_info = vk.SamplerCreateInfo{
            .flags = .{},
            .mag_filter = .linear, // not sure what the application would need
            .min_filter = .linear, // RT should use linear, pixel sim should be nearest
            .mipmap_mode = .linear,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .mip_lod_bias = 0.0,
            .anisotropy_enable = vk.FALSE, // TODO: test with, and without
            .max_anisotropy = 1.0, // device_properties.limits.max_sampler_anisotropy,
            .compare_enable = vk.FALSE,
            .compare_op = .always,
            .min_lod = 0.0,
            .max_lod = 0.0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = vk.FALSE, // TODO: might be good for pixel sim to use true
        };
        break :blk try ctx.vkd.createSampler(ctx.logical_device, &sampler_info, null);
    };

    return Texture{
        .image_size = image_size,
        .image_extent = image_extent,
        .image = image,
        .image_view = image_view,
        .image_memory = image_memory,
        .format = config.format,
        .sampler = sampler,
        .layout = layout,
    };
}

pub fn deinit(self: Texture, ctx: Context) void {
    ctx.vkd.destroySampler(ctx.logical_device, self.sampler, null);
    ctx.vkd.destroyImageView(ctx.logical_device, self.image_view, null);
    ctx.vkd.destroyImage(ctx.logical_device, self.image, null);
    ctx.vkd.freeMemory(ctx.logical_device, self.image_memory, null);
}

pub fn copyToHost(self: Texture, command_pool: vk.CommandPool, ctx: Context, comptime T: type, buffer: []T) !void {
    var staging_buffer = try GpuBufferMemory.init(ctx, self.image_size, .{
        .transfer_dst_bit = true,
    }, .{
        .host_visible_bit = true,
        .host_coherent_bit = true,
    });
    defer staging_buffer.deinit(ctx);

    try transitionImageLayout(ctx, command_pool, self.image, self.layout, .transfer_src_optimal);
    const command_buffer = try vk_utils.beginOneTimeCommandBuffer(ctx, command_pool);
    {
        const region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = vk.ImageSubresourceLayers{
                .aspect_mask = .{
                    .color_bit = true,
                },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{
                .x = 0,
                .y = 0,
                .z = 0,
            },
            .image_extent = .{
                .width = self.image_extent.width,
                .height = self.image_extent.height,
                .depth = 1,
            },
        };
        ctx.vkd.cmdCopyImageToBuffer(command_buffer, self.image, .transfer_src_optimal, staging_buffer.buffer, 1, @ptrCast(&region));
    }
    try vk_utils.endOneTimeCommandBuffer(ctx, command_pool, command_buffer);
    try transitionImageLayout(ctx, command_pool, self.image, .transfer_src_optimal, self.layout);

    try staging_buffer.transferFromDevice(ctx, T, buffer);
}

const TransitionBits = struct {
    src_mask: vk.AccessFlags,
    dst_mask: vk.AccessFlags,
    src_stage: vk.PipelineStageFlags,
    dst_stage: vk.PipelineStageFlags,
};
pub fn getTransitionBits(old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) TransitionBits {
    var transition_bits: TransitionBits = undefined;
    switch (old_layout) {
        .undefined => {
            transition_bits.src_mask = .{};
            transition_bits.src_stage = .{
                .top_of_pipe_bit = true,
            };
        },
        .general => {
            transition_bits.src_mask = .{
                .shader_read_bit = true,
                .shader_write_bit = true,
            };
            transition_bits.src_stage = .{
                .compute_shader_bit = true,
            };
        },
        .shader_read_only_optimal => {
            transition_bits.src_mask = .{
                .shader_read_bit = true,
            };
            transition_bits.src_stage = .{
                .fragment_shader_bit = true,
            };
        },
        .transfer_dst_optimal => {
            transition_bits.src_mask = .{
                .transfer_write_bit = true,
            };
            transition_bits.src_stage = .{
                .transfer_bit = true,
            };
        },
        .transfer_src_optimal => {
            transition_bits.src_mask = .{
                .transfer_read_bit = true,
            };
            transition_bits.src_stage = .{
                .transfer_bit = true,
            };
        },
        else => {
            // TODO return error
            std.debug.panic("illegal old layout", .{});
        },
    }
    switch (new_layout) {
        .undefined => {
            transition_bits.dst_mask = .{};
            transition_bits.dst_stage = .{
                .top_of_pipe_bit = true,
            };
        },
        .present_src_khr => {
            transition_bits.dst_mask = .{};
            transition_bits.dst_stage = .{
                .fragment_shader_bit = true,
            };
        },
        .general => {
            transition_bits.dst_mask = .{
                .shader_read_bit = true,
            };
            transition_bits.dst_stage = .{
                .fragment_shader_bit = true,
            };
        },
        .shader_read_only_optimal => {
            transition_bits.dst_mask = .{
                .shader_read_bit = true,
            };
            transition_bits.dst_stage = .{
                .fragment_shader_bit = true,
            };
        },
        .transfer_dst_optimal => {
            transition_bits.dst_mask = .{
                .transfer_write_bit = true,
            };
            transition_bits.dst_stage = .{
                .transfer_bit = true,
            };
        },
        .transfer_src_optimal => {
            transition_bits.dst_mask = .{
                .transfer_read_bit = true,
            };
            transition_bits.dst_stage = .{
                .transfer_bit = true,
            };
        },
        else => {
            // TODO return error
            std.debug.panic("illegal new layout", .{});
        },
    }
    return transition_bits;
}

pub inline fn transitionImageLayout(ctx: Context, command_pool: vk.CommandPool, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) !void {
    const commmand_buffer = try vk_utils.beginOneTimeCommandBuffer(ctx, command_pool);
    const transition = getTransitionBits(old_layout, new_layout);
    const barrier = vk.ImageMemoryBarrier{
        .src_access_mask = transition.src_mask,
        .dst_access_mask = transition.dst_mask,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = vk.ImageSubresourceRange{
            .aspect_mask = .{
                .color_bit = true,
            },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    ctx.vkd.cmdPipelineBarrier(commmand_buffer, transition.src_stage, transition.dst_stage, vk.DependencyFlags{}, 0, undefined, 0, undefined, 1, @ptrCast(&barrier));
    try vk_utils.endOneTimeCommandBuffer(ctx, command_pool, commmand_buffer);
}

pub inline fn copyBufferToImage(ctx: Context, command_pool: vk.CommandPool, image: vk.Image, buffer: vk.Buffer, image_extent: vk.Extent2D) !void {
    const command_buffer = try vk_utils.beginOneTimeCommandBuffer(ctx, command_pool);
    {
        const region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = vk.ImageSubresourceLayers{
                .aspect_mask = .{
                    .color_bit = true,
                },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{
                .x = 0,
                .y = 0,
                .z = 0,
            },
            .image_extent = .{
                .width = image_extent.width,
                .height = image_extent.height,
                .depth = 1,
            },
        };
        ctx.vkd.cmdCopyBufferToImage(command_buffer, buffer, image, .transfer_dst_optimal, 1, @ptrCast(&region));
    }
    try vk_utils.endOneTimeCommandBuffer(ctx, command_pool, command_buffer);
}
