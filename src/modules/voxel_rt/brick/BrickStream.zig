const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const vk = @import("vulkan");
const glfw = @import("mach-glfw");
const tracy = @import("ztracy");

const render = @import("../../render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;

const ray_pipeline_types = @import("../ray_pipeline_types.zig");
const BrickLimits = ray_pipeline_types.BrickLimits;

const RayDeviceResources = @import("../RayDeviceResources.zig");
const Resource = RayDeviceResources.Resource;

const BrickStream = @This();

allocator: Allocator,
frame_snapshot: FrameSnapshot,

pub fn init(allocator: Allocator, brick_limits: BrickLimits) Allocator.Error!BrickStream {
    const zone = tracy.ZoneN(@src(), @typeName(BrickStream) ++ " " ++ @src().fn_name);
    defer zone.End();

    return BrickStream{
        .allocator = allocator,
        .frame_snapshot = try FrameSnapshot.init(allocator, brick_limits),
    };
}

/// Fetch ray requests from the device and populate snapshot with this data
///
/// !This function will invalidate previously fetched snapshots!
pub fn takeSnapshot(self: *BrickStream, ctx: Context, ray_device_resources: *const RayDeviceResources) !DataFrameSnapshot {
    const zone = tracy.ZoneN(@src(), @typeName(BrickStream) ++ " " ++ @src().fn_name);
    defer zone.End();

    // sync brick request data on to the host
    try ray_device_resources.invalidateBrickRequestData(ctx);

    self.frame_snapshot.snapshot(ray_device_resources);

    return self.frame_snapshot.asDataSnapshot();
}

pub fn deinit(self: BrickStream) void {
    var mut_frame_snapshot = @constCast(&self.frame_snapshot);
    mut_frame_snapshot.deinit(self.allocator);
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
        const base_adr = @intFromPtr(ray_device_resources.request_buffer.mapped);

        // read brick request limits
        {
            const brick_req_limits_buffer_info = ray_device_resources.getBufferInfo(Resource{ .host_and_device = .brick_req_limits_s });
            const brick_req_limits_adr = base_adr + brick_req_limits_buffer_info.offset;
            const brick_req_limtis_ptr: *const ray_pipeline_types.BrickLimits = @ptrFromInt(brick_req_limits_adr);
            self.brick_limits = brick_req_limtis_ptr.*;
        }
        // read brick load requests
        if (self.brick_limits.load_request_count > 0) {
            const brick_load_buffer_info = ray_device_resources.getBufferInfo(Resource{ .host_and_device = .brick_load_request_s });
            const brick_load_adr = base_adr + brick_load_buffer_info.offset;
            const brick_load_ptr: [*]const c_uint = @ptrFromInt(brick_load_adr);
            const brick_load_slice = brick_load_ptr[0..self.brick_limits.load_request_count];
            self.brick_load_requests.appendSliceAssumeCapacity(brick_load_slice);
        }
    }

    pub fn asDataSnapshot(self: FrameSnapshot) DataFrameSnapshot {
        return DataFrameSnapshot{
            .brick_limits = self.brick_limits,
            .brick_load_requests = self.brick_load_requests.items,
        };
    }
};
