/// vk_utils contains utility functions for the vulkan API to reduce boiler plate

// TODO: most of these functions are only called once in the codebase, move to where they are
// relevant, and those who are only called in one file should be in that file

const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const dispatch = @import("dispatch.zig");

const Context = @import("Context.zig");

/// Check if extensions are available on host instance
pub fn isInstanceExtensionsPresent(allocator: Allocator, vkb: dispatch.Base, target_extensions: []const [*:0]const u8) !bool {
    // query extensions available
    var supported_extensions_count: u32 = 0;
    // TODO: handle "VkResult.incomplete"
    _ = try vkb.enumerateInstanceExtensionProperties(null, &supported_extensions_count, null);

    var extensions = try std.ArrayList(vk.ExtensionProperties).initCapacity(allocator, supported_extensions_count);
    defer extensions.deinit();

    _ = try vkb.enumerateInstanceExtensionProperties(null, &supported_extensions_count, extensions.items.ptr);
    extensions.items.len = supported_extensions_count;

    var matches: u32 = 0;
    for (target_extensions) |target_extension| {
        cmp: for (extensions.items) |existing| {
            const existing_name = @as([*:0]const u8, @ptrCast(&existing.extension_name));
            if (std.mem.orderZ(u8, target_extension, existing_name) == .eq) {
                matches += 1;
                break :cmp;
            }
        }
    }

    return matches == target_extensions.len;
}

pub inline fn findMemoryTypeIndex(ctx: Context, type_filter: u32, memory_flags: vk.MemoryPropertyFlags) !u32 {
    const properties = ctx.vki.getPhysicalDeviceMemoryProperties(ctx.physical_device);
    {
        var i: u32 = 0;
        while (i < properties.memory_type_count) : (i += 1) {
            const correct_type: bool = (type_filter & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0;
            if (correct_type and (properties.memory_types[i].property_flags.toInt() & memory_flags.toInt()) == memory_flags.toInt()) {
                return i;
            }
        }
    }

    return error.NotFound;
}

pub inline fn beginOneTimeCommandBuffer(ctx: Context, command_pool: vk.CommandPool) !vk.CommandBuffer {
    const allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    var command_buffer: vk.CommandBuffer = undefined;
    try ctx.vkd.allocateCommandBuffers(ctx.logical_device, &allocate_info, @as([*]vk.CommandBuffer, @ptrCast(&command_buffer)));

    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{
            .one_time_submit_bit = true,
        },
        .p_inheritance_info = null,
    };
    try ctx.vkd.beginCommandBuffer(command_buffer, &begin_info);

    return command_buffer;
}

// TODO: synchronization should be improved in this function (currently very sub optimal)!
pub inline fn endOneTimeCommandBuffer(ctx: Context, command_pool: vk.CommandPool, command_buffer: vk.CommandBuffer) !void {
    try ctx.vkd.endCommandBuffer(command_buffer);

    {
        @setRuntimeSafety(false);
        var semo_null_ptr: [*c]const vk.Semaphore = null;
        var wait_null_ptr: [*c]const vk.PipelineStageFlags = null;
        // perform the compute ray tracing, draw to target texture
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = semo_null_ptr,
            .p_wait_dst_stage_mask = wait_null_ptr,
            .command_buffer_count = 1,
            .p_command_buffers = @as([*]const vk.CommandBuffer, @ptrCast(&command_buffer)),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = semo_null_ptr,
        };
        try ctx.vkd.queueSubmit(ctx.graphics_queue, 1, @as([*]const vk.SubmitInfo, @ptrCast(&submit_info)), .null_handle);
    }

    try ctx.vkd.queueWaitIdle(ctx.graphics_queue);

    ctx.vkd.freeCommandBuffers(ctx.logical_device, command_pool, 1, @as([*]const vk.CommandBuffer, @ptrCast(&command_buffer)));
}
