const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const tracy = @import("../../tracy.zig");

const render = @import("../render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;
const Texture = render.Texture;

pub const buffer_size = 63 * GpuBufferMemory.bytes_in_mb;

/// StagingBuffers is a transfer abstraction used to transfer data from host
/// to device local memory (heap 0 memory)
const StagingBuffers = @This();

last_buffer_used: usize,
staging_ramps: []StagingRamp,

pub fn init(ctx: Context, allocator: Allocator, buffer_count: usize) !StagingBuffers {
    const staging_ramps = try allocator.alloc(StagingRamp, buffer_count);
    errdefer allocator.free(staging_ramps);

    var buffers_initialized: usize = 0;
    for (staging_ramps) |*ramp, i| {
        ramp.* = try StagingRamp.init(ctx);
        buffers_initialized = i + 1;
    }
    errdefer {
        var i: usize = 0;
        while (i < buffers_initialized) : (i += 1) {
            ramp[i].deinit(ctx);
        }
    }

    return StagingBuffers{
        .last_buffer_used = 0,
        .staging_ramps = staging_ramps,
    };
}

/// transfer to device image
pub fn transferToImage(self: *StagingBuffers, ctx: Context, image: vk.Image, width: u32, height: u32, comptime T: type, data: []const T) !void {
    const transfer_zone = tracy.ZoneN(@src(), "staging images transfer");
    defer transfer_zone.End();

    // TODO: support splitting single transfer to multiple buffers
    std.debug.assert(data.len * @sizeOf(T) < buffer_size);

    const index = try self.getIdleRamp(ctx);

    try ctx.vkd.resetCommandPool(ctx.logical_device, self.staging_ramps[index].command_pool, .{});
    try self.staging_ramps[index].device_buffer_memory.transferToDevice(ctx, T, 0, data);
    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{
            .one_time_submit_bit = true,
        },
        .p_inheritance_info = null,
    };
    try ctx.vkd.beginCommandBuffer(self.staging_ramps[index].command_buffer, &begin_info);
    {
        const transfer_transition = Texture.getTransitionBits(.@"undefined", .transfer_dst_optimal);
        const transfer_barrier = vk.ImageMemoryBarrier{
            .src_access_mask = transfer_transition.src_mask,
            .dst_access_mask = transfer_transition.dst_mask,
            .old_layout = .@"undefined",
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
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
            self.staging_ramps[index].command_buffer,
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

    const region = vk.BufferImageCopy{
        .buffer_offset = 0,
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
    ctx.vkd.cmdCopyBufferToImage(
        self.staging_ramps[index].command_buffer,
        self.staging_ramps[index].device_buffer_memory.buffer,
        image,
        .transfer_dst_optimal,
        1,
        @ptrCast([*]const vk.BufferImageCopy, &region),
    );

    {
        const read_only_transition = Texture.getTransitionBits(.transfer_dst_optimal, .shader_read_only_optimal);
        const read_only_barrier = vk.ImageMemoryBarrier{
            .src_access_mask = read_only_transition.src_mask,
            .dst_access_mask = read_only_transition.dst_mask,
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
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
            self.staging_ramps[index].command_buffer,
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
    try ctx.vkd.endCommandBuffer(self.staging_ramps[index].command_buffer);
    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.staging_ramps[index].command_buffer),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };
    try ctx.vkd.queueSubmit(ctx.graphics_queue, 1, @ptrCast([*]const vk.SubmitInfo, &submit_info), self.staging_ramps[index].fence);
}

/// transfer to device storage buffer
pub fn transferToBuffer(self: *StagingBuffers, ctx: Context, buffer: *GpuBufferMemory, offset: vk.DeviceSize, comptime T: type, data: []const T) !void {
    const transfer_zone = tracy.ZoneN(@src(), "staging buffers transfer");
    defer transfer_zone.End();

    // TODO: support splitting single transfer to multiple buffers
    std.debug.assert(data.len * @sizeOf(T) < buffer_size);

    const index = try self.getIdleRamp(ctx);

    // transfer data to staging buffer
    {
        const data_size = data.len * @sizeOf(T);
        try self.staging_ramps[index].device_buffer_memory.map(ctx, 0, data_size);
        defer self.staging_ramps[index].device_buffer_memory.unmap(ctx);

        var dest_location = @ptrCast([*]T, @alignCast(@alignOf(T), self.staging_ramps[index].device_buffer_memory.mapped) orelse unreachable);

        // runtime safety is turned off for performance
        @setRuntimeSafety(false);
        for (data) |elem, i| {
            dest_location[i] = elem;
        }

        // TODO: ONLY FLUSH AND COPY AT END OF FRAME, OR WHEN OUT OF SPACE IN STAGING BUFFERS
        // send changes to GPU
        try self.staging_ramps[index].device_buffer_memory.flush(ctx, 0, data_size);
    }

    const copy_config = .{
        .src_offset = 0,
        .dst_offset = offset,
        .size = data.len * @sizeOf(T),
    };
    try ctx.vkd.resetCommandPool(ctx.logical_device, self.staging_ramps[index].command_pool, .{});
    try self.staging_ramps[index].device_buffer_memory.manualCopy(
        ctx,
        buffer,
        self.staging_ramps[index].command_buffer,
        self.staging_ramps[index].fence,
        copy_config,
    );
}

pub fn deinit(self: StagingBuffers, ctx: Context, allocator: Allocator) void {
    for (self.staging_ramps) |ramp| {
        ramp.deinit(ctx);
    }
    allocator.free(self.staging_ramps);
}

inline fn getIdleRamp(self: *StagingBuffers, ctx: Context) !usize {
    // get a idle buffer
    var index: usize = blk: {
        for (self.staging_ramps) |ramp, i| {
            if ((try ctx.vkd.getFenceStatus(ctx.logical_device, ramp.fence)) == .success) {
                break :blk i;
            }
        }
        break :blk (self.last_buffer_used + 1) % self.staging_ramps.len;
    };
    defer self.last_buffer_used = index;

    // wait for previous transfer
    _ = try ctx.vkd.waitForFences(
        ctx.logical_device,
        1,
        @ptrCast([*]const vk.Fence, &self.staging_ramps[index].fence),
        vk.TRUE,
        std.math.maxInt(u64),
    );
    try ctx.vkd.resetFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.staging_ramps[index].fence));

    return index;
}

const fence_info = vk.FenceCreateInfo{
    .flags = .{
        .signaled_bit = true,
    },
};
const StagingRamp = struct {
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
    fence: vk.Fence,
    device_buffer_memory: GpuBufferMemory,

    fn init(ctx: Context) !StagingRamp {
        const device_buffer_memory = try GpuBufferMemory.init(
            ctx,
            buffer_size,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .device_local_bit = true },
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
        };
    }

    fn deinit(self: StagingRamp, ctx: Context) void {
        ctx.vkd.freeCommandBuffers(
            ctx.logical_device,
            self.command_pool,
            @intCast(u32, 1),
            @ptrCast([*]const vk.CommandBuffer, &self.command_buffer),
        );
        ctx.vkd.destroyCommandPool(ctx.logical_device, self.command_pool, null);
        self.device_buffer_memory.deinit(ctx);
        ctx.vkd.destroyFence(ctx.logical_device, self.fence, null);
    }
};
