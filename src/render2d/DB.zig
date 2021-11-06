const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const render = @import("../render/render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;

const zlm = @import("zlm");
const UV = @import("util_types.zig").UV;

const DB = @This();

pub const Index = usize;

// global data
len: usize,
sprite_pool_size: usize,
uv_buffer: StorageType(zlm.Vec2),

sprite_index: ArrayList(Index),

// instance data
positions: StorageType(zlm.Vec2),
scales: StorageType(zlm.Vec2),
rotations: StorageType(f32),
uv_indices: StorageType(c_int),

pub fn initCapacity(allocator: *Allocator, capacity: usize) !DB {
    return DB{
        .len = 0,
        .sprite_pool_size = capacity,
        .uv_buffer      = try StorageType(zlm.Vec2).initCapacity(allocator, 10 * 4 * 2), // TODO: allow configure
        .sprite_index   = try ArrayList(Index).initCapacity(allocator, capacity),
        .positions      = try StorageType(zlm.Vec2).initCapacity(allocator, capacity),
        .scales         = try StorageType(zlm.Vec2).initCapacity(allocator, capacity),
        .rotations      = try StorageType(f32).initCapacity(allocator, capacity),
        .uv_indices     = try StorageType(c_int).initCapacity(allocator, capacity),
    };
}

/// get a new sprite id
pub fn getNewId(self: *DB) !usize {
    const newId = self.len;
    
    if (newId < self.sprite_pool_size) {
        self.sprite_pool_size += 1;
    }

    try self.sprite_index.append(newId);
    try self.positions.append(zlm.Vec2.zero);
    try self.scales.append(zlm.Vec2.zero);
    try self.rotations.append(0);
    try self.uv_indices.append(0);

    self.len += 1;
    return newId;
}

pub inline fn getIndex(self: *DB, sprite_id: usize) Index {
    return self.sprite_index.items[sprite_id];
}

pub fn flush(self: *DB) !void {
    try self.positions.signalChangesPushed();
    try self.scales.signalChangesPushed();
    try self.rotations.signalChangesPushed();
    try self.uv_indices.signalChangesPushed();
}

/// generate uv buffer based on 
pub inline fn generateUvBuffer(self: *DB, mega_uvs: []UV) !void {
    self.uv_buffer.delta.from = 0;
    for (mega_uvs) |uv| {
        try self.uv_buffer.append(zlm.Vec2.new(uv.min.x, uv.max.y));
        try self.uv_buffer.append(uv.max);
        try self.uv_buffer.append(uv.min);
        try self.uv_buffer.append(zlm.Vec2.new(uv.max.x, uv.min.y));
    }
    self.uv_buffer.delta.to = self.uv_buffer.storage.items.len - 1;
    self.uv_buffer.delta.has_changes = true;
}

pub fn deinit(self: *DB) void {
    self.sprite_index.deinit();
    self.positions.deinit();
    self.scales.deinit();
    self.rotations.deinit();
    self.uv_indices.deinit();
    self.uv_buffer.deinit();
}

const DeltaRange = struct {
    has_changes: bool,
    from: usize,
    to: usize,
};

fn StorageType(comptime T: type) type {
    return struct {
        // const StoredType = T;
        const Self = @This();

        storage: ArrayList(T),
        delta: DeltaRange,

        pub inline fn initCapacity(allocator: *Allocator, capacity: usize) !Self {
            return Self {
                .storage = try ArrayList(T).initCapacity(allocator, capacity),
                .delta = .{ .has_changes = false, .from = 0, .to = 0 },
            };
        }

        pub inline fn append(self: *Self, item: T) !void {
            try self.storage.append(item);
        }

        pub inline fn updateAt(self: *Self, at: Index, new_value: T) !void {
            // update value
            self.storage.items[at] = new_value;

            self.delta.from = if (at < self.delta.from) at else self.delta.from;
            self.delta.to = if (at > self.delta.to) at else self.delta.to;
            self.delta.has_changes = true;
        }

        pub inline fn signalChangesPushed(self: *Self) !void {
            self.delta.from = 0;
            self.delta.to   = 0;
            self.delta.has_changes = false;
        }

        pub inline fn deinit(self: Self) void {
            self.storage.deinit();
        }

        pub inline fn handleDeviceTransfer(self: *Self, ctx: Context, buffer: *GpuBufferMemory) !void {
            if (self.delta.has_changes == false) return;

            var offset = [1]usize{ self.delta.from };
            var slice = [1][]const T{ self.storage.items[self.delta.from..self.delta.to + 1] };
            try buffer.batchTransfer(ctx, T, offset[0..], slice[0..]);
        }

        fn sortMethod(context: void, lhs: DeltaRange, rhs: DeltaRange) bool  {
            _ = context;
            return lhs.to < rhs.to;
        }
    };
}
