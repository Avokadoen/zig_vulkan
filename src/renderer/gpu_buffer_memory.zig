const std= @import("std");
const vk = @import("vulkan");

const vk_utils = @import("vk_utils.zig");
const Context = @import("context.zig").Context;

/// Vulkan buffer abstraction
pub const GpuBufferMemory = struct {
    const Self = @This();

    ctx: Context,

    // TODO: might not make sense if different type, should be array
    /// how many elements does the buffer contain
    len: u32, 
    // TODO: rename capacity, and add an accumulating size variable
    /// how many bytes *can* be stored in the buffer
    size: vk.DeviceSize,
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,

    /// user has to make sure to call deinit on buffer
    pub fn init(ctx: Context, size: vk.DeviceSize, buf_usage_flags: vk.BufferUsageFlags, mem_prop_flags: vk.MemoryPropertyFlags) !Self {
        const buffer = blk: {
            const buffer_info = vk.BufferCreateInfo{
                .flags = .{},
                .size = size,
                .usage = buf_usage_flags,
                .sharing_mode = .exclusive, // TODO: look into concurrent mode!
                .queue_family_index_count = 0,
                .p_queue_family_indices = undefined,
            };
            break :blk try ctx.vkd.createBuffer(ctx.logical_device, buffer_info, null);
        };
        const memory = blk: {
            const memory_requirements = ctx.vkd.getBufferMemoryRequirements(ctx.logical_device, buffer);
            const memory_type_index = try vk_utils.findMemoryTypeIndex(ctx, memory_requirements.memory_type_bits, mem_prop_flags);
            const allocate_info = vk.MemoryAllocateInfo{
                .allocation_size = memory_requirements.size,
                .memory_type_index = memory_type_index,
            };
            break :blk try ctx.vkd.allocateMemory(ctx.logical_device, allocate_info, null);
        };
        return Self {
            .ctx = ctx,
            .len = 0,
            .size = size,
            .buffer = buffer,
            .memory = memory,
        };
    }

    pub inline fn bind(self: Self) !void {
        try self.ctx.vkd.bindBufferMemory(self.ctx.logical_device, self.buffer, self.memory, 0);
    }

    pub fn copyBuffer(self: Self, into: *GpuBufferMemory, size: vk.DeviceSize, command_pool: vk.CommandPool) !void {
        const command_buffer = try vk_utils.beginOneTimeCommandBuffer(self.ctx, command_pool);
        var copy_region = vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = 0,
            .size = size,
        };
        self.ctx.vkd.cmdCopyBuffer(command_buffer, self.buffer, into.buffer, 1, @ptrCast([*]vk.BufferCopy, &copy_region));
        try vk_utils.endOneTimeCommandBuffer(self.ctx, command_pool, command_buffer);
        into.len += self.len;
    }

    pub fn transferData(self: *Self, comptime T: type, data: []T) !void {
        const size = data.len * @sizeOf(T);
        if (self.size < size) {
            return error.InsufficentBufferSize; // size of buffer is less than data being transfered
        }
        var gpu_mem = try self.ctx.vkd.mapMemory(self.ctx.logical_device, self.memory, 0, size, .{});
        const gpu_mem_start = @ptrToInt(gpu_mem);
        // YOLO
        @setRuntimeSafety(false);
        for (data) |element, i| {
            const mem_location = gpu_mem_start + i * @sizeOf(T);
            var ptr = @intToPtr(*T, mem_location);
            ptr.* = element;
        }
        self.ctx.vkd.unmapMemory(self.ctx.logical_device, self.memory);
        self.len += @intCast(u32, data.len);
    }

    pub inline fn deinit(self: Self) void {
        self.ctx.vkd.destroyBuffer(self.ctx.logical_device, self.buffer, null);
        self.ctx.vkd.freeMemory(self.ctx.logical_device, self.memory, null);
    }
};
