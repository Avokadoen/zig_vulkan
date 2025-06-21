const std = @import("std");
const vk = @import("vulkan");

const vk_utils = @import("vk_utils.zig");
const GpuBufferMemory = @import("GpuBufferMemory.zig");
const Context = @import("Context.zig");
const Allocator = std.mem.Allocator;

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

pub const TransitionConfig = struct {
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_queue_family_index: u32 = vk.QUEUE_FAMILY_IGNORED,
    dst_queue_family_index: u32 = vk.QUEUE_FAMILY_IGNORED,
};
pub fn transitionImageLayouts(
    ctx: Context,
    command_pool: vk.CommandPool,
    configs: []const TransitionConfig,
) !void {
    const commmand_buffer = try vk_utils.beginOneTimeCommandBuffer(ctx, command_pool);

    for (configs) |config| {
        const transition = getTransitionBits(config.old_layout, config.new_layout);
        const barrier = vk.ImageMemoryBarrier{
            .src_access_mask = transition.src_mask,
            .dst_access_mask = transition.dst_mask,
            .old_layout = config.old_layout,
            .new_layout = config.new_layout,
            .src_queue_family_index = config.src_queue_family_index,
            .dst_queue_family_index = config.dst_queue_family_index,
            .image = config.image,
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
    }
    try vk_utils.endOneTimeCommandBuffer(ctx, command_pool, commmand_buffer);
}

pub fn copyBufferToImage(ctx: Context, command_pool: vk.CommandPool, image: vk.Image, buffer: vk.Buffer, image_extent: vk.Extent2D) !void {
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
