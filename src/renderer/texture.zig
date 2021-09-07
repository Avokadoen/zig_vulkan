const std = @import("std");
const stbi = @import("stbi");
const vk = @import("vulkan");

const vk_utils = @import("vk_utils.zig");
const GpuBufferMemory = @import("gpu_buffer_memory.zig").GpuBufferMemory;
const Context = @import("context.zig").Context;
const Allocator = std.mem.Allocator;

pub const Texture = struct {

    texture_size: vk.DeviceSize,
    image: vk.Image,
    image_memory: vk.DeviceMemory,
    format: vk.Format,

    /// caller has to make sure to call deinit
    pub fn from_file(ctx: Context, allocator: *Allocator,  command_pool: vk.CommandPool, path: []const u8) !Texture {
        // load image from file
        const stb_image = try stbi.Image.init(allocator, path, stbi.DesiredChannels.STBI_rgb_alpha);
        defer stb_image.deinit();

        // transfer texture data to gpu
        const image_size = stb_image.data.len * @sizeOf(stbi.Pixel);
        const texture_size: vk.DeviceSize = @intCast(vk.DeviceSize, image_size);
        const staging_buffer = try GpuBufferMemory.init(ctx, texture_size, .{ .transfer_src_bit = true, }, .{ .host_visible_bit = true, .host_coherent_bit = true, });
        defer staging_buffer.deinit();

        try staging_buffer.bind();
        try staging_buffer.transferData(stbi.Pixel, stb_image.data);

        const indices = ctx.queue_indices;
        const queue_family_indices = [_]u32{ indices.present, indices.graphics, indices.compute };
        const format = .r8g8b8a8_srgb; // reflect stbi.DesiredChannels.STBI_rgb_alpha
        // TODO: make sure we use correct usage bits https://www.khronos.org/registry/vulkan/specs/1.2-extensions/man/html/VkImageUsageFlagBits.html
        // TODO: VK_IMAGE_CREATE_SPARSE_BINDING_BIT
        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = format,
            .extent = vk.Extent3D{
                .width = @intCast(u32, stb_image.width),
                .height = @intCast(u32, stb_image.height),
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true, },
            .tiling = .optimal,
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true, }, 
            .sharing_mode = .exclusive, // TODO: concurrent :( especially for compute shader
            .queue_family_index_count = queue_family_indices.len,
            .p_queue_family_indices = &queue_family_indices,
            .initial_layout = .@"undefined",
        };
        const image = try ctx.vkd.createImage(ctx.logical_device, image_info, null);

        const memory_requirements = ctx.vkd.getImageMemoryRequirements(ctx.logical_device, image);
        const alloc_info = vk.MemoryAllocateInfo{
            .allocation_size = memory_requirements.size,
            .memory_type_index = try vk_utils.findMemoryTypeIndex(ctx, memory_requirements.memory_type_bits, .{ .device_local_bit = true, }),
        };
        const image_memory = try ctx.vkd.allocateMemory(ctx.logical_device, alloc_info, null);
        
        try ctx.vkd.bindImageMemory(ctx.logical_device, image, image_memory, 0);
        try transitionImageLayout(ctx, command_pool, image, .@"undefined", .transfer_dst_optimal);
        try copyImageToBuffer(ctx, command_pool, image, staging_buffer.buffer, @intCast(u32, stb_image.width), @intCast(u32, stb_image.height));
        try transitionImageLayout(ctx, command_pool, image, .transfer_dst_optimal, .shader_read_only_optimal); // TODO: some textures should be write!

        return Texture {
            .texture_size = texture_size,
            .image = image,
            .image_memory = image_memory,
            .format = format,
        };
    }

    pub fn deinit(self: Texture, ctx: Context) void {
        ctx.vkd.destroyImage(ctx.logical_device, self.image, null);
        ctx.vkd.freeMemory(ctx.logical_device, self.image_memory, null);
    }
};

// TODO: this can be optimized to generate on compile time transition bits, but it will limit the usage of the function,
//       if it is only for internal use, then comptime should be utilized on the transition bits 
inline fn transitionImageLayout(ctx: Context, command_pool: vk.CommandPool, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) !void {
    const commmand_buffer = try vk_utils.beginOneTimeCommandBuffer(ctx, command_pool);
    const TransitionBits = struct {
        src_mask: vk.AccessFlags,
        dst_mask: vk.AccessFlags,
        src_stage: vk.PipelineStageFlags,
        dst_stage: vk.PipelineStageFlags,
    };
    const transition_bits = blk: {
        if (old_layout == .@"undefined" and new_layout == .transfer_dst_optimal) {
            break :blk TransitionBits{
                .src_mask = .{},
                .dst_mask = .{ .transfer_write_bit = true, },
                .src_stage = .{ .top_of_pipe_bit = true, },
                .dst_stage = .{ .transfer_bit = true, },
            };
        } else if (old_layout == .transfer_dst_optimal and new_layout == .shader_read_only_optimal) {
            break :blk TransitionBits{
                .src_mask = .{ .transfer_write_bit = true, },
                .dst_mask = .{ .shader_read_bit = true, },
                .src_stage = .{ .transfer_bit = true, },
                .dst_stage = .{ .fragment_shader_bit = true, },
            };
        }
        return error.UnsupportedLayout; // This layout transition is not implemented
    };
    const barrier = vk.ImageMemoryBarrier{
        .src_access_mask = transition_bits.src_mask,
        .dst_access_mask = transition_bits.dst_mask, 
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true, },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    ctx.vkd.cmdPipelineBarrier(
        commmand_buffer,
        transition_bits.src_stage,
        transition_bits.dst_stage,
        vk.DependencyFlags{}, 
        0,
        undefined,
        0,
        undefined,
        1,
        @ptrCast([*]const vk.ImageMemoryBarrier, &barrier)
    );
    try vk_utils.endOneTimeCommandBuffer(ctx, command_pool, commmand_buffer);
}

// TODO: find a suitable location for this functio 
inline fn copyImageToBuffer(ctx: Context, command_pool: vk.CommandPool, image: vk.Image, buffer: vk.Buffer, width: u32, height: u32) !void {
    const command_buffer = try vk_utils.beginOneTimeCommandBuffer(ctx, command_pool);
    const region = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = vk.ImageSubresourceLayers{
            .aspect_mask = .{ .color_bit = true, },
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
            .width = width,
            .height = height,
            .depth = 1,
        },
    };
    ctx.vkd.cmdCopyBufferToImage(command_buffer, buffer, image, .transfer_dst_optimal, 1, @ptrCast([*]const vk.BufferImageCopy, &region));
    try vk_utils.endOneTimeCommandBuffer(ctx, command_pool, command_buffer);
}
