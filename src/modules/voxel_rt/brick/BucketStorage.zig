const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const IndexMapContext = struct {
    pub fn hash(self: IndexMapContext, key: usize) u64 {
        _ = self;
        return @intCast(key);
    }
    pub fn eql(self: IndexMapContext, a: usize, b: usize) bool {
        _ = self;
        return a == b;
    }
};
const IndexMap = std.HashMap(usize, Index, IndexMapContext, 80);

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
        for (self.occupied.items, 0..) |elem, i| {
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

const bucket_count = 4;
// max bucket is always the size of brick which is 2^9 = 512
const min_2_pow_size = 9 - (bucket_count - 1);

pub const Index = packed struct {
    bucket_index: u6,
    element_index: u26,
};

allocator: Allocator,
// used to find the active bucked for a given brick index
index: IndexMap,
buckets: [bucket_count]Bucket,

/// init a bucket storage.
/// caller must make sure to call deinit
pub fn init(allocator: Allocator, start_index: u32, material_indices_len: usize, brick_count: usize) !BucketStorage {
    std.debug.assert(material_indices_len > 2048);
    const segments_2048 = std.math.divFloor(usize, material_indices_len, 2048) catch unreachable;

    var buckets: [bucket_count]Bucket = undefined;

    var cursor: u32 = start_index;
    { // init first bucket
        const inital_index = cursor;
        buckets[0] = Bucket{
            .free = try ArrayList(Bucket.Entry).initCapacity(allocator, 2 * segments_2048),
            .occupied = try ArrayList(?Bucket.Entry).initCapacity(allocator, segments_2048),
        };
        const bucket_size = try std.math.powi(u32, 2, min_2_pow_size);
        var j: usize = 0;
        while (j < segments_2048) : (j += 1) {
            buckets[0].free.appendAssumeCapacity(.{ .start_index = cursor });
            buckets[0].free.appendAssumeCapacity(.{ .start_index = cursor + bucket_size });
            cursor += 2048;
        }
        cursor = inital_index + bucket_size * 2;
    }
    {
        comptime var i: usize = 1;
        inline while (i < buckets.len - 1) : (i += 1) {
            const inital_index = cursor;
            buckets[i] = Bucket{
                .free = try ArrayList(Bucket.Entry).initCapacity(allocator, segments_2048),
                .occupied = try ArrayList(?Bucket.Entry).initCapacity(allocator, segments_2048 / 2),
            };
            const bucket_size = try std.math.powi(u32, 2, min_2_pow_size + i);
            var j: usize = 0;
            while (j < segments_2048) : (j += 1) {
                buckets[i].free.appendAssumeCapacity(.{ .start_index = cursor });
                cursor += 2048;
            }
            cursor = inital_index + bucket_size;
        }

        buckets[buckets.len - 1] = Bucket{
            .free = try ArrayList(Bucket.Entry).initCapacity(allocator, segments_2048 * 3),
            .occupied = try ArrayList(?Bucket.Entry).initCapacity(allocator, segments_2048),
        };
        const bucket_size = 512;
        var j: usize = 0;
        while (j < segments_2048) : (j += 1) {
            buckets[buckets.len - 1].free.appendAssumeCapacity(.{ .start_index = cursor });
            buckets[buckets.len - 1].free.appendAssumeCapacity(.{ .start_index = cursor + bucket_size });
            buckets[buckets.len - 1].free.appendAssumeCapacity(.{ .start_index = cursor + bucket_size * 2 });
            cursor += 2048;
        }
    }

    var index = IndexMap.init(allocator);
    errdefer index.deinit();
    try index.ensureUnusedCapacity(@intCast(brick_count));

    return BucketStorage{
        .allocator = allocator,
        .index = index,
        .buckets = buckets,
    };
}

// return brick's bucket
// function handles assigning new buckets as needed and will transfer material indices to new slot in the event
// that a new bucket is required
// returns error if there is no more buckets of appropriate size
pub fn getBrickBucket(self: *BucketStorage, brick_index: usize, voxel_count: usize, material_indices: []u8) !Bucket.Entry {
    // check if brick already have assigned a bucket
    if (self.index.get(brick_index)) |index| {
        const bucket_size = try std.math.powi(usize, 2, min_2_pow_size + index.bucket_index);
        // if bucket size is sufficent, or if voxel was set before, no change required
        if (bucket_size > voxel_count) {
            return self.buckets[index.bucket_index].occupied.items[index.element_index].?;
        }

        // free previous bucket
        const previous_bucket = self.buckets[index.bucket_index].occupied.items[index.element_index].?;
        try self.buckets[index.bucket_index].free.append(previous_bucket);
        self.buckets[index.bucket_index].occupied.items[index.element_index] = null;

        // find a bucket with increased size that is free
        var i: usize = index.bucket_index + 1;
        while (i < self.buckets.len) : (i += 1) {
            if (self.buckets[i].free.pop()) |bucket| {
                // do bucket stuff to rel
                const oc_index = try self.buckets[i].appendOccupied(bucket);

                try self.index.put(brick_index, Index{
                    .bucket_index = @intCast(i),
                    .element_index = @intCast(oc_index),
                });

                // copy material indices to new bucket
                @memcpy(
                    material_indices[bucket.start_index .. bucket.start_index + bucket_size],
                    material_indices[previous_bucket.start_index .. previous_bucket.start_index + bucket_size],
                );
                return bucket;
            }
        }
    } else {
        // fetch the smallest free bucket
        for (&self.buckets, 0..) |*bucket, i| {
            if (bucket.free.pop()) |take| {
                const oc_index = try bucket.appendOccupied(take);

                try self.index.put(brick_index, Index{
                    .bucket_index = @intCast(i),
                    .element_index = @intCast(oc_index),
                });

                return take;
            }
        }
    }
    return BucketRequestError.NoSuitableBucket; // no free bucket big enough to store brick color data
}

pub inline fn deinit(self: *BucketStorage) void {
    self.index.deinit();
    for (self.buckets) |bucket| {
        bucket.free.deinit();
        bucket.occupied.deinit();
    }
}
