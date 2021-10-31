const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const zlm = @import("zlm");
const UV = @import("util_types.zig").UV;

const DB = @This();

// global data
// TODO: dirty and transfer
len: usize,
sprite_pool_size: usize,
uv_buffer: ArrayList(zlm.Vec2),

// instance data
positions: ArrayList(zlm.Vec2),
scales: ArrayList(zlm.Vec2),
rotations: ArrayList(f32),
uv_indices: ArrayList(c_int),

pub fn initCapacity(allocator: *Allocator, capacity: usize) !DB {
    return DB{
        .len = 0,
        .sprite_pool_size = capacity,
        .uv_buffer  = try ArrayList(zlm.Vec2).initCapacity(allocator, 10 * 4 * 2), // TODO: allow configure
        .positions  = try ArrayList(zlm.Vec2).initCapacity(allocator, capacity),
        .scales     = try ArrayList(zlm.Vec2).initCapacity(allocator, capacity),
        .rotations  = try ArrayList(f32).initCapacity(allocator, capacity),
        .uv_indices = try ArrayList(c_int).initCapacity(allocator, capacity),
    };
}

/// get a new sprite id
pub fn getNewId(self: *DB) !usize {
    const newId = self.len;
    if (newId < self.sprite_pool_size) {
        self.sprite_pool_size += 1;
    }

    try self.positions.append(zlm.Vec2.zero);
    try self.scales.append(zlm.Vec2.zero);
    try self.rotations.append(0);
    try self.uv_indices.append(0);

    self.len += 1;
    return newId;
}

/// generate uv buffer based on 
pub inline fn generateUvBuffer(self: *DB, mega_uvs: []UV) !void {
    for (mega_uvs) |uv| {
        try self.uv_buffer.append(zlm.Vec2.new(uv.min.x, uv.max.y));
        try self.uv_buffer.append(uv.max);
        try self.uv_buffer.append(uv.min);
        try self.uv_buffer.append(zlm.Vec2.new(uv.max.x, uv.min.y));
    }
}

pub fn deinit(self: *DB) void {
    self.positions.deinit();
    self.scales.deinit();
    self.rotations.deinit();
    self.uv_indices.deinit();
    self.uv_buffer.deinit();
}
