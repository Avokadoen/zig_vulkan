const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const swapchain = @import("swapchain.zig");

const context = @import("context.zig");

pub fn createFramebuffers(
    allocator: Allocator,
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.Device,
    swapchain_data: *const swapchain.components.SwapchainData,
    render_pass: vk.RenderPass,
    prev_framebuffer: ?[]vk.Framebuffer,
) ![]vk.Framebuffer {
    const image_len = swapchain_data.image_len;
    const image_views = swapchain_data.image_views[0..image_len];
    var framebuffers = prev_framebuffer orelse try allocator.alloc(vk.Framebuffer, image_views.len);
    for (image_views, 0..) |view, i| {
        const attachments = [_]vk.ImageView{
            view,
        };
        const framebuffer_info = vk.FramebufferCreateInfo{
            .flags = .{},
            .render_pass = render_pass,
            .attachment_count = attachments.len,
            .p_attachments = &attachments,
            .width = swapchain_data.extent.width,
            .height = swapchain_data.extent.height,
            .layers = 1,
        };
        const framebuffer = try vkd.createFramebuffer(logical_device.v, &framebuffer_info, null);
        framebuffers[i] = framebuffer;
    }
    return framebuffers;
}

/// create a command buffers, caller must destroy returned buffer with allocator
pub fn createCmdBuffer(
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.Device,
    command_pool: vk.CommandPool,
) !vk.CommandBuffer {
    const alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = vk.CommandBufferLevel.primary,
        .command_buffer_count = @intCast(1),
    };
    var command_buffer: vk.CommandBuffer = undefined;
    try vkd.allocateCommandBuffers(logical_device.v, &alloc_info, @ptrCast(&command_buffer));

    return command_buffer;
}
