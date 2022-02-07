const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

/// used by the brick grid to pack brick material data closer to eachother
pub const Bucket = struct {
    pub const Entry = packed struct {
        start_index: u32,
    };
    free: ArrayList(Entry),
    occupied: ArrayList(?Entry),

    /// check for any existing null elements to replace before doing a normal append
    /// returns index of item
    pub inline fn appendOccupied(self: *Bucket, item: Entry) !usize {
        // replace first null element with item
        for (self.occupied.items) |elem, i| {
            if (elem == null) {
                self.occupied.items[i] = item;
                return i;
            }
        }
        // append to list if no null item in list
        try self.occupied.append(item);
        return self.occupied.items.len - 1;
    }
};

pub const BucketRequestError = error{
    NoSuitableBucket,
};

const BucketStorage = @This();

// the smallest bucket size in 2^n
const bucket_count = 6;
// max bucket is always the size of brick which is 2^9
const min_2_pow_size = 9 - (bucket_count - 1);

pub const Index = packed struct {
    bucket_index: u16,
    element_index: u16,
};

allocator: Allocator,
// used to find the active bucked for a given brick index
index: []?Index,
buckets: [bucket_count]Bucket,
bucket_mutexes: [bucket_count]std.Thread.Mutex,

// TODO: allow configuring the distribution of buckets
/// init a bucket storage.
/// caller must make sure to call deinit
/// segments_2048 defined how many 2048 segments should be stored.
/// one segment will be split into: 2 * 256, 1 * 512
pub inline fn init(allocator: Allocator, brick_count: usize, segments_2048: usize) !BucketStorage {
    std.debug.assert(segments_2048 > 0);

    var bucket_mutexes: [bucket_count]std.Thread.Mutex = undefined;
    std.mem.set(std.Thread.Mutex, bucket_mutexes[0..], .{});

    var buckets: [bucket_count]Bucket = undefined;

    var prev_indices: u32 = 0;
    { // init first bucket
        // zig fmt: off
        buckets[0] = Bucket{ 
            .free = try ArrayList(Bucket.Entry).initCapacity(allocator, 2 * segments_2048), 
            .occupied = try ArrayList(?Bucket.Entry).initCapacity(allocator, segments_2048) 
        };
        // zig fmt: on
        const bucket_size = try std.math.powi(u32, 2, min_2_pow_size);
        var j: usize = 0;
        while (j < 2 * segments_2048) : (j += 1) {
            buckets[0].free.appendAssumeCapacity(.{ .start_index = prev_indices });
            prev_indices += bucket_size;
        }
    }
    {
        comptime var i: usize = 1;
        inline while (i < buckets.len - 1) : (i += 1) {
            // zig fmt: off
            buckets[i] = Bucket{ 
                .free = try ArrayList(Bucket.Entry).initCapacity(allocator, segments_2048), 
                .occupied = try ArrayList(?Bucket.Entry).initCapacity(allocator, segments_2048 / 2) 
            };
            // zig fmt: on
            const bucket_size = try std.math.powi(u32, 2, min_2_pow_size + i);
            var j: usize = 0;
            while (j < segments_2048) : (j += 1) {
                buckets[i].free.appendAssumeCapacity(.{ .start_index = prev_indices });
                prev_indices += bucket_size;
            }
        }
        // zig fmt: off
        buckets[buckets.len-1] = Bucket{ 
            .free = try ArrayList(Bucket.Entry).initCapacity(allocator, segments_2048 * 3), 
            .occupied = try ArrayList(?Bucket.Entry).initCapacity(allocator, segments_2048) 
        };
        // zig fmt: on
        const bucket_size = 512;
        var j: usize = 0;
        while (j < segments_2048 * 3) : (j += 1) {
            buckets[buckets.len - 1].free.appendAssumeCapacity(.{ .start_index = prev_indices });
            prev_indices += bucket_size;
        }
    }

    const index = try allocator.alloc(?Index, brick_count);
    errdefer allocator.free(index);
    std.mem.set(?Index, index, null);

    return BucketStorage{
        .allocator = allocator,
        .index = index,
        .buckets = buckets,
        .bucket_mutexes = bucket_mutexes,
    };
}

// return brick's bucket
// function handles assigning new buckets as needed and will transfer material indices to new slot in the event
// that a new bucket is required
// returns error if there is no more buckets of appropriate size
pub inline fn getBrickBucket(self: *BucketStorage, brick_index: usize, voxel_offset: usize, material_indices: []u8, was_set: bool) !Bucket.Entry {
    // check if brick already have assigned a bucket
    if (self.index[brick_index]) |index| {
        const bucket_size = try std.math.powi(usize, 2, min_2_pow_size + index.bucket_index);
        // if bucket size is sufficent, or if voxel was set before, no change required
        if (bucket_size > voxel_offset or was_set) {
            return self.buckets[index.bucket_index].occupied.items[index.element_index].?;
        }

        // free previous bucket
        self.bucket_mutexes[index.bucket_index].lock();
        const previous_bucket = self.buckets[index.bucket_index].occupied.items[index.element_index].?;
        try self.buckets[index.bucket_index].free.append(previous_bucket);
        self.buckets[index.bucket_index].occupied.items[index.element_index] = null;
        self.bucket_mutexes[index.bucket_index].unlock();

        // find a bucket with increased size that is free
        var i: usize = index.bucket_index + 1;
        while (i < self.buckets.len) : (i += 1) {
            self.bucket_mutexes[i].lock();
            if (self.buckets[i].free.items.len > 0) {
                // do bucket stuff to rel
                const bucket = self.buckets[i].free.pop();
                const oc_index = try self.buckets[i].appendOccupied(bucket);
                self.bucket_mutexes[i].unlock();

                self.index[brick_index] = Index{ .bucket_index = @intCast(u16, i), .element_index = @intCast(u16, oc_index) };

                // copy material indices to new bucket
                std.mem.copy(u8, material_indices[bucket.start_index..], material_indices[previous_bucket.start_index .. previous_bucket.start_index + bucket_size]);
                return bucket;
            }
            self.bucket_mutexes[i].unlock();
        }
    } else {
        // fetch the smallest free bucket
        for (self.buckets) |*bucket, i| {
            self.bucket_mutexes[i].lock();

            if (bucket.free.items.len > 0) {
                const take = bucket.free.pop();
                const oc_index = try bucket.appendOccupied(take);
                self.bucket_mutexes[i].unlock();

                self.index[brick_index] = Index{ .bucket_index = @intCast(u16, i), .element_index = @intCast(u16, oc_index) };
                return take;
            }
            self.bucket_mutexes[i].unlock();
        }
    }
    std.debug.assert(was_set == false);
    return BucketRequestError.NoSuitableBucket; // no free bucket big enough to store brick color data
}

pub inline fn deinit(self: BucketStorage) void {
    self.allocator.free(self.index);
    for (self.buckets) |bucket| {
        bucket.free.deinit();
        bucket.occupied.deinit();
    }
}
