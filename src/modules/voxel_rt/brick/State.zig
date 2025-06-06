const std = @import("std");
const Mutex = std.Thread.Mutex;

pub const AtomicCount = std.atomic.Value(u32);
pub const brick_dimension: u32 = 4;
pub const brick_bits: u32 = brick_dimension * brick_dimension * brick_dimension;
pub const brick_bytes: u32 = brick_bits / 8;
pub const brick_words: u32 = brick_bytes / 4;
pub const brick_log2: u32 = std.math.log2_int(u32, brick_bits);
pub const BrickMap = std.meta.Int(.unsigned, State.brick_bits);
pub const BrickMapLog2 = std.meta.Int(.unsigned, State.brick_log2);

/// type used to record changes in host/device buffers in order to only send changed data to the gpu
pub const DeviceDataDelta = struct {
    pub const empty = DeviceDataDelta{
        .mutex = .{},
        .state = .inactive,
        .from = 0,
        .to = 0,
    };

    const DeltaState = enum {
        invalid,
        inactive,
        active,
    };

    mutex: Mutex,
    state: DeltaState,
    from: usize,
    to: usize,

    pub fn resetDelta(self: *DeviceDataDelta) void {
        self.state = .inactive;
        self.from = std.math.maxInt(usize);
        self.to = std.math.minInt(usize);
    }

    pub fn registerDelta(self: *DeviceDataDelta, delta_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.state = .active;
        self.from = @min(self.from, delta_index);
        self.to = @max(self.to, delta_index + 1);
    }

    /// register a delta range
    pub fn registerDeltaRange(self: *DeviceDataDelta, from: usize, to: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.state = .active;
        self.from = @min(self.from, from);
        self.to = @max(self.to, to + 1);
    }
};

// uniform binding: 2
pub const Device = extern struct {
    // how many voxels in each axis
    voxel_dim_x: u32,
    voxel_dim_y: u32,
    voxel_dim_z: u32,
    // how many bricks in each axis
    dim_x: u32,
    dim_y: u32,
    dim_z: u32,

    padding1: u32 = 0,
    padding2: u32 = 0,

    // holds the min point, and the base t advance
    // base t advance dictate the minimum stretch of distance a ray can go for each iteration
    // at 0.1 it will move atleast 10% of a given voxel
    min_point_base_t: [4]f32,
    // holds the max_point, and the brick scale
    max_point_scale: [4]f32,
};

// pub const Unloaded = packed struct {
//     lod_color: u24,
//     flags: u6,
// };

pub const BrickStatusMask = extern struct {
    pub const Status = enum(u2) {
        empty = 0,
        loaded = 1,
    };

    bits: c_uint,

    pub fn write(self: *BrickStatusMask, state: Status, at: u5) void {
        // zero out bits
        self.bits &= ~(@as(u32, 0b1) << at);
        const state_bit: u32 = @intCast(@intFromEnum(state));
        self.bits |= state_bit << at;
    }

    pub fn read(self: BrickStatusMask, at: u5) Status {
        var bits = self.bits;
        bits &= @as(u32, 0b1) << at;
        bits = bits >> at;
        return @enumFromInt(@as(u2, @intCast(bits)));
    }
};

pub const IndexToBrick = c_uint;

pub const Brick = struct {
    pub const IndexType = enum(u1) {
        voxel_start_index,
        brick_lod_index,
    };

    pub const StartIndex = packed struct(u32) {
        value: u31,
        type: IndexType,
    };

    const unset_bits: u32 = std.math.maxInt(u32);
    pub const unset_index: StartIndex = @bitCast(unset_bits);

    pub const empty: Occupancy = [_]u8{0} ** brick_bytes;
    pub const Occupancy = [brick_bytes]u8;
};

pub const MaterialIndices = u8;

const State = @This();

brick_statuses: []BrickStatusMask,
brick_statuses_delta: DeviceDataDelta = .empty,
brick_indices: []IndexToBrick,
brick_indices_delta: DeviceDataDelta = .empty,

// we keep a single bricks delta structure since active_bricks is shared
bricks_occupancy_delta: DeviceDataDelta = .empty,
brick_occupancy: []u8,

bricks_start_indices_delta: DeviceDataDelta = .empty,
brick_start_indices: []Brick.StartIndex,

material_indices_delta: DeviceDataDelta = .empty,
// assigned through a bucket
material_indices: []MaterialIndices,

/// how many bricks are used in the grid, keep in mind that this is used in a multithread context
active_bricks: AtomicCount,

device_state: Device,

// used to determine which worker is scheduled a job
work_segment_size: usize,
