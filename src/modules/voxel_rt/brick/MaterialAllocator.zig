const std = @import("std");
const Allocator = std.mem.Allocator;
const brick_bits = @import("State.zig").brick_bits;

pub const Entry = u32;

pub const Cursor = std.atomic.Value(Entry);

const IndexMap = std.AutoArrayHashMapUnmanaged(
    usize,
    usize,
);

const MaterialAllocator = @This();

capacity: usize,
next_index: Cursor = .init(0),

// TODO: implement releaseEntry, this array must be behind a mutex, an Atomic may be used to probe if there are any entries in the array
// released_entries: std.ArrayListUnmanaged(Entry) = .empty,

pub fn init(capacity: usize) MaterialAllocator {
    return MaterialAllocator{
        .capacity = capacity,
    };
}

pub fn deinit(self: *MaterialAllocator, allocator: Allocator) void {
    _ = self;
    _ = allocator;
    // self.released_entries.deinit(allocator);
}

pub fn nextEntry(self: *MaterialAllocator) Entry {
    // if (self.released_entries.pop()) |free| {
    //     return free;
    // }

    const next_entry = self.next_index.fetchAdd(brick_bits / 4, .monotonic);
    std.debug.assert(next_entry < self.capacity); // no more material data, should not occur

    return next_entry;
}

// pub fn releaseEntry(self: *MaterialAllocator, allocator: Allocator, entry: Entry) error{OutOfMemory}!void {
//     self.released_entries.append(allocator, entry);
// }
