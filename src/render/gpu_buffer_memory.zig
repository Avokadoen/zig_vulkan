const std = @import("std");
const vk = @import("vulkan");

const ecez = @import("ecez");

const vk_utils = @import("vk_utils.zig");
const context = @import("context.zig");

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

        pub fn flush(
            self: GpuBufferMemory,
            vkd: context.components.vk_dispatch.Device,
            logical_device: context.components.VkDevice,
            physical_device_properties: context.components.VkPhysicalDeviceProperties,
            offset: vk.DeviceSize,
            size: vk.DeviceSize,
        ) !void {
            const atom_size = memory_util.nonCoherentAtomSize(physical_device_properties, size);
            if (atom_size + offset > self.capacity) return error.InsufficientMemory; // size greater than buffer

            const map_range = vk.MappedMemoryRange{
                .memory = self.memory,
                .offset = offset,
                .size = atom_size,
            };
            try vkd.flushMappedMemoryRanges(
                logical_device.v,
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
        pub fn gpuBufferMemory(gpu_buffer_memory_query: *queries.GpuBufferMemory, vk_device_query: *context.queries.VkdAndDevice) void {
            const ctx = vk_device_query.getAny().?;
            while (gpu_buffer_memory_query.next()) |entity| {
                destroyBuffer(ctx.vkd, ctx.logical_device, entity.gpu_buffer_memory);
            }
        }
    };
};

pub fn createGpuBufferMemoryComponents(
    vki: context.components.vk_dispatch.Instance,
    physical_device: context.components.VkPhysicalDevice,
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.VkDevice,
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
        break :blk try vkd.createBuffer(logical_device.v, &buffer_info, null);
    };
    errdefer vkd.destroyBuffer(logical_device.v, buffer, null);

    const memory, const atom_coherent_capacity = blk: {
        const memory_requirements = vkd.getBufferMemoryRequirements(logical_device.v, buffer);
        const memory_type_index = try vk_utils.findMemoryTypeIndex(
            vki,
            physical_device,
            memory_requirements.memory_type_bits,
            mem_prop_flags,
        );
        const allocate_info = vk.MemoryAllocateInfo{
            .allocation_size = memory_requirements.size,
            .memory_type_index = memory_type_index,
        };

        break :blk .{
            try vkd.allocateMemory(logical_device.v, &allocate_info, null),
            memory_requirements.size,
        };
    };
    errdefer vkd.freeMemory(logical_device.v, memory, null);

    try vkd.bindBufferMemory(logical_device.v, buffer, memory, 0);

    const mapped = (try vkd.mapMemory(
        logical_device.v,
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
pub fn destroyBuffer(
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.VkDevice,
    buffer: components.GpuBufferMemory,
) void {
    vkd.unmapMemory(logical_device.v, buffer.memory);
    std.debug.assert(buffer.buffer != .null_handle and buffer.memory != .null_handle);

    vkd.destroyBuffer(logical_device.v, buffer.buffer, null);
    vkd.freeMemory(logical_device.v, buffer.memory, null);
}
