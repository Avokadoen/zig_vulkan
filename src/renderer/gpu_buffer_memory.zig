const std= @import("std");
const vk = @import("vulkan");

const Context = @import("context.zig").Context;

/// Vulkan buffer abstraction
pub const GpuBufferMemory = struct {
    const Self = @This();

    context: *Context,

    size: vk.DeviceSize,
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,

    /// user has to make sure to call deinit on buffer
    pub fn init(context: *Context, size: vk.DeviceSize, usage: vk.BufferUsageFlags) !Self {
        const ctx = context.*;

        const buffer = blk: {
            const buffer_info = vk.BufferCreateInfo {
                .flags = .{},
                .size = size,
                .usage = usage,
                .sharing_mode = .exclusive, // TODO: look into concurrent mode!
                .queue_familiy_index_count = 0,
                .p_queue_familiy_indices = undefined,
            };
            break :blk try ctx.vkd.createBuffer(ctx.logical_device, buffer_info, null);
        };

        const memory = blk: {
            const memory_requirements = ctx.vkd.getBufferMemoryRequirements(ctx.logical_device, buffer);
            const memory_type_index = try findMemoryTypeIndex(ctx, memory_requirements.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true });
            const allocate_info = vk.MemoryAllocateInfo{
                .allocation_size = memory_requirements.size,
                .memory_type_index = memory_type_index,
            };
            break :blk try ctx.vkd.allocateMemory(ctx.logical_device, allocate_info);
        };

        return Self {
            .context = context,
            .size = size,
            .buffer = buffer,
            .memory = memory,
        };
    }

    pub fn bind(self: Self) !void {
        const ctx = self.context.*;
        try ctx.vkd.bindBufferMemory(ctx.logical_device, self.buffer, self.memory, 0);
    }

    pub fn transfer_data(self: Self, comptime T: type, data: []T) !void {
        const ctx = self.context.*;
        var gpu_mem = try ctx.vkd.mapMemory(ctx.logical_device, self.memory, 0, self.size, .{});
        const sliced_data = if (data.len >= self.size) data[0..self.size] else data[0..];
        std.mem.copy(T, gpu_mem, sliced_data);
        ctx.vkd.unmapMemory(ctx.logical_device, self.memory);
    }

    pub fn deinit(self: Self) void {
        const ctx = self.context.*;
        ctx.vkd.destroyBuffer(ctx.logical_device, self.buffer);
        ctx.vkd.freeMemory(ctx.logical_device, self.memory);
    }
};


inline fn findMemoryTypeIndex(ctx: Context, type_filter: u32, flags: vk.MemoryPropertyFlags) !u32 {
    const properties = ctx.vki.getPhysicalDeviceMemoryProperties(ctx.physical_device);
    {
        var i: usize = 0;
        while (i < properties.memory_type_count) : (i += 1) {
            if (type_filter & (1 << i) and flags.contains(properties.memory_types[i].property_flags)) {
                return i;
            }
        }
    }

    return error.NotFound;
}
