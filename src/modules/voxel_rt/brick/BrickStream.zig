const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const vk = @import("vulkan");
const tracy = @import("ztracy");

const render = @import("../../render.zig");
const Context = render.Context;
const SimpleStagingBuffer = render.SimpleStagingBuffer;

const ray_pipeline_types = @import("../ray_pipeline_types.zig");
const BrickLimits = ray_pipeline_types.BrickLimits;
const Brick = ray_pipeline_types.Brick;
const BrickGridMetadata = ray_pipeline_types.BrickGridMetadata;
const BrickLoadRequest = ray_pipeline_types.BrickLoadRequest;

const RayDeviceResources = @import("../RayDeviceResources.zig");
const Resource = RayDeviceResources.Resource;

const HostBrickState = @import("HostBrickState.zig");

const BrickStream = @This();

allocator: Allocator,
frame_snapshot: FrameSnapshot,

brick_staging_buffer: SimpleStagingBuffer,

brick_load_requests: []BrickLoadRequest,
new_bricks: []Brick,
new_material_indices: []HostBrickState.material_index,

unload_request_buf_flush_from: usize = 0,
unload_request_buf_flush_to: usize = 0,

load_request_buf_flush_from: usize = 0,
load_request_buf_flush_to: usize = 0,

load_voxel_buf_flush_from: usize = 0,
load_voxel_buf_flush_to: usize = 0,

pub fn init(allocator: Allocator, ctx: Context, brick_limits: BrickLimits) !BrickStream {
    const zone = tracy.ZoneN(@src(), @typeName(BrickStream) ++ " " ++ @src().fn_name);
    defer zone.End();

    var frame_snapshot = try FrameSnapshot.init(allocator, brick_limits);
    errdefer frame_snapshot.deinit(allocator);

    const brick_staging_buffer = try SimpleStagingBuffer.init(ctx, allocator);
    errdefer brick_staging_buffer.deinit(ctx);

    const brick_load_requests = try allocator.alloc(BrickLoadRequest, brick_limits.max_load_request_count);
    errdefer allocator.free(brick_load_requests);

    const new_bricks = try allocator.alloc(Brick, brick_limits.max_load_request_count);
    errdefer allocator.free(new_bricks);

    const new_material_indices = try allocator.alloc(HostBrickState.material_index, brick_limits.max_load_request_count * 512);
    errdefer allocator.free(new_material_indices);

    return BrickStream{
        .allocator = allocator,
        .frame_snapshot = frame_snapshot,
        .brick_staging_buffer = brick_staging_buffer,
        .brick_load_requests = brick_load_requests,
        .new_bricks = new_bricks,
        .new_material_indices = new_material_indices,
    };
}

pub fn deinit(self: BrickStream, ctx: Context) void {
    var mut_frame_snapshot = @constCast(&self.frame_snapshot);
    mut_frame_snapshot.deinit(self.allocator);

    self.brick_staging_buffer.deinit(ctx);
    self.allocator.free(self.brick_load_requests);
    self.allocator.free(self.new_bricks);
    self.allocator.free(self.new_material_indices);
}

/// Fetch device state to host
pub fn deviceToHostSync(self: *BrickStream, ctx: Context, ray_device_resources: *RayDeviceResources) !void {
    // sync brick request data on to the host
    try ray_device_resources.invalidateBrickRequestData(ctx);
    self.frame_snapshot.snapshot(ray_device_resources);
}

pub fn hostToDeviceSync(self: *BrickStream, ctx: Context) !void {
    // If we have any transfers
    if (self.brick_staging_buffer.buffer_cursor != 0) {
        try self.brick_staging_buffer.sync(ctx);
    }
}

