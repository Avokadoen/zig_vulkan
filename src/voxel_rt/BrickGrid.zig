// This file contains an implementaion of "Real-time Ray tracing and Editing of Large Voxel Scenes"
// source: https://dspace.library.uu.nl/handle/1874/315917

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Material = @import("gpu_types.zig").Material;

// pub const Unloaded = packed struct {
//     lod_color: u24,
//     flags: u6,
// };

// TODO: move types?
// buffer binding: 7
pub const GridEntry = packed struct {
    pub const Type = enum(u2) {
        empty = 0,
        loaded,
        unloaded,
    };
    @"type": Type,
    data: u30,
};

const unset_material = std.math.maxInt(u24);

// buffer binding: 8
pub const Brick = packed struct {
    /// maps to a voxel grid of 8x8x8
    solid_mask: i512,
    // index for index
    material_index: u24,
    lod_material_index: u8,
};

// uniform binding: 2
pub const Device = extern struct {
    dim_x: u32,
    dim_y: u32,
    dim_z: u32,
    max_ray_iteration: u32,
    // holds the min point, and the base t advance
    // base t advance dictate the minimum stretch of distance a ray can go for each iteration
    // at 0.1 it will move atleast 10% of a given voxel
    min_point_base_t: [4]f32,
    // holds the max_point, and the brick scale
    max_point_scale: [4]f32,
};

pub const Config = struct {
    // Default value is enough to define half of all bricks
    brick_alloc: ?usize = null,
    // Default is enough to iter paralell the longest axis
    max_ray_iteration: ?u32 = null,

    base_t: f32 = 0.01,
    min_point: [3]f32 = [_]f32{ 0.0, 0.0, 0.0 },
    scale: f32 = 1.0,
    material_indices_per_brick: usize = 192,
};

const BrickGrid = @This();

allocator: Allocator,

grid: []GridEntry,
bricks: []Brick,

// TODO: ability to configure a size less then all voxels in the grid
bucket_storage: BucketStorage,
// assigned through a bucket
material_indices: []u8,

active_bricks: usize,
voxel_dim: [3]u32,
device_state: Device,

/// Initialize a BrickGrid that can be raytraced 
/// @param:
///     - allocator: used to allocate bricks and the grid, also to clean up these in deinit
///     - dim_x:     how many bricks *maps* (or chunks) in x dimension
///     - dim_y:     how many bricks *maps* (or chunks) in y dimension
///     - dim_z:     how many bricks *maps* (or chunks) in z dimension
///     - config:    config options for the brickmap
pub fn init(allocator: Allocator, dim_x: u32, dim_y: u32, dim_z: u32, config: Config) !BrickGrid {
    const grid = try allocator.alloc(GridEntry, dim_x * dim_y * dim_z);
    errdefer allocator.free(grid);
    std.mem.set(GridEntry, grid, .{ .@"type" = .empty, .data = 0 });

    const brick_alloc = config.brick_alloc orelse grid.len;
    const bricks = try allocator.alloc(Brick, brick_alloc);
    errdefer allocator.free(bricks);
    std.mem.set(Brick, bricks, .{ .solid_mask = 0, .material_index = unset_material, .lod_material_index = 0 });

    const material_indices = try allocator.alloc(u8, bricks.len * config.material_indices_per_brick);
    errdefer allocator.free(material_indices);
    std.mem.set(u8, material_indices, 0);

    const min_point_base_t = blk: {
        const min_point = config.min_point;
        const base_t = config.base_t;
        var result: [4]f32 = undefined;
        for (min_point) |axis, i| {
            result[i] = axis;
        }
        result[3] = base_t;
        break :blk result;
    };
    const max_point_scale = blk: {
        const scale = config.scale;
        // zig fmt: off
        var result = [4]f32{ 
            min_point_base_t[0] + @intToFloat(f32, dim_x) * scale, 
            min_point_base_t[1] + @intToFloat(f32, dim_y) * scale, 
            min_point_base_t[2] + @intToFloat(f32, dim_z) * scale, 
            scale 
        };
        // zig fmt: on
        break :blk result;
    };

    const max_ray_iteration = blk: {
        if (config.max_ray_iteration) |some| {
            break :blk some;
        }

        var biggest_axis = @maximum(dim_x, dim_y);
        biggest_axis = @maximum(biggest_axis, dim_z);
        break :blk biggest_axis * 8;
    };

    const voxel_dim = [3]u32{ dim_x * 8, dim_y * 8, dim_z * 8 };

    const bucket_segments = try std.math.divFloor(usize, material_indices.len, 1024.0);
    const bucket_storage = try BucketStorage.init(allocator, brick_alloc, bucket_segments);
    errdefer bucket_storage.deinit();

    // zig fmt: off
    return BrickGrid{ 
        .allocator = allocator, 
        .grid = grid, 
        .bricks = bricks, 
        .bucket_storage = bucket_storage,
        .material_indices = material_indices, 
        .active_bricks = 0, 
        .voxel_dim = voxel_dim, 
        .device_state = Device{
            .dim_x = dim_x,
            .dim_y = dim_y,
            .dim_z = dim_z,
            .max_ray_iteration = max_ray_iteration,
            .min_point_base_t = min_point_base_t,
            .max_point_scale = max_point_scale,
        } 
    };
    // zig fmt: on
}

