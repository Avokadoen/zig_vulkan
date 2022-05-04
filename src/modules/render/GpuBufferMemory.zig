const std = @import("std");
const vk = @import("vulkan");

const vk_utils = @import("vk_utils.zig");
const Context = @import("Context.zig");

const tracy = @import("../../tracy.zig");

/// Vulkan buffer abstraction
const GpuBufferMemory = @This();

pub const bytes_in_mb = 1048576;

// TODO: might not make sense if different type, should be array
/// how many elements does the buffer contain
len: u32,
// TODO: rename capacity, and add an accumulating size variable
/// how many bytes *can* be stored in the buffer
size: vk.DeviceSize,
buffer: vk.Buffer,
memory: vk.DeviceMemory,
mapped: ?*anyopaque,

/// create a undefined buffer that can be utilized later
pub fn @"undefined"() GpuBufferMemory {
    return GpuBufferMemory{
        .len = 0,
        .size = 0,
        .buffer = .null_handle,
        .memory = .null_handle,
        .mapped = null,
    };
}

/// user has to make sure to call deinit on buffer
pub fn init(ctx: Context, size: vk.DeviceSize, buf_usage_flags: vk.BufferUsageFlags, mem_prop_flags: vk.MemoryPropertyFlags) !GpuBufferMemory {
    const buffer = blk: {
        const buffer_info = vk.BufferCreateInfo{
            .flags = .{},
            .size = size,
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
        .size = size,
        .buffer = buffer,
        .memory = memory,
        .mapped = null,
    };
}

pub const CopyConfig = struct {
    src_offset: vk.DeviceSize = 0,
    dst_offset: vk.DeviceSize = 0,
    size: vk.DeviceSize = 0,
};
pub fn copy(self: GpuBufferMemory, ctx: Context, into: *GpuBufferMemory, command_pool: vk.CommandPool, config: CopyConfig) !void {
    const copy_zone = tracy.ZoneN(@src(), "copy buffer");
    defer copy_zone.End();
    const command_buffer = try vk_utils.beginOneTimeCommandBuffer(ctx, command_pool);
    var copy_region = vk.BufferCopy{
        .src_offset = config.src_offset,
        .dst_offset = config.dst_offset,
        .size = config.size,
    };
    ctx.vkd.cmdCopyBuffer(command_buffer, self.buffer, into.buffer, 1, @ptrCast([*]vk.BufferCopy, &copy_region));
    try vk_utils.endOneTimeCommandBuffer(ctx, command_pool, command_buffer);
}

/// Transfer data from host to device
pub fn transferToDevice(self: *GpuBufferMemory, ctx: Context, comptime T: type, offset: usize, data: []const T) !void {
    const transfer_zone = tracy.ZoneN(@src(), @src().fn_name);
    defer transfer_zone.End();

    if (self.mapped != null) {
        // TODO: implement a transfer for already mapped memory
        return error.MemoryAlreadyMapped; // can't used transfer if memory is externally mapped
    }
    // transfer empty data slice is NOP
    if (data.len <= 0) return;

    const size = data.len * @sizeOf(T);
    const map_size = self.nonCoherentAtomSize(ctx, size);
    const gpu_mem = (try ctx.vkd.mapMemory(ctx.logical_device, self.memory, offset, map_size, .{})) orelse return error.FailedToMapGPUMem;
    const gpu_mem_start = @ptrToInt(gpu_mem);
    {
        @setRuntimeSafety(false);
        for (data) |element, i| {
            const mem_location = gpu_mem_start + i * @sizeOf(T);
            var ptr = @intToPtr(*T, mem_location);
            ptr.* = element;
        }
    }
    ctx.vkd.unmapMemory(ctx.logical_device, self.memory);
    self.len = @intCast(u32, data.len);
}

pub fn map(self: *GpuBufferMemory, ctx: Context, offset: vk.DeviceSize, size: vk.DeviceSize) !void {
    const map_size = self.nonCoherentAtomSize(ctx, size);
    self.mapped = (try ctx.vkd.mapMemory(ctx.logical_device, self.memory, offset, map_size, .{})) orelse return error.FailedToMapGPUMem;
}

pub fn unmap(self: *GpuBufferMemory, ctx: Context) void {
    if (self.mapped != null) {
        ctx.vkd.unmapMemory(ctx.logical_device, self.memory);
        self.mapped = null;
    }
}

pub fn flush(self: GpuBufferMemory, ctx: Context, offset: vk.DeviceSize, size: vk.DeviceSize) !void {
    const atom_size = self.nonCoherentAtomSize(ctx, size);
    const map_range = vk.MappedMemoryRange{
        .memory = self.memory,
        .offset = offset,
        .size = atom_size,
    };
    try ctx.vkd.flushMappedMemoryRanges(
        ctx.logical_device,
        1,
        @ptrCast([*]const vk.MappedMemoryRange, &map_range),
    );
}

pub fn transferFromDevice(self: *GpuBufferMemory, ctx: Context, comptime T: type, data: []T) !void {
    const transfer_zone = tracy.ZoneN(@src(), @src().fn_name);
    defer transfer_zone.End();

    if (self.mapped != null) {
        // TODO: implement a transfer for already mapped memory
        return error.MemoryAlreadyMapped; // can't used transfer if memory is externally mapped
    }

    const gpu_mem = (try ctx.vkd.mapMemory(ctx.logical_device, self.memory, 0, self.size, .{})) orelse return error.FailedToMapGPUMem;
    const gpu_mem_start = @ptrToInt(gpu_mem);

    var i: usize = 0;
    var offset: usize = 0;
    {
        @setRuntimeSafety(false);
        while (offset + @sizeOf(T) <= self.size and i < data.len) : (i += 1) {
            offset = @sizeOf(T) * i;
            data[i] = @intToPtr(*T, gpu_mem_start + offset).*;
        }
    }
    ctx.vkd.unmapMemory(ctx.logical_device, self.memory);
}

/// Transfer data from host to device, allows you to send multiple chunks of data in the same buffer.
/// offsets are index offsets, not byte offsets
pub fn batchTransfer(self: *GpuBufferMemory, ctx: Context, comptime T: type, offsets: []usize, datas: [][]const T) !void {
    const transfer_zone = tracy.ZoneN(@src(), @src().fn_name);
    defer transfer_zone.End();

    if (self.mapped != null) {
        // TODO: implement a transfer for already mapped memory
        return error.MemoryAlreadyMapped; // can't used transfer if memory is externally mapped
    }

    if (offsets.len == 0) return;
    if (offsets.len != datas.len) {
        return error.OffsetDataMismatch; // inconsistent offset and data size indicate a programatic error
    }

    // calculate how far in the memory location we are going
    const size = datas[datas.len - 1].len * @sizeOf(T) + offsets[offsets.len - 1] * @sizeOf(T);
    if (self.size < size) {
        return error.InsufficentBufferSize; // size of buffer is less than data being transfered
    }

    const gpu_mem = (try ctx.vkd.mapMemory(ctx.logical_device, self.memory, 0, self.size, .{})) orelse return error.FailedToMapGPUMem;
    const gpu_mem_start = @ptrToInt(gpu_mem);
    {
        @setRuntimeSafety(false);
        for (offsets) |offset, i| {
            const byte_offset = offset * @sizeOf(T);
            for (datas[i]) |element, j| {
                const mem_location = gpu_mem_start + byte_offset + j * @sizeOf(T);
                var ptr = @intToPtr(*T, mem_location);
                ptr.* = element;
            }
        }
    }
    ctx.vkd.unmapMemory(ctx.logical_device, self.memory);

    self.len = std.math.max(self.len, @intCast(u32, datas[datas.len - 1].len + offsets[offsets.len - 1]));
}

/// destroy buffer and free memory
pub fn deinit(self: GpuBufferMemory, ctx: Context) void {
    if (self.mapped != null) {
        ctx.vkd.unmapMemory(ctx.logical_device, self.memory);
    }
    if (self.buffer != .null_handle) {
        ctx.vkd.destroyBuffer(ctx.logical_device, self.buffer, null);
    }
    if (self.memory != .null_handle) {
        ctx.vkd.freeMemory(ctx.logical_device, self.memory, null);
    }
}

inline fn nonCoherentAtomSize(self: GpuBufferMemory, ctx: Context, size: vk.DeviceSize) vk.DeviceSize {
    const map_size = ctx.non_coherent_atom_size * (std.math.divCeil(vk.DeviceSize, size, ctx.non_coherent_atom_size) catch unreachable);
    return std.math.min(self.size, map_size);
}