/// In the event a brick was updated on host,
/// the brick stream will request the device to unload invalid bricks
pub fn prepareBrickUnloads(
    self: *BrickStream,
    host_brick_state: *HostBrickState,
    ray_device_resources: *RayDeviceResources,
) !void {
    const data_snapshot = self.frame_snapshot.asDataSnapshot();

    const active_bricks: u32 = @intCast(data_snapshot.brick_limits.active_bricks);
    std.debug.assert(data_snapshot.brick_limits.max_active_bricks >= active_bricks);

    self.unload_request_buf_flush_from = 0;
    self.unload_request_buf_flush_to = 0;

    // If a brick is incoherent, then we must ask the device to unload the brick to reupload
    const incoherent_brick_count: usize = @intCast(host_brick_state.inchoherent_bricks.count());

    host_brick_state.brick_limits = data_snapshot.brick_limits;

    if (incoherent_brick_count > 0) {
        const brick_unload_buffer_index = (RayDeviceResources.Resource{ .host_and_device = .brick_unload_request_s }).toBufferIndex();
        std.debug.assert(@sizeOf(c_uint) == @sizeOf(u32));

        const incoherent_unload_offset: vk.DeviceSize = @intCast(@sizeOf(u32) * host_brick_state.brick_limits.unload_request_count);

        // Changing this call will affect appendUnloadCommands
        try self.brick_staging_buffer.transferToBuffer(
            &ray_device_resources.request_buffer,
            ray_device_resources.buffer_infos[brick_unload_buffer_index].offset + incoherent_unload_offset,
            u32,
            host_brick_state.inchoherent_bricks.keys(),
        );
        self.unload_request_buf_flush_to += 1;

        host_brick_state.brick_limits.unload_request_count += @intCast(incoherent_brick_count);
    }

    if (host_brick_state.brick_limits.unload_request_count > 0) {
        host_brick_state.brick_limits.active_bricks -= @intCast(host_brick_state.brick_limits.unload_request_count);

        const brick_req_limits_buffer_index = (RayDeviceResources.Resource{ .host_and_device = .brick_req_limits_s }).toBufferIndex();
        const limits_slice = [1]ray_pipeline_types.BrickLimits{host_brick_state.brick_limits};
        // Changing this call will affect appendUnloadCommands
        try self.brick_staging_buffer.transferToBuffer(
            &ray_device_resources.request_buffer,
            ray_device_resources.buffer_infos[brick_req_limits_buffer_index].offset,
            ray_pipeline_types.BrickLimits,
            &limits_slice,
        );
        self.unload_request_buf_flush_to += 1;
    }
}

