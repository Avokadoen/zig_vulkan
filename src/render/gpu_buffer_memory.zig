const std = @import("std");
const vk = @import("vulkan");

const ecez = @import("ecez");

const vk_utils = @import("vk_utils.zig");
const Context = @import("Context.zig");

const tracy = @import("ztracy");

const memory_util = @import("memory.zig");

pub const components = struct {
    pub const GpuBufferMemory = struct {
        len: u32,
        capacity: vk.DeviceSize,
        buffer: vk.Buffer,
        memory: vk.DeviceMemory,
        mapped: *anyopaque,

        pub fn typedMapAssumeMapped(self: *const GpuBufferMemory, comptime T: type, offset: vk.DeviceSize) [*]T {
            var bytes: [*]u8 = @ptrCast(self.mapped);
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
    };
};

pub const queries = struct {
    pub const GpuBufferMemory = ecez.Query(
        struct {
            gpu_buffer_memory: components.GpuBufferMemory,
        },
        .{},
        .{},
    );
};

pub const systems = struct {
    pub const deinit = struct {
        pub fn gpuBufferMemory(gpu_buffer_memory_queries: *queries.GpuBufferMemory, ctx: Context) void {
            while (gpu_buffer_memory_queries.next()) |entity| {
                destroyBuffer(entity.gpu_buffer_memory, ctx);
            }
        }
    };
};

pub fn createGpuBufferMemoryComponents(
    ctx: Context,
    capacity: vk.DeviceSize,
    buf_usage_flags: vk.BufferUsageFlags,
    mem_prop_flags: vk.MemoryPropertyFlags,
) !components.GpuBufferMemory {
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

    const memory, const atom_coherent_capacity = blk: {
        const memory_requirements = ctx.vkd.getBufferMemoryRequirements(ctx.logical_device, buffer);
        const memory_type_index = try vk_utils.findMemoryTypeIndex(ctx, memory_requirements.memory_type_bits, mem_prop_flags);
        const allocate_info = vk.MemoryAllocateInfo{
            .allocation_size = memory_requirements.size,
            .memory_type_index = memory_type_index,
        };

        break :blk .{
            try ctx.vkd.allocateMemory(ctx.logical_device, &allocate_info, null),
            memory_requirements.size,
        };
    };
    errdefer ctx.vkd.freeMemory(ctx.logical_device, memory, null);

    try ctx.vkd.bindBufferMemory(ctx.logical_device, buffer, memory, 0);

    const mapped = (try ctx.vkd.mapMemory(
        ctx.logical_device,
        memory,
        0,
        vk.WHOLE_SIZE,
        .{},
    )) orelse return error.FailedToMapGPUMem;

    return components.GpuBufferMemory{
        .len = 0,
        .capacity = atom_coherent_capacity,
        .buffer = buffer,
        .memory = memory,
        .mapped = mapped,
    };
}

/// destroy buffer and free memory
pub fn destroyBuffer(buffer: components.GpuBufferMemory, ctx: Context) void {
    ctx.vkd.unmapMemory(ctx.logical_device, buffer.memory);
    std.debug.assert(buffer.buffer != .null_handle and buffer.memory != .null_handle);

    ctx.vkd.destroyBuffer(ctx.logical_device, buffer.buffer, null);
    ctx.vkd.freeMemory(ctx.logical_device, buffer.memory, null);
}
