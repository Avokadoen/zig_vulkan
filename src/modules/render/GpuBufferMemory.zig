const std = @import("std");
const vk = @import("vulkan");

const vk_utils = @import("vk_utils.zig");
const Context = @import("Context.zig");

const tracy = @import("ztracy");

const memory_util = @import("memory.zig");

/// Vulkan buffer abstraction
const GpuBufferMemory = @This();

/// how many elements does the buffer contain
len: vk.DeviceSize,
/// how many bytes *can* be stored in the buffer
size: vk.DeviceSize,
buffer: vk.Buffer,
memory: vk.DeviceMemory,
mapped: ?*anyopaque,
map_offset: vk.DeviceSize = 0,

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
    const zone = tracy.ZoneN(@src(), @typeName(GpuBufferMemory) ++ " " ++ @src().fn_name);
    defer zone.End();

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
    const zone = tracy.ZoneN(@src(), @typeName(GpuBufferMemory) ++ " " ++ @src().fn_name);
    defer zone.End();

    const command_buffer = try vk_utils.beginOneTimeCommandBuffer(ctx, command_pool);
    var copy_region = vk.BufferCopy{
        .src_offset = config.src_offset,
        .dst_offset = config.dst_offset,
        .size = config.size,
    };
    ctx.vkd.cmdCopyBuffer(command_buffer, self.buffer, into.buffer, 1, @as([*]vk.BufferCopy, @ptrCast(&copy_region)));
    try vk_utils.endOneTimeCommandBuffer(ctx, command_pool, command_buffer);
}

pub const FillConfig = struct {
    dst_offset: vk.DeviceSize = 0,
    size: vk.DeviceSize = 0,
};
pub fn fill(self: GpuBufferMemory, ctx: Context, command_pool: vk.CommandPool, dst_offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) !void {
    const zone = tracy.ZoneN(@src(), @typeName(GpuBufferMemory) ++ " " ++ @src().fn_name);
    defer zone.End();

    const command_buffer = try vk_utils.beginOneTimeCommandBuffer(ctx, command_pool);
    ctx.vkd.cmdFillBuffer(command_buffer, self.buffer, dst_offset, size, data);
    try vk_utils.endOneTimeCommandBuffer(ctx, command_pool, command_buffer);
}

pub fn map(self: *GpuBufferMemory, ctx: Context, offset: vk.DeviceSize, size: vk.DeviceSize) !void {
    const zone = tracy.ZoneN(@src(), @typeName(GpuBufferMemory) ++ " " ++ @src().fn_name);
    defer zone.End();

    const map_size = blk: {
        if (size == vk.WHOLE_SIZE) {
            break :blk vk.WHOLE_SIZE;
        }
        const atom_size = memory_util.nonCoherentAtomSize(ctx, size);

        if (atom_size + offset > self.size - self.map_offset) {
            return error.InsufficientMemory;
        }

        break :blk atom_size;
    };

    self.map_offset = offset;
    self.mapped = (try ctx.vkd.mapMemory(ctx.logical_device, self.memory, offset, map_size, .{})) orelse return error.FailedToMapGPUMem;
}

pub fn unmap(self: *GpuBufferMemory, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(GpuBufferMemory) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (self.mapped != null) {
        ctx.vkd.unmapMemory(ctx.logical_device, self.memory);
        self.mapped = null;
    }
}

/// Cast currently mapped memory + offset as *T, assume memory is mapped
pub inline fn mappedAsPtr(self: GpuBufferMemory, comptime T: type, offset: vk.DeviceSize) *T {
    const cast_ptr: *T = cast_blk: {
        const address: vk.DeviceSize = @intCast(@intFromPtr(self.mapped.?));
        const offset_address: usize = @intCast(address + offset);
        break :cast_blk @ptrFromInt(offset_address);
    };

    return cast_ptr;
}

/// Cast currently mapped memory + offset as [*]T, assume memory is mapped
pub inline fn mappedAsC(self: GpuBufferMemory, comptime T: type, offset: vk.DeviceSize) [*]T {
    const cast_ptr: [*]T = cast_blk: {
        const address: vk.DeviceSize = @intCast(@intFromPtr(self.mapped.?));
        const offset_address: usize = @intCast(address + offset);
        break :cast_blk @ptrFromInt(offset_address);
    };

    return cast_ptr;
}

/// Cast currently mapped memory + offset as []T, assume memory is mapped
pub inline fn mappedAs(self: GpuBufferMemory, comptime T: type, offset: vk.DeviceSize, len: usize) []T {
    const c_slice = self.mappedAsC(T, offset);
    return c_slice[0..len];
}

pub const SyncOp = enum {
    flush,
    invalidate,
};
/// Makes host writes visible to the device
pub fn sync(self: GpuBufferMemory, comptime sync_op: SyncOp, ctx: Context, offset: vk.DeviceSize, size: vk.DeviceSize) !void {
    const zone = tracy.ZoneN(@src(), @typeName(GpuBufferMemory) ++ " " ++ @src().fn_name);
    defer zone.End();

    const atom_size = memory_util.nonCoherentAtomSize(ctx, size);
    if (atom_size + offset > self.size - self.map_offset) {
        return error.InsufficientMemory;
    }

    const map_range = vk.MappedMemoryRange{
        .memory = self.memory,
        .offset = offset,
        .size = atom_size,
    };

    switch (sync_op) {
        .flush => try ctx.vkd.flushMappedMemoryRanges(
            ctx.logical_device,
            1,
            @as([*]const vk.MappedMemoryRange, @ptrCast(&map_range)),
        ),
        .invalidate => try ctx.vkd.invalidateMappedMemoryRanges(
            ctx.logical_device,
            1,
            @as([*]const vk.MappedMemoryRange, @ptrCast(&map_range)),
        ),
    }
}

/// destroy buffer and free memory
pub fn deinit(self: GpuBufferMemory, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(GpuBufferMemory) ++ " " ++ @src().fn_name);
    defer zone.End();

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