// TODO: bug: incoherent brick also being brick requested by gpu will lead to corruption
/// In the event a brick was updated on host or a new brick is ray casted on device:
/// Upload new bricks to the device and signal to the loading shader where they are placed
pub fn prepareBrickLoads(
    self: *BrickStream,
    host_brick_state: *HostBrickState,
    ray_device_resources: *RayDeviceResources,
) !void {
    const zone = tracy.ZoneN(@src(), @typeName(BrickStream) ++ " " ++ @src().fn_name);
    defer zone.End();

    const data_snapshot = self.frame_snapshot.asDataSnapshot();
    std.debug.assert(host_brick_state.brick_limits.max_load_request_count > 0);
    std.debug.assert(host_brick_state.brick_limits.max_unload_request_count > 0);

    // brick_limits is incorherent as we captured before the unloading
    const active_bricks: u32 = @max(
        host_brick_state.brick_limits.active_bricks,
        0,
    );
    std.debug.assert(host_brick_state.brick_limits.max_active_bricks >= active_bricks);

    const max_load_count = host_brick_state.brick_limits.max_load_request_count - active_bricks;

    // If a brick is incoherent, then we must ask the device to load the brick to reupload
    const incoherent_brick_count: usize = @intCast(host_brick_state.inchoherent_bricks.count());

    // TODO: easy to deal with, just only empty the incoherent bricks that was updated
    // TODO: we should also cache brick_load_requests that were not handled
    std.debug.assert(incoherent_brick_count <= max_load_count);

    const load_request_count: usize = @intCast(@min(
        host_brick_state.brick_limits.load_request_count,
        max_load_count - incoherent_brick_count,
    ));

    const total_load_requests: usize = @intCast(@min(
        incoherent_brick_count + load_request_count,
        max_load_count,
    ));

    self.load_request_buf_flush_from = self.unload_request_buf_flush_to;
    self.load_request_buf_flush_to = self.load_request_buf_flush_from;

    self.load_voxel_buf_flush_from = 0;
    self.load_voxel_buf_flush_to = 0;

    if (total_load_requests > 0) {
        const new_bricks = self.new_bricks[0..total_load_requests];
        const brick_load_requests = self.brick_load_requests[0..total_load_requests];
        const new_material_indices = self.new_material_indices[0 .. total_load_requests * 512];

        std.debug.assert(host_brick_state.brick_limits.max_active_bricks >= active_bricks);

        const load_req_slices: [2][]const c_uint = .{
            data_snapshot.brick_load_requests[0..load_request_count],
            host_brick_state.inchoherent_bricks.keys(),
        };
        var load_req_initalized_count: usize = 0;

        inline for (load_req_slices) |load_requests| {
            const from = load_req_initalized_count;
            const to = from + load_requests.len;
            for (
                load_requests,
                new_bricks[from..to],
                brick_load_requests[from..to],
                active_bricks + from..,
                from..,
            ) |
                load_index,
                *new_brick,
                *brick_load_request,
                brick_buffer_index,
                loop_iter,
            | {
                const brick_index: u32 = @intCast(host_brick_state.brick_indices[load_index].index);
                new_brick.* = host_brick_state.bricks[brick_index];

                {
                    const mat_indices_dest = dest_blk: {
                        const start = loop_iter * 512;
                        const end = start + 512;
                        break :dest_blk new_material_indices[start..end];
                    };

                    const mat_indices_src = src_blk: {
                        const start = brick_index * 512;
                        const end = start + 512;
                        break :src_blk host_brick_state.voxel_material_indices[start..end];
                    };

                    @memcpy(mat_indices_dest, mat_indices_src);
                }

                brick_load_request.* = ray_pipeline_types.BrickLoadRequest{
                    .brick_index_index = load_index,
                    .brick_index_32b = @intCast(brick_buffer_index),
                };
            }

            load_req_initalized_count += load_requests.len;
        }

        if (incoherent_brick_count > 0) {
            // Transfer brick set
            // TODO: For now we just send the full grid brick set bits since it is relatively small amount of data
            const brick_set_buffer_index = (RayDeviceResources.Resource{ .device = .bricks_set_s }).toBufferIndex();
            try self.brick_staging_buffer.transferToBuffer(
                &ray_device_resources.voxel_scene_buffer,
                ray_device_resources.buffer_infos[brick_set_buffer_index].offset,
                u8,
                host_brick_state.brick_set,
            );
            self.load_voxel_buf_flush_to += 1;
        }

        // Transfer bricks
        {
            const brick_buffer_index = (RayDeviceResources.Resource{ .device = .bricks_b }).toBufferIndex();
            const new_bricks_offset: vk.DeviceSize = @intCast(active_bricks * @sizeOf(ray_pipeline_types.Brick));
            try self.brick_staging_buffer.transferToBuffer(
                &ray_device_resources.voxel_scene_buffer,
                ray_device_resources.buffer_infos[brick_buffer_index].offset + new_bricks_offset,
                ray_pipeline_types.Brick,
                new_bricks,
            );
            self.load_voxel_buf_flush_to += 1;
        }

        // Transfer material indices
        {
            const material_indices_index = (RayDeviceResources.Resource{ .device = .material_indices_b }).toBufferIndex();
            const new_material_indices_offset: vk.DeviceSize = @intCast(active_bricks * 512 * @sizeOf(HostBrickState.material_index));

            try self.brick_staging_buffer.transferToBuffer(
                &ray_device_resources.voxel_scene_buffer,
                ray_device_resources.buffer_infos[material_indices_index].offset + new_material_indices_offset,
                HostBrickState.material_index,
                new_material_indices,
            );
            self.load_voxel_buf_flush_to += 1;
        }

        // Transfer patch work required to set gpu indices
        {
            const brick_load_request_result_index = (RayDeviceResources.Resource{ .host_and_device = .brick_load_request_result_s }).toBufferIndex();

            try self.brick_staging_buffer.transferToBuffer(
                &ray_device_resources.request_buffer,
                ray_device_resources.buffer_infos[brick_load_request_result_index].offset,
                ray_pipeline_types.BrickLoadRequest,
                brick_load_requests,
            );
            self.load_request_buf_flush_to += 1;
        }

        host_brick_state.brick_limits = host_brick_state.brick_limits;
        host_brick_state.brick_limits.active_bricks = @as(c_int, @intCast(active_bricks + total_load_requests));
        host_brick_state.brick_limits.load_request_count = @intCast(total_load_requests);

        const brick_req_limits_buffer_index = (RayDeviceResources.Resource{ .host_and_device = .brick_req_limits_s }).toBufferIndex();
        const limits_slice = [1]ray_pipeline_types.BrickLimits{host_brick_state.brick_limits};
        try self.brick_staging_buffer.transferToBuffer(
            &ray_device_resources.request_buffer,
            ray_device_resources.buffer_infos[brick_req_limits_buffer_index].offset,
            ray_pipeline_types.BrickLimits,
            &limits_slice,
        );
        self.load_request_buf_flush_to += 1;
    }
}