/// Clean up host memory, does not account for device
pub fn deinit(self: BrickGrid) void {
    self.allocator.free(self.grid);
    self.allocator.free(self.bricks);
    self.allocator.free(self.material_indices);
    self.bucket_storage.deinit();
}

pub const InsertError = error{ OutOfBoundsX, OutOfBoundsY, OutOfBoundsZ };
pub fn safeInsert(self: *BrickGrid, x: usize, y: usize, z: usize, material_index: u32) InsertError!void {
    if (x < 0 or x >= self.voxel_dim[0]) {
        return InsertError.OutOfBoundsX; // x was out of bounds
    }
    if (y < 0 or y >= self.voxel_dim[1]) {
        return InsertError.OutOfBoundsY; // y was out of bounds
    }
    if (z < 0 or z >= self.voxel_dim[2]) {
        return InsertError.OutOfBoundsZ; // z was out of bounds
    }
    @call(.{ .modifier = .always_inline }, insert, .{ self, x, y, z, material_index });
}

/// Insert a brick at coordinate x y z
/// this function will cause panics if you insert out of bounds, use safeInsert
/// if bound checks are required
pub fn insert(self: *BrickGrid, x: usize, y: usize, z: usize, material_index: u8) void {
    const actual_y = self.device_state.dim_y * 8 - 1 - y;

    const grid_index = self.gridAt(x, actual_y, z);
    var entry = self.grid[grid_index];

    // if entry is empty we need to populate the entry first
    if (entry.@"type" == .empty) {
        entry = GridEntry{
            // TODO: loaded, or unloaded ??
            .@"type" = .loaded,
            .data = @intCast(u30, self.active_bricks),
        };
        self.active_bricks += 1;
    }

    const brick_index = @intCast(usize, entry.data);
    var brick = self.bricks[brick_index];

    // set the voxel to exist
    const nth_bit = brickAt(x, actual_y, z);

    // set the color information for the given voxel
    { // shift material position voxels that are after this voxel
        const voxels_in_brick = countBits(brick.solid_mask, 512);
        // TODO: error
        const bucket = self.bucket_storage.getBrickBucket(brick_index, voxels_in_brick, self.material_indices) catch {
            std.debug.panic("no more buckets", .{});
        };
        brick.material_index = @intCast(u24, bucket.start_index);

        // move all color data
        const bits_before = countBits(brick.solid_mask, nth_bit);
        var i: u32 = voxels_in_brick;
        while (i > bits_before) : (i -= 1) {
            const base_index = brick.material_index + i;
            self.material_indices[base_index] = self.material_indices[base_index - 1];
        }

        self.material_indices[brick.material_index + bits_before] = material_index;
        brick.material_index /= 4;
    }

    // set voxel
    brick.solid_mask |= @as(i512, 1) << nth_bit;

    // store changes
    self.bricks[@intCast(usize, entry.data)] = brick;
    self.grid[grid_index] = entry;
}

inline fn countBits(bits: i512, range_to: u32) u32 {
    var bit = bits;
    var count: i512 = 0;
    var i: u32 = 0;
    while (i < range_to and bit != 0) : (i += 1) {
        count += bit & 1;
        bit = bit >> 1;
    }
    return @intCast(u32, count);
}

// TODO: test
/// get brick index from global index coordinates
inline fn brickAt(x: usize, y: usize, z: usize) u9 {
    const brick_x: usize = @rem(x, 8);
    const brick_y: usize = @rem(y, 8);
    const brick_z: usize = @rem(z, 8);
    return @intCast(u9, brick_x + 8 * (brick_z + 8 * brick_y));
}

// TODO: test
/// get grid index from global index coordinates
inline fn gridAt(self: BrickGrid, x: usize, y: usize, z: usize) usize {
    const grid_x: u32 = @intCast(u32, x / 8);
    const grid_y: u32 = @intCast(u32, y / 8);
    const grid_z: u32 = @intCast(u32, z / 8);
    return @intCast(usize, grid_x + self.device_state.dim_x * (grid_z + self.device_state.dim_z * grid_y));
}

