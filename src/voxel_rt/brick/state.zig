const std = @import("std");
const Mutex = std.Thread.Mutex;

const ecez = @import("ecez");

pub const AtomicCount = std.atomic.Value(u32);

pub const chunk_dimension: u32 = 32; // chunk_dimension^3 bricks
pub const brick_count = validateAndCalculateVolume(chunk_dimension, "can not have 0 bricks in chunk!");

pub const brick_dimension: u32 = 4; // brick_dimension^3 voxels per brick
pub const brick_bits: u32 = validateAndCalculateVolume(brick_dimension, "cant have 0 voxels in brick!");
pub const brick_bytes: u32 = brick_bits / 8;
pub const brick_words: u32 = brick_bytes / 4;
pub const brick_log2: u32 = std.math.log2_int(u32, brick_bits);
pub const BrickMap = std.meta.Int(.unsigned, brick_bits);
pub const BrickMapLog2 = std.meta.Int(.unsigned, brick_log2);

/// type used to record changes in host/device buffers in order to only send changed data to the gpu
pub const DeviceDataDelta = struct {
    pub const empty = DeviceDataDelta{
        .state = .inactive,
        .from = 0,
        .to = 0,
    };

    const DeltaState = enum {
        invalid,
        inactive,
        active,
    };

    state: DeltaState,
    from: usize,
    to: usize,

    pub fn resetDelta(self: *DeviceDataDelta) void {
        self.state = .inactive;
        self.from = std.math.maxInt(usize);
        self.to = std.math.minInt(usize);
    }

    pub fn registerDelta(self: *DeviceDataDelta, delta_index: usize) void {
        self.state = .active;
        self.from = @min(self.from, delta_index);
        self.to = @max(self.to, delta_index + 1);
    }

    /// register a delta range
    pub fn registerDeltaRange(self: *DeviceDataDelta, from: usize, to: usize) void {
        self.state = .active;
        self.from = @min(self.from, from);
        self.to = @max(self.to, to + 1);
    }
};

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

pub const components = struct {
    pub const ActiveBricks = struct {
        pub const empty = ActiveBricks{
            .count = .init(0),
        };

        count: AtomicCount,
    };

    pub const Statuses = struct {
        pub const brick_status_count = std.math.divCeil(u32, brick_count, 32) catch @compileError("unreachable");

        pub const empty = Statuses{
            .statuses = [_]BrickStatusMask{.{ .bits = 0 }} ** brick_status_count,
        };

        statuses: [brick_status_count]BrickStatusMask,
    };
    pub const StatusDelta = struct {
        pub const empty = StatusDelta{
            .delta = .empty,
        };

        delta: DeviceDataDelta,
    };

    pub const Indices = struct {
        pub const empty = Indices{
            .indices = [_]IndexToBrick{0} ** brick_count,
        };

        indices: [brick_count]IndexToBrick,
    };
    pub const IndicesDelta = struct {
        pub const empty = IndicesDelta{
            .delta = .empty,
        };

        delta: DeviceDataDelta,
    };

    pub const Occupancy = struct {
        pub const occupancy_count = brick_count * brick_bytes;
        pub const OccupancyByte = u8;

        pub const empty = Occupancy{
            .occupancy = [_]OccupancyByte{0} ** occupancy_count,
        };

        occupancy: [occupancy_count]OccupancyByte,
    };
    pub const OccupancyDelta = struct {
        pub const empty = OccupancyDelta{
            .delta = .empty,
        };

        delta: DeviceDataDelta,
    };

    // TODO: rename all references to "brick start index" to brick_material_index to make the distinction between brick index and brick start index ...
    pub const StartIndices = struct {
        pub const empty = StartIndices{
            .indices = [_]Brick.StartIndex{Brick.unset_index} ** brick_count,
        };

        indices: [brick_count]Brick.StartIndex,
    };
    pub const StartIndicesDelta = struct {
        pub const empty = StartIndicesDelta{
            .delta = .empty,
        };

        delta: DeviceDataDelta,
    };

    pub const MaterialIndices = struct {
        pub const IndexType = u8;
        pub const material_index_count = brick_count * brick_bits;

        pub const empty = MaterialIndices{
            .indices = [_]IndexType{0} ** material_index_count,
        };

        indices: [material_index_count]IndexType,
    };
    pub const MaterialIndicesDelta = struct {
        pub const empty = MaterialIndicesDelta{
            .delta = .empty,
        };

        delta: DeviceDataDelta,
    };

    pub const MaterialAllocator = @import("MaterialAllocator.zig");

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

        pub const Config = struct {
            base_t: f32 = 0.01,
            min_point: [3]f32 = [_]f32{ 0.0, 0.0, 0.0 },
            scale: f32 = 1.0,
        };
        pub fn init(config: Config) Device {
            const min_point_base_t = blk: {
                const min_point = config.min_point;
                const base_t = config.base_t;
                var result: [4]f32 = undefined;
                @memcpy(result[0..3], &min_point);
                result[3] = base_t;
                break :blk result;
            };

            const max_point_scale = [4]f32{
                min_point_base_t[0] + @as(f32, @floatFromInt(chunk_dimension)) * config.scale,
                min_point_base_t[1] + @as(f32, @floatFromInt(chunk_dimension)) * config.scale,
                min_point_base_t[2] + @as(f32, @floatFromInt(chunk_dimension)) * config.scale,
                config.scale,
            };

            return Device{
                .voxel_dim_x = chunk_dimension * brick_dimension,
                .voxel_dim_y = chunk_dimension * brick_dimension,
                .voxel_dim_z = chunk_dimension * brick_dimension,
                .dim_x = chunk_dimension,
                .dim_y = chunk_dimension,
                .dim_z = chunk_dimension,
                .min_point_base_t = min_point_base_t,
                .max_point_scale = max_point_scale,
            };
        }
    };
};

