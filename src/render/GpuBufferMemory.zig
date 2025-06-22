const std = @import("std");
const vk = @import("vulkan");

const vk_utils = @import("vk_utils.zig");
const Context = @import("Context.zig");

const tracy = @import("ztracy");

const memory_util = @import("memory.zig");

/// Vulkan buffer abstraction
const GpuBufferMemory = @This();

// TODO: might not make sense if different type, should be array
/// how many elements does the buffer contain
len: u32,
// TODO: rename capacity, and add an accumulating size variable
/// how many bytes *can* be stored in the buffer
capacity: vk.DeviceSize,
buffer: vk.Buffer,
memory: vk.DeviceMemory,
mapped: ?*anyopaque,

/// user has to make sure to call deinit on buffer
pub fn init(
    ctx: Context,
    capacity: vk.DeviceSize,
    buf_usage_flags: vk.BufferUsageFlags,
    mem_prop_flags: vk.MemoryPropertyFlags,
) !GpuBufferMemory {
    const buffer = blk: {
        const buffer_info = vk.BufferCreateInfo{
            .flags = .{},
            .size = capacity,
            .usage = buf_usage_flags,
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        };
        break :blk try ctx.vkd.createBuffer(ctx.logical_device, &buffer_info, null);
    };
    errdefer ctx.vkd.destroyBuffer(ctx.logical_device, buffer, null);

    const memory = blk: {
        const memory_requirements = ctx.vkd.getBufferMemoryRequirements(ctx.logical_device, buffer);
        const memory_type_index = try vk_utils.findMemoryTypeIndex(ctx, memory_requirements.memory_type_bits, mem_prop_flags);
        const allocate_info = vk.MemoryAllocateInfo{
            .allocation_size = memory_requirements.size,
            .memory_type_index = memory_type_index,
        };
        break :blk try ctx.vkd.allocateMemory(ctx.logical_device, &allocate_info, null);
    };
    errdefer ctx.vkd.freeMemory(ctx.logical_device, memory, null);

    try ctx.vkd.bindBufferMemory(ctx.logical_device, buffer, memory, 0);

    return GpuBufferMemory{
        .len = 0,
        .capacity = capacity,
        .buffer = buffer,
        .memory = memory,
        .mapped = null,
    };
}

pub fn map(self: *GpuBufferMemory, ctx: Context, offset: vk.DeviceSize, size: vk.DeviceSize) !void {
    const map_size = blk: {
        if (size == vk.WHOLE_SIZE) {
            break :blk vk.WHOLE_SIZE;
        }
        const atom_size = memory_util.nonCoherentAtomSize(ctx, size);
        if (atom_size + offset > self.capacity) {
            return error.InsufficientMemory;
        }
        break :blk atom_size;
    };

    self.mapped = (try ctx.vkd.mapMemory(ctx.logical_device, self.memory, offset, map_size, .{})) orelse return error.FailedToMapGPUMem;
}

pub fn unmap(self: *GpuBufferMemory, ctx: Context) void {
    if (self.mapped != null) {
        ctx.vkd.unmapMemory(ctx.logical_device, self.memory);
        self.mapped = null;
    }
}

pub fn typedMapAssumeMapped(self: *GpuBufferMemory, comptime T: type, offset: vk.DeviceSize) [*]T {
    var bytes: [*]u8 = @ptrCast(self.mapped.?);
    const ptr: [*]T = @alignCast(@ptrCast(&bytes[offset]));
    return ptr;
}

pub fn flush(self: GpuBufferMemory, ctx: Context, offset: vk.DeviceSize, size: vk.DeviceSize) !void {
    const atom_size = memory_util.nonCoherentAtomSize(ctx, size);
    if (atom_size + offset > self.capacity) return error.InsufficientMemory; // size greater than buffer

    const map_range = vk.MappedMemoryRange{
        .memory = self.memory,
        .offset = offset,
        .size = atom_size,
    };
    try ctx.vkd.flushMappedMemoryRanges(
        ctx.logical_device,
        1,
        @ptrCast(&map_range),
    );
}

/// destroy buffer and free memory
pub fn deinit(self: GpuBufferMemory, ctx: Context) void {
    if (self.mapped != null) {
        ctx.vkd.unmapMemory(ctx.logical_device, self.memory);
    }
    std.debug.assert(self.buffer != .null_handle and self.memory != .null_handle);

    ctx.vkd.destroyBuffer(ctx.logical_device, self.buffer, null);
    ctx.vkd.freeMemory(ctx.logical_device, self.memory, null);
}
