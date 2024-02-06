const std = @import("std");
const Allocator = std.mem.Allocator;

const tracy = @import("ztracy");

const vk = @import("vulkan");
const render = @import("../render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;
const memory = render.memory;

const SimpleStagingBuffer = @This();

pub const buffer_size = 64 * memory.bytes_in_mb;

// TODO: benchmark ArrayHashMap vs HashMap
// we do not need hash cache as the buffer and image type
// are u64 opaque types (so eql is cheap)
///   hash(self, K) u32
///   eql(self, K, K, usize) bool
const BufferCopyMapContext = struct {
    pub fn hash(self: BufferCopyMapContext, key: vk.Buffer) u32 {
        _ = self;
        const v: u64 = @intFromEnum(key);
        const left_value = (v >> 32) / 4;
        const right_value = ((v << 32) >> 32) / 2;
        return @as(u32, @intCast(left_value + right_value));
    }

    pub fn eql(self: BufferCopyMapContext, a: vk.Buffer, b: vk.Buffer, i: usize) bool {
        _ = self;
        _ = i;
        return a == b;
    }
};
const RegionCount = 256;
const BufferCopies = struct {
    len: u32,
    regions: [RegionCount]vk.BufferCopy,
};
const BufferCopyMap = std.ArrayHashMap(vk.Buffer, BufferCopies, BufferCopyMapContext, false);

const fence_info = vk.FenceCreateInfo{
    .flags = .{
        .signaled_bit = true,
    },
};

buffer_cursor: vk.DeviceSize,
device_buffer_memory: GpuBufferMemory,

buffer_copy: BufferCopyMap,

pub fn init(ctx: Context, allocator: Allocator) !SimpleStagingBuffer {
    const zone = tracy.ZoneN(@src(), @typeName(SimpleStagingBuffer) ++ " " ++ @src().fn_name);
    defer zone.End();

    var device_buffer_memory = try GpuBufferMemory.init(
        ctx,
        buffer_size,
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true, .host_cached_bit = true },
    );
    errdefer device_buffer_memory.deinit(ctx);

    try device_buffer_memory.map(ctx, 0, buffer_size);

    return SimpleStagingBuffer{
        .device_buffer_memory = device_buffer_memory,
        .buffer_cursor = 0,
        .buffer_copy = BufferCopyMap.init(allocator),
    };
}

pub fn deinit(self: SimpleStagingBuffer, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(SimpleStagingBuffer) ++ " " ++ @src().fn_name);
    defer zone.End();

    self.device_buffer_memory.deinit(ctx);

    var copy_map = @constCast(&self.buffer_copy);
    copy_map.deinit();
}

pub fn transferToBuffer(self: *SimpleStagingBuffer, dst: *GpuBufferMemory, offset: vk.DeviceSize, comptime T: type, data: []const T) !void {
    const zone = tracy.ZoneN(@src(), @typeName(SimpleStagingBuffer) ++ " " ++ @src().fn_name);
    defer zone.End();

    const data_size = data.len * @sizeOf(T);
    if (offset + data_size > dst.size) {
        // TODO: renmame InsufficientDestMemory
        return error.DestOutOfDeviceMemory; // destination buffer has insufficient memory capacity
    }
    if (self.buffer_cursor + data_size > buffer_size) {
        return error.StageOutOfDeviceMemory; // buffer is out of memory
    }

    {
        // TODO: here we align as u8 and later we reinterpret data as a byte array.
        //       This is because we get an appropriate runtime error from using T and data directly when address does not align.
        //       It might be worth using T with appropriate address alignment
        const raw_device_ptr = self.device_buffer_memory.mapped orelse @panic("device pointer was null");
        var dest_location = @as([*]u8, @ptrCast(@alignCast(raw_device_ptr)));
        const byte_data = std.mem.sliceAsBytes(data);

        const dest_from = self.buffer_cursor;
        const dest_to = dest_from + byte_data.len;
        @memcpy(dest_location[dest_from..dest_to], byte_data);
    }

    const copy_region = vk.BufferCopy{
        .src_offset = self.buffer_cursor,
        .dst_offset = offset,
        .size = data_size,
    };

    if (self.buffer_copy.getPtr(dst.buffer)) |regions| {
        if (regions.len >= RegionCount) return error.OutOfRegions; // no more regions in this ramp for this frame

        regions.*.regions[regions.len] = copy_region;
        regions.*.len += 1;
    } else {
        var regions = [_]vk.BufferCopy{undefined} ** RegionCount;
        regions[0] = copy_region;
        try self.buffer_copy.put(
            dst.buffer,
            // create array of copy jobs, begin with current job and
            // set remaining jobs as undefined
            BufferCopies{ .len = 1, .regions = regions },
        );
    }
    self.buffer_cursor += data_size;
}

pub fn sync(self: *SimpleStagingBuffer, ctx: Context) !void {
    const zone = tracy.ZoneN(@src(), @typeName(SimpleStagingBuffer) ++ " " ++ @src().fn_name);
    defer zone.End();

    try self.device_buffer_memory.sync(.flush, ctx, 0, self.buffer_cursor);
}

pub fn partialFlush(
    self: SimpleStagingBuffer,
    ctx: Context,
    command_buffer: vk.CommandBuffer,
    buffer: vk.Buffer,
    inclusive_from: usize,
    exclusive_to: usize,
) !void {
    const zone = tracy.ZoneN(@src(), @typeName(SimpleStagingBuffer) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (self.buffer_cursor == 0) return;

    const copy_job = self.buffer_copy.get(buffer) orelse return error.MissingBuffer;
    const len: u32 = @intCast(exclusive_to - inclusive_from);
    std.debug.assert(len <= copy_job.len);

    ctx.vkd.cmdCopyBuffer(command_buffer, self.device_buffer_memory.buffer, buffer, len, copy_job.regions[inclusive_from..exclusive_to].ptr);
}

pub fn empty(self: *SimpleStagingBuffer) void {
    self.buffer_copy.clearRetainingCapacity();
    self.buffer_cursor = 0;
}

pub fn flush(self: *SimpleStagingBuffer, ctx: Context, command_buffer: vk.CommandBuffer) void {
    const zone = tracy.ZoneN(@src(), @typeName(SimpleStagingBuffer) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (self.buffer_cursor == 0) return;

    { // copy buffer jobs
        var iter = self.buffer_copy.iterator();
        while (iter.next()) |some| {
            ctx.vkd.cmdCopyBuffer(command_buffer, self.device_buffer_memory.buffer, some.key_ptr.*, some.value_ptr.len, &some.value_ptr.*.regions);
        }
    }

    self.empty();
}
