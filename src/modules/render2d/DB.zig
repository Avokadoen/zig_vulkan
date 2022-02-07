const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const render = @import("../render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;

const za = @import("zalgebra");
const Vec2 = @Vector(2, f32);

const util_types = @import("util_types.zig");
const UV = util_types.UV;
const TextureHandle = util_types.TextureHandle;

const DB = @This();

pub const Index = usize;

pub const Id = struct {
    value: usize,
    verify: usize,
};

pub const Layer = struct {
    id: usize,
    begin_index: usize,
    len: usize,
};

const ShiftRange = struct {
    from: usize,
    to: usize,
};

const ShiftEnum = enum {
    left,
    right,
};

const ShiftEvent = union(ShiftEnum) {
    left: ShiftRange,
    right: ShiftRange,
};

// global data
len: usize,
sprite_pool_size: usize,
uv_buffer: StorageType(Vec2),
uv_meta: ArrayList(TextureHandle),

// used to lookup index of sprite in array's using ID
layer_data: ArrayList(Layer),
// TODO: there should be a safe way of clearing the list to prevent it from becoming too big
// changes in storage, used to update created sprite_id handles
shift_events: ArrayList(ShiftEvent),

// instance data
positions: StorageType(Vec2),
scales: StorageType(Vec2),
rotations: StorageType(f32),
uv_indices: StorageType(c_int),

pub fn initCapacity(allocator: Allocator, capacity: usize) !DB {
    var layers = ArrayList(Layer).init(allocator);
    try layers.append(.{
        .id = 0,
        .len = 0,
        .begin_index = 0,
    });
    return DB{
        .len = 0,
        .sprite_pool_size = capacity,
        .uv_buffer = try StorageType(Vec2).initCapacity(allocator, 10 * 4 * 2), // TODO: allow configure
        .uv_meta = try ArrayList(TextureHandle).initCapacity(allocator, capacity),
        .layer_data = layers,
        .shift_events = ArrayList(ShiftEvent).init(allocator),
        .positions = try StorageType(Vec2).initCapacity(allocator, capacity),
        .scales = try StorageType(Vec2).initCapacity(allocator, capacity),
        .rotations = try StorageType(f32).initCapacity(allocator, capacity),
        .uv_indices = try StorageType(c_int).initCapacity(allocator, capacity),
    };
}

/// get a new sprite id
pub fn getNewId(self: *DB) !Id {
    const newId = Id{
        .value = self.len,
        .verify = self.shift_events.items.len,
    };

    if (newId.value >= self.sprite_pool_size) {
        self.sprite_pool_size += 1;
    }

    try self.positions.append(za.Vec2.zero());
    try self.scales.append(za.Vec2.zero());
    try self.rotations.append(0);
    try self.uv_indices.append(0);

    self.len += 1;
    return newId;
}

// TODO: it's silly that layer state is handeled outside of DB, move logic for this into DB?
/// Change the layer of a sprite
pub inline fn applyLayer(self: *DB, sprite_id: *Id, current_layer: usize, new_layer: usize) !void {
    // TODO: count down length of previous layer of sprite
    for (self.layer_data.items) |*item, i| {
        // if we have not found the slot to add the layer to
        if (new_layer > item.id and i != self.layer_data.items.len - 1) {
            continue;
        }

        const work_layer = blk: {
            if (new_layer == item.id) {
                // assumption: you don't call this function on a sprite that is already in target layer
                item.len += 1;
                break :blk item;
            }

            if (i == self.layer_data.items.len - 1) {
                try self.layer_data.append(.{
                    .id = new_layer,
                    .begin_index = self.len,
                    .len = 1,
                });
                break :blk &self.layer_data.items[self.layer_data.items.len - 1];
            } else {
                const begin_index = blk2: {
                    if (i > 0) {
                        const prev_layer = self.layer_data.items[i - 1];
                        break :blk2 prev_layer.begin_index + prev_layer.len;
                    } else {
                        break :blk2 0;
                    }
                };
                try self.layer_data.insert(i, .{
                    .id = new_layer,
                    .begin_index = begin_index,
                    .len = 1,
                });
                break :blk &self.layer_data.items[i];
            }
        };

        const index = self.getIndex(sprite_id);
        const neg_delta = index < work_layer.begin_index;

        var abs_delta: usize = undefined;
        var from: usize = undefined;
        var to: usize = undefined;
        if (neg_delta == true) {
            // update layers between index and new layer begin.index
            for (self.layer_data.items[1..]) |*item2| {
                if (item2.begin_index >= index and item2.begin_index <= work_layer.begin_index) {
                    item2.begin_index -= 1;
                } else {
                    break;
                }
            }

            abs_delta = work_layer.begin_index - index;
            from = index;
            to = index + abs_delta + 1;
            try self.shift_events.append(ShiftEvent{ .left = .{ .from = from, .to = to } });
        } else {
            // update layers between index and new layer begin.index
            for (self.layer_data.items[1..]) |*item2| {
                if (item2.begin_index >= work_layer.begin_index and item2.begin_index <= index) {
                    item2.begin_index += 1;
                }
            }

            abs_delta = index - work_layer.begin_index;
            from = index - abs_delta;
            to = index;
            try self.shift_events.append(ShiftEvent{ .right = .{ .from = from, .to = to } });
        }

        const postion = self.positions.storage.orderedRemove(index);
        const scale = self.scales.storage.orderedRemove(index);
        const rotation = self.rotations.storage.orderedRemove(index);
        const uv_indice = self.uv_indices.storage.orderedRemove(index);
        try self.positions.storage.insert(work_layer.begin_index, postion);
        try self.scales.storage.insert(work_layer.begin_index, scale);
        try self.rotations.storage.insert(work_layer.begin_index, rotation);
        try self.uv_indices.storage.insert(work_layer.begin_index, uv_indice);

        sprite_id.value = work_layer.begin_index;
        sprite_id.verify += 1;

        break;
    }

    // update the length of the previous layer
    for (self.layer_data.items) |*layer, i| {
        if (layer.id == current_layer) {
            layer.len -= 1;
            if (layer.len == 0) {
                _ = self.layer_data.orderedRemove(i);
            }
            break;
        }
    }
}

pub fn getIndex(self: *DB, sprite_id: *Id) Index {
    // if sprite id is no longer valid, update id
    if (sprite_id.verify != self.shift_events.items.len) {
        var i: usize = sprite_id.verify;
        while (i < self.shift_events.items.len) : (i += 1) {
            switch (self.shift_events.items[i]) {
                .left => |event| {
                    if (sprite_id.value >= event.from and sprite_id.value <= event.to) {
                        sprite_id.value -= 1;
                    }
                },
                .right => |event| {
                    if (sprite_id.value >= event.from and sprite_id.value <= event.to) {
                        sprite_id.value += 1;
                    }
                },
            }
        }
        sprite_id.verify = self.shift_events.items.len;
    }

    return @as(Index, sprite_id.value);
}

pub fn flush(self: *DB) void {
    self.positions.signalChangesPushed();
    self.scales.signalChangesPushed();
    self.rotations.signalChangesPushed();
    self.uv_indices.signalChangesPushed();
}

/// generate uv buffer based on 
pub inline fn generateUvBuffer(self: *DB, mega_uvs: []UV) !void {
    self.uv_buffer.delta.from = 0;
    for (mega_uvs) |uv| {
        try self.uv_buffer.append(za.Vec2.new(uv.min[0], uv.max[1]));
        try self.uv_buffer.append(uv.max);
        try self.uv_buffer.append(uv.min);
        try self.uv_buffer.append(za.Vec2.new(uv.max[0], uv.min[1]));
    }
    self.uv_buffer.delta.to = self.uv_buffer.storage.items.len - 1;
    self.uv_buffer.delta.has_changes = true;
}

pub fn deinit(self: DB) void {
    self.shift_events.deinit();
    self.layer_data.deinit();
    self.positions.deinit();
    self.scales.deinit();
    self.rotations.deinit();
    self.uv_indices.deinit();
    self.uv_buffer.deinit();
    self.uv_meta.deinit();
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

        pub inline fn initCapacity(allocator: Allocator, capacity: usize) !Self {
            return Self{
                .storage = try ArrayList(T).initCapacity(allocator, capacity),
                .delta = .{ .has_changes = false, .from = 0, .to = 0 },
            };
        }

        pub inline fn append(self: *Self, item: T) !void {
            try self.storage.append(item);
        }

        pub inline fn updateAt(self: *Self, at: Index, new_value: T) void {
            // update value
            self.storage.items[at] = new_value;

            self.delta.from = if (at < self.delta.from) at else self.delta.from;
            self.delta.to = if (at > self.delta.to) at else self.delta.to;
            self.delta.has_changes = true;
        }

        pub inline fn signalChangesPushed(self: *Self) void {
            self.delta.from = 0;
            self.delta.to = 0;
            self.delta.has_changes = false;
        }

        pub inline fn deinit(self: Self) void {
            self.storage.deinit();
        }

        pub fn handleDeviceTransfer(self: *Self, ctx: Context, buffer: *GpuBufferMemory) !void {
            if (self.delta.has_changes == false) return;

            var offset = [1]usize{self.delta.from};
            var slice = [1][]const T{self.storage.items[self.delta.from .. self.delta.to + 1]};
            try buffer.batchTransfer(ctx, T, offset[0..], slice[0..]);
        }

        fn sortMethod(context: void, lhs: DeltaRange, rhs: DeltaRange) bool {
            _ = context;
            return lhs.to < rhs.to;
        }
    };
}
