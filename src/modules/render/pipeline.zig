const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const swapchain = @import("swapchain.zig");
const utils = @import("../utils.zig");

const Context = @import("Context.zig");

pub fn createFramebuffers(allocator: Allocator, ctx: Context, swapchain_data: *const swapchain.Data, render_pass: vk.RenderPass, prev_framebuffer: ?[]vk.Framebuffer) ![]vk.Framebuffer {
    const image_views = swapchain_data.image_views;
    var framebuffers = prev_framebuffer orelse try allocator.alloc(vk.Framebuffer, image_views.len);
    for (image_views) |view, i| {
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
        const framebuffer = try ctx.vkd.createFramebuffer(ctx.logical_device, &framebuffer_info, null);
        framebuffers[i] = framebuffer;
    }
    return framebuffers;
}

pub fn loadShaderStage(
    ctx: Context,
    // TODO: validate and document anytype here
    shader_code: anytype,
    stage: vk.ShaderStageFlags,
    specialization: ?*const vk.SpecializationInfo,
) !vk.PipelineShaderStageCreateInfo {
    const create_info = vk.ShaderModuleCreateInfo{
        .flags = .{},
        .p_code = @ptrCast([*]const u32, &shader_code),
        .code_size = shader_code.len,
    };
    const module = try ctx.vkd.createShaderModule(ctx.logical_device, &create_info, null);

    return vk.PipelineShaderStageCreateInfo{
        .flags = .{},
        .stage = stage,
        .module = module,
        .p_name = "main",
        .p_specialization_info = specialization,
    };
}

/// create a command buffers with sizeof buffer_count, caller must deinit returned list
pub fn createCmdBuffers(allocator: Allocator, ctx: Context, command_pool: vk.CommandPool, buffer_count: usize, prev_buffer: ?[]vk.CommandBuffer) ![]vk.CommandBuffer {
    var command_buffers = prev_buffer orelse try allocator.alloc(vk.CommandBuffer, buffer_count);
    const alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = vk.CommandBufferLevel.primary,
        .command_buffer_count = @intCast(u32, buffer_count),
    };
    try ctx.vkd.allocateCommandBuffers(ctx.logical_device, &alloc_info, command_buffers.ptr);
    command_buffers.len = buffer_count;

    return command_buffers;
}

/// create a command buffers with sizeof buffer_count, caller must destroy returned buffer with allocator
pub fn createCmdBuffer(ctx: Context, command_pool: vk.CommandPool) !vk.CommandBuffer {
    const alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = vk.CommandBufferLevel.primary,
        .command_buffer_count = @intCast(u32, 1),
    };
    var command_buffer: vk.CommandBuffer = undefined;
    try ctx.vkd.allocateCommandBuffers(ctx.logical_device, &alloc_info, @ptrCast([*]vk.CommandBuffer, &command_buffer));

    return command_buffer;
}
