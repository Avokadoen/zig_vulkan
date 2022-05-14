const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const tracy = @import("../../tracy.zig");

const render = @import("../render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;
const Texture = render.Texture;
const memory = render.memory;

pub const buffer_size = 63 * memory.bytes_in_mb;

const DeferBufferTransfer = struct {
    ctx: Context,
    buffer: *GpuBufferMemory,
    offset: vk.DeviceSize,
    data: []const u8,
};

/// StagingBuffers is a transfer abstraction used to transfer data from host
/// to device local memory (heap 0 memory)
const StagingBuffers = @This();

last_buffer_used: usize,
staging_ramps: []StagingRamp,
wait_all_fences: []vk.Fence,
deferred_buffer_transfers: std.ArrayList(DeferBufferTransfer),

pub fn init(ctx: Context, allocator: Allocator, buffer_count: usize) !StagingBuffers {
    const staging_ramps = try allocator.alloc(StagingRamp, buffer_count);
    errdefer allocator.free(staging_ramps);

    var buffers_initialized: usize = 0;
    for (staging_ramps) |*ramp, i| {
        ramp.* = try StagingRamp.init(ctx, allocator);
        buffers_initialized = i + 1;
    }
    errdefer {
        var i: usize = 0;
        while (i < buffers_initialized) : (i += 1) {
            staging_ramps[i].deinit(ctx);
        }
    }

    const wait_all_fences = try allocator.alloc(vk.Fence, buffer_count);
    errdefer allocator.free(wait_all_fences);

    return StagingBuffers{
        .last_buffer_used = 0,
        .staging_ramps = staging_ramps,
        .wait_all_fences = wait_all_fences,
        .deferred_buffer_transfers = std.ArrayList(DeferBufferTransfer).init(allocator),
    };
}

pub fn flush(self: *StagingBuffers, ctx: Context) !void {
    for (self.staging_ramps) |*ramp| {
        try ramp.flush(ctx);
    }

    for (self.deferred_buffer_transfers.items) |transfer| {
        try self.transferToBuffer(transfer.ctx, transfer.buffer, transfer.offset, u8, transfer.data);
    }
    self.deferred_buffer_transfers.clearRetainingCapacity();
}

/// transfer to device image
pub fn transferToImage(
    self: *StagingBuffers,
    ctx: Context,
    src_layout: vk.ImageLayout,
    dst_layout: vk.ImageLayout,
    image: vk.Image,
    width: u32,
    height: u32,
    comptime T: type,
    data: []const T,
) !void {
    const transfer_zone = tracy.ZoneN(@src(), "schedule images transfer");
    defer transfer_zone.End();

    // TODO: handle transfers greater than buffer size (split across ramps and frames!)

    const index = self.getIdleRamp(ctx, data.len * @sizeOf(T)) catch |err| {
        switch (err) {
            error.StagingRampsFull => {
                std.debug.panic("TODO: handle image transfer defer", .{});
            },
            else => return err,
        }
    };
    try self.staging_ramps[index].transferToImage(ctx, src_layout, dst_layout, image, width, height, T, data);
}

/// transfer to device storage buffer
pub fn transferToBuffer(self: *StagingBuffers, ctx: Context, buffer: *GpuBufferMemory, offset: vk.DeviceSize, comptime T: type, data: []const T) !void {
    const transfer_zone = tracy.ZoneN(@src(), "schedule buffers transfer");
    defer transfer_zone.End();

    const index = self.getIdleRamp(ctx, data.len * @sizeOf(T)) catch |err| {
        switch (err) {
            error.StagingRampsFull => {
                // TODO: RC: data might change between transfer call and final flush ...
                try self.deferred_buffer_transfers.append(DeferBufferTransfer{
                    .ctx = ctx,
                    .buffer = buffer,
                    .offset = offset,
                    .data = std.mem.sliceAsBytes(data),
                });
                return;
            },
            else => return err,
        }
    };
    try self.staging_ramps[index].transferToBuffer(ctx, buffer, offset, T, data);
}

// wait until all pending transfers are done
pub fn waitIdle(self: StagingBuffers, ctx: Context) !void {
    for (self.staging_ramps) |ramp, i| {
        self.wait_all_fences[i] = ramp.fence;
    }
    _ = try ctx.vkd.waitForFences(
        ctx.logical_device,
        @intCast(u32, self.wait_all_fences.len),
        self.wait_all_fences.ptr,
        vk.TRUE,
        std.math.maxInt(u64),
    );
}

pub fn deinit(self: StagingBuffers, ctx: Context, allocator: Allocator) void {
    for (self.staging_ramps) |*ramp| {
        ramp.deinit(ctx);
    }
    allocator.free(self.staging_ramps);
    self.deferred_buffer_transfers.deinit();
}

inline fn getIdleRamp(self: *StagingBuffers, ctx: Context, size: vk.DeviceSize) !usize {
    var full_ramps: usize = 0;
    // get a idle buffer
    var index: usize = blk: {
        for (self.staging_ramps) |ramp, i| {
            // if ramp is out of memory
            if (ramp.buffer_cursor + size >= buffer_size) {
                full_ramps += 1;
                continue;
            }
            // if ramp is idle
            if ((try ctx.vkd.getFenceStatus(ctx.logical_device, ramp.fence)) == .success) {
                break :blk i;
            }
        }
        break :blk (self.last_buffer_used + 1) % self.staging_ramps.len;
    };
    if (full_ramps >= self.staging_ramps.len) {
        return error.StagingRampsFull;
    }

    defer self.last_buffer_used = index;

    // wait for previous transfer
    _ = try ctx.vkd.waitForFences(
        ctx.logical_device,
        1,
        @ptrCast([*]const vk.Fence, &self.staging_ramps[index].fence),
        vk.TRUE,
        std.math.maxInt(u64),
    );

    return index;
}

const RegionCount = 32;
const BufferCopies = struct {
    len: u32,
    regions: [RegionCount]vk.BufferCopy,
};

const BufferImageCopy = struct {
    image: vk.Image,
    src_layout: vk.ImageLayout,
    dst_layout: vk.ImageLayout,
    region: vk.BufferImageCopy,
};

// TODO: benchmark ArrayHashMap vs HashMap
// we do not need hash cache as the buffer and image type
// are u64 opaque types (so eql is cheap)
///   hash(self, K) u32
///   eql(self, K, K, usize) bool
const BufferCopyMapContext = struct {
    pub fn hash(self: BufferCopyMapContext, key: vk.Buffer) u32 {
        _ = self;
        const v = @bitCast(u64, key);
        const left_value = (v >> 32) / 4;
        const right_value = ((v << 32) >> 32) / 2;
        return @intCast(u32, left_value + right_value);
    }

    pub fn eql(self: BufferCopyMapContext, a: vk.Buffer, b: vk.Buffer, i: usize) bool {
        _ = self;
        _ = i;
        return a == b;
    }
};
const BufferCopyMap = std.ArrayHashMap(vk.Buffer, BufferCopies, BufferCopyMapContext, false);
const ImageCopyList = std.ArrayList(BufferImageCopy);

const fence_info = vk.FenceCreateInfo{
    .flags = .{
        .signaled_bit = true,
    },
};
const StagingRamp = struct {
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
    fence: vk.Fence,
    buffer_cursor: vk.DeviceSize,
    device_buffer_memory: GpuBufferMemory,

    buffer_copy: BufferCopyMap,
    image_copy: ImageCopyList,

    fn init(ctx: Context, allocator: Allocator) !StagingRamp {
        const device_buffer_memory = try GpuBufferMemory.init(
            ctx,
            buffer_size,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true, .device_local_bit = true },
        );
        errdefer device_buffer_memory.deinit(ctx);

        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{},
            .queue_family_index = ctx.queue_indices.graphics,
        };
        const command_pool = try ctx.vkd.createCommandPool(ctx.logical_device, &pool_info, null);
        errdefer ctx.vkd.destroyCommandPool(ctx.logical_device, command_pool, null);

        const command_buffer = try render.pipeline.createCmdBuffer(ctx, command_pool);
        errdefer ctx.vkd.freeCommandBuffers(
            ctx.logical_device,
            command_pool,
            @intCast(u32, 1),
            @ptrCast([*]const vk.CommandBuffer, &command_buffer),
        );

        const fence = try ctx.vkd.createFence(ctx.logical_device, &fence_info, null);
        errdefer ctx.vkd.destroyFence(ctx.logical_device, fence, null);

        return StagingRamp{
            .command_pool = command_pool,
            .command_buffer = command_buffer,
            .fence = fence,
            .device_buffer_memory = device_buffer_memory,
            .buffer_cursor = 0,
            .buffer_copy = BufferCopyMap.init(allocator),
            .image_copy = ImageCopyList.init(allocator),
        };
    }

    fn transferToImage(
        self: *StagingRamp,
        ctx: Context,
        src_layout: vk.ImageLayout,
        dst_layout: vk.ImageLayout,
        image: vk.Image,
        width: u32,
        height: u32,
        comptime T: type,
        data: []const T,
    ) !void {
        const data_size = data.len * @sizeOf(T);

        try self.device_buffer_memory.map(ctx, self.buffer_cursor, data_size);
        defer self.device_buffer_memory.unmap(ctx);

        var dest_location = @ptrCast([*]T, @alignCast(@alignOf(T), self.device_buffer_memory.mapped) orelse unreachable);

        {
            // runtime safety is turned off for performance
            @setRuntimeSafety(false);
            for (data) |elem, i| {
                dest_location[i] = elem;
            }
        }

        const region = vk.BufferImageCopy{
            .buffer_offset = self.buffer_cursor,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = vk.ImageSubresourceLayers{
                .aspect_mask = .{
                    .color_bit = true,
                },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{
                .x = 0,
                .y = 0,
                .z = 0,
            },
            .image_extent = .{
                .width = width,
                .height = height,
                .depth = 1,
            },
        };
        try self.image_copy.append(BufferImageCopy{
            .image = image,
            .src_layout = src_layout,
            .dst_layout = dst_layout,
            .region = region,
        });
        self.buffer_cursor += data_size;
    }

    fn transferToBuffer(self: *StagingRamp, ctx: Context, dst: *GpuBufferMemory, offset: vk.DeviceSize, comptime T: type, data: []const T) !void {
        const data_size = data.len * @sizeOf(T);
        if (offset + data_size > dst.size) {
            return error.DestOutOfDeviceMemory;
        }
        if (self.buffer_cursor + data_size > buffer_size) {
            return error.StageOutOfDeviceMemory; // current buffer is out of memory
        }

        try self.device_buffer_memory.map(ctx, self.buffer_cursor, data_size);
        defer self.device_buffer_memory.unmap(ctx);

        // TODO: here we align as u8 and later we reinterpret data as a byte array.
        //       This is because we get runtime errors from using T and data directly.
        //       It *SEEMS* like alignment error is a zig bug, but might as well be an application bug.
        //       If the bug is an application bug, then we need to find a way to fix it instead of disabling safety ...
        var dest_location = @ptrCast([*]u8, @alignCast(@alignOf(u8), self.device_buffer_memory.mapped) orelse unreachable);
        {
            // runtime safety is turned off for performance
            @setRuntimeSafety(false);
            const byte_data = std.mem.sliceAsBytes(data);
            for (byte_data) |elem, i| {
                dest_location[i] = elem;
            }
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

    fn flush(self: *StagingRamp, ctx: Context) !void {
        if (self.buffer_cursor == 0) return;

        // wait for previous transfer
        _ = try ctx.vkd.waitForFences(
            ctx.logical_device,
            1,
            @ptrCast([*]const vk.Fence, &self.fence),
            vk.TRUE,
            std.math.maxInt(u64),
        );
        // lock ramp
        try ctx.vkd.resetFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.fence));

        try self.device_buffer_memory.map(ctx, 0, self.buffer_cursor);
        try self.device_buffer_memory.flush(ctx, 0, self.buffer_cursor);
        self.device_buffer_memory.unmap(ctx);
        try ctx.vkd.resetCommandPool(ctx.logical_device, self.command_pool, .{});

        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{
                .one_time_submit_bit = true,
            },
            .p_inheritance_info = null,
        };
        try ctx.vkd.beginCommandBuffer(self.command_buffer, &begin_info);

        { // copy buffer jobs
            var iter = self.buffer_copy.iterator();
            while (iter.next()) |some| {
                ctx.vkd.cmdCopyBuffer(self.command_buffer, self.device_buffer_memory.buffer, some.key_ptr.*, some.value_ptr.len, &some.value_ptr.*.regions);
            }

            for (self.image_copy.items) |copy| {
                {
                    const transfer_transition = Texture.getTransitionBits(copy.src_layout, .transfer_dst_optimal);
                    const transfer_barrier = vk.ImageMemoryBarrier{
                        .src_access_mask = transfer_transition.src_mask,
                        .dst_access_mask = transfer_transition.dst_mask,
                        .old_layout = copy.src_layout,
                        .new_layout = .transfer_dst_optimal,
                        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .image = copy.image,
                        .subresource_range = vk.ImageSubresourceRange{
                            .aspect_mask = .{
                                .color_bit = true,
                            },
                            .base_mip_level = 0,
                            .level_count = 1,
                            .base_array_layer = 0,
                            .layer_count = 1,
                        },
                    };
                    ctx.vkd.cmdPipelineBarrier(
                        self.command_buffer,
                        transfer_transition.src_stage,
                        transfer_transition.dst_stage,
                        vk.DependencyFlags{},
                        0,
                        undefined,
                        0,
                        undefined,
                        1,
                        @ptrCast([*]const vk.ImageMemoryBarrier, &transfer_barrier),
                    );
                }

                ctx.vkd.cmdCopyBufferToImage(
                    self.command_buffer,
                    self.device_buffer_memory.buffer,
                    copy.image,
                    .transfer_dst_optimal,
                    1,
                    @ptrCast([*]const vk.BufferImageCopy, &copy.region),
                );

                {
                    const read_only_transition = Texture.getTransitionBits(.transfer_dst_optimal, copy.dst_layout);
                    const read_only_barrier = vk.ImageMemoryBarrier{
                        .src_access_mask = read_only_transition.src_mask,
                        .dst_access_mask = read_only_transition.dst_mask,
                        .old_layout = .transfer_dst_optimal,
                        .new_layout = copy.dst_layout,
                        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .image = copy.image,
                        .subresource_range = vk.ImageSubresourceRange{
                            .aspect_mask = .{
                                .color_bit = true,
                            },
                            .base_mip_level = 0,
                            .level_count = 1,
                            .base_array_layer = 0,
                            .layer_count = 1,
                        },
                    };
                    ctx.vkd.cmdPipelineBarrier(
                        self.command_buffer,
                        read_only_transition.src_stage,
                        read_only_transition.dst_stage,
                        vk.DependencyFlags{},
                        0,
                        undefined,
                        0,
                        undefined,
                        1,
                        @ptrCast([*]const vk.ImageMemoryBarrier, &read_only_barrier),
                    );
                }
            }
        }
        try ctx.vkd.endCommandBuffer(self.command_buffer);

        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        };
        try ctx.vkd.queueSubmit(ctx.graphics_queue, 1, @ptrCast([*]const vk.SubmitInfo, &submit_info), self.fence);

        self.buffer_copy.clearRetainingCapacity();
        self.image_copy.clearRetainingCapacity();
        self.buffer_cursor = 0;
    }

    fn deinit(self: *StagingRamp, ctx: Context) void {
        ctx.vkd.freeCommandBuffers(
            ctx.logical_device,
            self.command_pool,
            @intCast(u32, 1),
            @ptrCast([*]const vk.CommandBuffer, &self.command_buffer),
        );
        ctx.vkd.destroyCommandPool(ctx.logical_device, self.command_pool, null);
        self.device_buffer_memory.deinit(ctx);
        ctx.vkd.destroyFence(ctx.logical_device, self.fence, null);

        self.buffer_copy.deinit();
        self.image_copy.deinit();
    }
};