/// used by the brick grid to pack brick material data closer to eachother
const Bucket = struct {
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

const BucketRequestError = error{
    NoSuitableBucket,
};
const BucketStorage = struct {
    // the smallest bucket size in 2^n
    const min_2_pow_size = 8; // 256;

    pub const Index = packed struct {
        bucket_index: u16,
        element_index: u16,
    };

    allocator: Allocator,
    // used to find the active bucked for a given brick index
    index: []?Index,
    buckets: [2]Bucket,

    // TODO: allow configuring the distribution of buckets
    /// init a bucket storage.
    /// caller must make sure to call deinit
    /// segments_1024 defined how many 1024 segments should be stored.
    /// one segment will be split into: 2 * 256, 1 * 512
    pub inline fn init(allocator: Allocator, brick_count: usize, segments_1024: usize) !BucketStorage {
        std.debug.assert(segments_1024 > 0);

        var buckets: [2]Bucket = undefined;

        var prev_indices: u32 = 0;
        { // init first bucket
            // zig fmt: off
            buckets[0] = Bucket{ 
                .free = try ArrayList(Bucket.Entry).initCapacity(allocator, 2 * segments_1024), 
                .occupied = try ArrayList(?Bucket.Entry).initCapacity(allocator, segments_1024) 
            };
            // zig fmt: on
            const bucket_size = 256;
            var j: usize = 0;
            while (j < 2 * segments_1024) : (j += 1) {
                buckets[0].free.appendAssumeCapacity(.{ .start_index = prev_indices });
                prev_indices += bucket_size;
            }
        }
        {
            comptime var i: usize = 1;
            inline while (i < buckets.len) : (i += 1) {
                // zig fmt: off
                buckets[i] = Bucket{ 
                    .free = try ArrayList(Bucket.Entry).initCapacity(allocator, segments_1024), 
                    .occupied = try ArrayList(?Bucket.Entry).initCapacity(allocator, segments_1024 / 2) 
                };
                // zig fmt: on
                const bucket_size = try std.math.powi(u32, 2, min_2_pow_size + i);
                var j: usize = 0;
                while (j < segments_1024) : (j += 1) {
                    buckets[i].free.appendAssumeCapacity(.{ .start_index = prev_indices });
                    prev_indices += bucket_size;
                }
            }
        }

        const index = try allocator.alloc(?Index, brick_count);
        errdefer allocator.free(index);
        std.mem.set(?Index, index, null);

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
    pub inline fn getBrickBucket(self: *BucketStorage, brick_index: usize, voxel_offset: usize, material_indices: []u8) !Bucket.Entry {
        // check if brick already have assigned a bucket
        if (self.index[brick_index]) |index| {
            const bucket_size = try std.math.powi(usize, 2, min_2_pow_size + index.bucket_index);
            // if bucket size is insufficent
            if (bucket_size > voxel_offset) {
                return self.buckets[index.bucket_index].occupied.items[index.element_index].?;
            }

            // free previous bucket
            const previous_bucket = self.buckets[index.bucket_index].occupied.items[index.element_index].?;
            try self.buckets[index.bucket_index].free.append(previous_bucket);
            self.buckets[index.bucket_index].occupied.items[index.element_index] = null;

            // find a bucket with increased size that is free
            var i: usize = index.bucket_index + 1;
            while (i < self.buckets.len) : (i += 1) {
                if (self.buckets[i].free.items.len > 0) {
                    const bucket = self.buckets[i].free.pop();
                    const oc_index = try self.buckets[i].appendOccupied(bucket);
                    self.index[brick_index] = Index{ .bucket_index = @intCast(u16, i), .element_index = @intCast(u16, oc_index) };

                    // copy material indices to new bucket
                    std.mem.copy(u8, material_indices[bucket.start_index..], material_indices[previous_bucket.start_index .. previous_bucket.start_index + bucket_size]);
                    return bucket;
                }
            }
        } else {
            // fetch the smallest free bucket
            for (self.buckets) |*bucket, i| {
                if (bucket.free.items.len > 0) {
                    const take = bucket.free.pop();
                    const oc_index = try bucket.appendOccupied(take);
                    self.index[brick_index] = Index{ .bucket_index = @intCast(u16, i), .element_index = @intCast(u16, oc_index) };
                    return take;
                }
            }
        }
        return BucketRequestError.NoSuitableBucket; // no free bucket big enough to store brick color data
    }

    pub inline fn deinit(self: BucketStorage) void {
        self.allocator.free(self.index);
        for (self.buckets) |bucket| {
            bucket.free.deinit();
            bucket.occupied.deinit();
        }
    }
};