pub const queries = struct {
    pub const upload = struct {
        pub const Status = ecez.QueryAny(struct {
            statuses: *const components.Statuses,
            delta: *components.StatusDelta,
        }, .{}, .{});

        pub const Indices = ecez.QueryAny(struct {
            indices: *const components.Indices,
            delta: *components.IndicesDelta,
        }, .{}, .{});

        pub const Occupancy = ecez.QueryAny(struct {
            occupancy: *const components.Occupancy,
            delta: *components.OccupancyDelta,
        }, .{}, .{});

        pub const StartIndices = ecez.QueryAny(struct {
            indices: *const components.StartIndices,
            delta: *components.StartIndicesDelta,
        }, .{}, .{});

        pub const MaterialIndices = ecez.QueryAny(struct {
            indices: *const components.MaterialIndices,
            delta: *components.MaterialIndicesDelta,
        }, .{}, .{});
    };

    pub const WriteActiveBricks = ecez.QueryAny(struct {
        active: *components.ActiveBricks,
    }, .{}, .{});

    pub const WriteStatus = ecez.QueryAny(struct {
        statuses: *components.Statuses,
        delta: *components.StatusDelta,
    }, .{}, .{});

    pub const WriteIndices = ecez.QueryAny(struct {
        indices: *components.Indices,
        delta: *components.IndicesDelta,
    }, .{}, .{});

    pub const WriteOccupancy = ecez.QueryAny(struct {
        occupancy: *components.Occupancy,
        delta: *components.OccupancyDelta,
    }, .{}, .{});

    pub const WriteStartIndices = ecez.QueryAny(struct {
        indices: *components.StartIndices,
        delta: *components.StartIndicesDelta,
    }, .{}, .{});

    pub const WriteMaterialIndices = ecez.QueryAny(struct {
        allocator: *components.MaterialAllocator,
        indices: *components.MaterialIndices,
        delta: *components.MaterialIndicesDelta,
    }, .{}, .{});

    pub const Device = ecez.QueryAny(struct {
        device: components.Device,
    }, .{}, .{});
};

fn validateAndCalculateVolume(comptime dimension: u32, comptime error_msg: []const u8) u32 {
    if (dimension * dimension * dimension == 0) {
        @compileError(error_msg);
    }

    return dimension * dimension * dimension;
}