pub fn appendUnloadCommands(
    self: *BrickStream,
    ctx: Context,
    command_buffer: vk.CommandBuffer,
    request_buffer: vk.Buffer,
) !void {
    const zone = tracy.ZoneN(@src(), @typeName(BrickStream) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (render.consts.enable_validation_layers) {
        const label_info = vk.DebugUtilsLabelEXT{
            .p_label_name = @typeName(BrickStream) ++ " " ++ @src().fn_name,
            .color = [_]f32{ 0.4, 0.8, 0.2, 0.5 },
        };
        ctx.vkd.cmdBeginDebugUtilsLabelEXT(command_buffer, &label_info);
    }
    defer {
        if (render.consts.enable_validation_layers) {
            ctx.vkd.cmdEndDebugUtilsLabelEXT(command_buffer);
        }
    }

    // if we have staged the unloading
    if (self.unload_request_buf_flush_to - self.unload_request_buf_flush_from != 0) {
        const brick_buffer_memory_barrier = [_]vk.BufferMemoryBarrier{.{
            .src_access_mask = .{ .shader_read_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
            .src_queue_family_index = ctx.queue_indices.compute,
            .dst_queue_family_index = ctx.queue_indices.compute,
            .buffer = request_buffer,
            .offset = 0,
            .size = vk.WHOLE_SIZE,
        }};
        ctx.vkd.cmdPipelineBarrier(
            command_buffer,
            .{ .compute_shader_bit = true },
            .{ .compute_shader_bit = true },
            .{},
            0,
            undefined,
            brick_buffer_memory_barrier.len,
            &brick_buffer_memory_barrier,
            0,
            undefined,
        );

        try self.brick_staging_buffer.partialFlush(
            ctx,
            command_buffer,
            request_buffer,
            self.unload_request_buf_flush_from,
            self.unload_request_buf_flush_to,
        );
    }
}

pub fn appendLoadCommands(
    self: *BrickStream,
    ctx: Context,
    host_brick_state: HostBrickState,
    command_buffer: vk.CommandBuffer,
    voxel_scene_buffer: vk.Buffer,
    request_buffer: vk.Buffer,
) !void {
    _ = host_brick_state;
    const zone = tracy.ZoneN(@src(), @typeName(BrickStream) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (render.consts.enable_validation_layers) {
        const label_info = vk.DebugUtilsLabelEXT{
            .p_label_name = @typeName(BrickStream) ++ " " ++ @src().fn_name,
            .color = [_]f32{ 0.4, 0.8, 0.2, 0.5 },
        };
        ctx.vkd.cmdBeginDebugUtilsLabelEXT(command_buffer, &label_info);
    }
    defer {
        if (render.consts.enable_validation_layers) {
            ctx.vkd.cmdEndDebugUtilsLabelEXT(command_buffer);
        }
    }

    const has_request_pending = (self.load_request_buf_flush_to - self.load_request_buf_flush_from) != 0;
    const has_voxel_pending = (self.load_voxel_buf_flush_to - self.load_voxel_buf_flush_from) != 0;
    if (has_request_pending or has_voxel_pending) {
        const brick_buffer_memory_barrier = [_]vk.BufferMemoryBarrier{ .{
            .src_access_mask = .{ .shader_read_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
            .src_queue_family_index = ctx.queue_indices.compute,
            .dst_queue_family_index = ctx.queue_indices.compute,
            .buffer = voxel_scene_buffer,
            .offset = 0,
            .size = vk.WHOLE_SIZE,
        }, .{
            .src_access_mask = .{ .shader_read_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
            .src_queue_family_index = ctx.queue_indices.compute,
            .dst_queue_family_index = ctx.queue_indices.compute,
            .buffer = request_buffer,
            .offset = 0,
            .size = vk.WHOLE_SIZE,
        } };
        ctx.vkd.cmdPipelineBarrier(
            command_buffer,
            .{ .compute_shader_bit = true },
            .{ .compute_shader_bit = true },
            .{},
            0,
            undefined,
            brick_buffer_memory_barrier.len,
            &brick_buffer_memory_barrier,
            0,
            undefined,
        );

        if (has_request_pending) {
            try self.brick_staging_buffer.partialFlush(
                ctx,
                command_buffer,
                request_buffer,
                self.load_request_buf_flush_from,
                self.load_request_buf_flush_to,
            );
        }

        if (has_voxel_pending) {
            try self.brick_staging_buffer.partialFlush(
                ctx,
                command_buffer,
                voxel_scene_buffer,
                self.load_voxel_buf_flush_from,
                self.load_voxel_buf_flush_to,
            );
        }
    }

    self.brick_staging_buffer.empty();
}

pub const DataFrameSnapshot = struct {
    brick_limits: BrickLimits,
    brick_load_requests: []const c_uint,
};

const FrameSnapshot = struct {
    brick_limits: BrickLimits,
    brick_load_requests: ArrayListUnmanaged(c_uint),

    /// Initialize the frame snapshot by preallocating request buffers
    ///
    /// ``snapshot()`` must be called before reading
    pub fn init(allocator: Allocator, brick_limits: BrickLimits) Allocator.Error!FrameSnapshot {
        const zone = tracy.ZoneN(@src(), @typeName(FrameSnapshot) ++ " " ++ @src().fn_name);
        defer zone.End();

        var brick_load_requests = try ArrayListUnmanaged(c_uint).initCapacity(
            allocator,
            @intCast(brick_limits.max_load_request_count),
        );
        errdefer brick_load_requests.deinit(allocator);

        return FrameSnapshot{
            .brick_limits = brick_limits,
            .brick_load_requests = brick_load_requests,
        };
    }

    pub fn deinit(self: *FrameSnapshot, allocator: Allocator) void {
        self.brick_load_requests.deinit(allocator);
    }

    /// Grab snapshot from device memory, storing device state in this struct on host
    ///
    /// Caller should make sure to invalidate resources before calling snapshot
    pub fn snapshot(self: *FrameSnapshot, ray_device_resources: *const RayDeviceResources) void {
        const zone = tracy.ZoneN(@src(), @typeName(FrameSnapshot) ++ " " ++ @src().fn_name);
        defer zone.End();

        self.brick_load_requests.clearRetainingCapacity();

        // grab device request data and move it into the snapshot
        const base_addr = @intFromPtr(ray_device_resources.request_buffer.mapped);

        // read brick request limits
        {
            const brick_req_limits_buffer_info = ray_device_resources.getBufferInfo(Resource{ .host_and_device = .brick_req_limits_s });
            const brick_req_limits_adr = base_addr + brick_req_limits_buffer_info.offset;
            const brick_req_limtis_ptr: *const ray_pipeline_types.BrickLimits = @ptrFromInt(brick_req_limits_adr);
            self.brick_limits = brick_req_limtis_ptr.*;
        }
        // read brick load requests
        if (self.brick_limits.load_request_count > 0) {
            const buffer_info = ray_device_resources.getBufferInfo(Resource{ .host_and_device = .brick_load_request_s });
            const addr = base_addr + buffer_info.offset;
            const ptr: [*]const c_uint = @ptrFromInt(addr);
            const slice = ptr[0..self.brick_limits.load_request_count];
            self.brick_load_requests.appendSliceAssumeCapacity(slice);
        }
    }

    pub fn asDataSnapshot(self: FrameSnapshot) DataFrameSnapshot {
        return DataFrameSnapshot{
            .brick_limits = self.brick_limits,
            .brick_load_requests = self.brick_load_requests.items,
        };
    }
};
