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
size: vk.DeviceSize,
buffer: vk.Buffer,
memory: vk.DeviceMemory,
mapped: ?*anyopaque,

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

pub inline fn checkCapacity(self: GpuBufferMemory, ctx: Context, extra: vk.DeviceSize) error{InsufficientMemory}!void {
    if (memory_util.nonCoherentAtomSize(ctx, self.len + extra) > self.size) {
        return error.InsufficientMemory;
    }
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
    ctx.vkd.cmdCopyBuffer(command_buffer, self.buffer, into.buffer, 1, @ptrCast(&copy_region));
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
    const map_size = memory_util.nonCoherentAtomSize(ctx, size);
    if (map_size + offset > self.size) return error.OutOfDeviceMemory; // size greater than buffer

    const gpu_mem = (try ctx.vkd.mapMemory(ctx.logical_device, self.memory, offset, map_size, .{})) orelse return error.FailedToMapGPUMem;
    const gpu_mem_align: [*]align(1) T = @ptrCast(gpu_mem);
    var typed_gpu_mem: [*]T = @alignCast(gpu_mem_align);
    @memcpy(typed_gpu_mem[0..data.len], data);
    ctx.vkd.unmapMemory(ctx.logical_device, self.memory);
    self.len = @intCast(data.len);
}

pub fn map(self: *GpuBufferMemory, ctx: Context, offset: vk.DeviceSize, size: vk.DeviceSize) !void {
    const map_size = blk: {
        if (size == vk.WHOLE_SIZE) {
            break :blk vk.WHOLE_SIZE;
        }
        const atom_size = memory_util.nonCoherentAtomSize(ctx, size);
        if (atom_size + offset > self.size) {
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
    if (atom_size + offset > self.size) return error.InsufficientMemory; // size greater than buffer

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

pub fn transferFromDevice(self: *GpuBufferMemory, ctx: Context, comptime T: type, data: []T) !void {
    const transfer_zone = tracy.ZoneN(@src(), @src().fn_name);
    defer transfer_zone.End();

    if (self.mapped != null) {
        // TODO: implement a transfer for already mapped memory
        return error.MemoryAlreadyMapped; // can't used transfer if memory is externally mapped
    }

    const gpu_mem = (try ctx.vkd.mapMemory(ctx.logical_device, self.memory, 0, self.size, .{})) orelse return error.FailedToMapGPUMem;
    const gpu_mem_start = @intFromPtr(gpu_mem);

    var i: usize = 0;
    var offset: usize = 0;
    {
        @setRuntimeSafety(false);
        while (offset + @sizeOf(T) <= self.size and i < data.len) : (i += 1) {
            offset = @sizeOf(T) * i;
            const address = gpu_mem_start + offset;
            std.debug.assert(std.mem.alignForward(usize, address, @alignOf(T)) == address);

            data[i] = @as(*T, @ptrFromInt(address)).*;
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
    const gpu_mem_start = @intFromPtr(gpu_mem);
    {
        @setRuntimeSafety(false);
        for (offsets, 0..) |offset, i| {
            const byte_offset = offset * @sizeOf(T);
            for (datas[i], 0..) |element, j| {
                const mem_location = gpu_mem_start + byte_offset + j * @sizeOf(T);
                const ptr: *T = @ptrFromInt(mem_location);
                ptr.* = element;
            }
        }
    }
    ctx.vkd.unmapMemory(ctx.logical_device, self.memory);

    self.len = std.math.max(self.len, @intCast(datas[datas.len - 1].len + offsets[offsets.len - 1]));
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
