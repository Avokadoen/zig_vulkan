/// vk_utils contains utility functions for the vulkan API to reduce boiler plate

// TODO: most of these functions are only called once in the codebase, move to where they are
// relevant, and those who are only called in one file should be in that file

const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const dispatch = @import("dispatch.zig");

const Context = @import("context.zig").Context;

// TODO: support mixed types
/// Construct VkPhysicalDeviceFeatures type with VkFalse as default field value 
pub fn GetFalseFeatures(comptime T: type) type {
    const features_type_info = @typeInfo(T).Struct;
    var new_type_fields: [features_type_info.fields.len]std.builtin.TypeInfo.StructField = undefined;

    inline for (features_type_info.fields) |field, i| {
        new_type_fields[i] = field;
        new_type_fields[i].default_value = @intCast(u32, vk.FALSE);
    }

    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = &new_type_fields,
            .decls = &[_]std.builtin.TypeInfo.Declaration{},
            .is_tuple = false,
        },
    });
}

/// Check if extensions are available on host instance
pub fn isInstanceExtensionsPresent(allocator: *Allocator, vkb: dispatch.Base, target_extensions: []const [*:0]const u8) !bool {
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
            const existing_name = @ptrCast([*:0]const u8, &existing.extension_name);
            if (std.cstr.cmp(target_extension, existing_name) == 0) {
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
            // I am honsetly not sure what this something actually does ...
            const something = type_filter & @as(u32, 1) << @intCast(u5, i);
            if (something > 0 and memory_flags.toInt() == properties.memory_types[i].property_flags.toInt()) {
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
    var commmand_buffer: vk.CommandBuffer = undefined; 
    try ctx.vkd.allocateCommandBuffers(ctx.logical_device, allocate_info, @ptrCast([*]vk.CommandBuffer, &commmand_buffer));

    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true, },
        .p_inheritance_info = null,
    };
    try ctx.vkd.beginCommandBuffer(commmand_buffer, begin_info);

    return commmand_buffer;
}

// TODO: synchronization should be improved in this function (currently very sub optimal)!
pub inline fn endOneTimeCommandBuffer(ctx: Context, command_pool: vk.CommandPool, command_buffer: vk.CommandBuffer) !void {
    try ctx.vkd.endCommandBuffer(command_buffer);

    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &command_buffer),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };
    try ctx.vkd.queueSubmit(ctx.graphics_queue, 1, @ptrCast([*]const vk.SubmitInfo, &submit_info), .null_handle);
    try ctx.vkd.queueWaitIdle(ctx.graphics_queue);

    ctx.vkd.freeCommandBuffers(ctx.logical_device, command_pool, 1, @ptrCast([*]const vk.CommandBuffer, &command_buffer));
}
