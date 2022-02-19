const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const tracy = @import("../../../tracy.zig");

const State = @import("State.zig");
const BucketStorage = @import("BucketStorage.zig");

/// Parallel workers that does insert and remove work on the grid
/// each worker get one kernel thread
const Worker = @This();

/// a FIFO queue of jobs for a given worker
const JobQueue = std.fifo.LinearFifo(Job, .Dynamic);
const Signal = std.atomic.Atomic(bool);

pub const Insert = struct { x: usize, y: usize, z: usize, material_index: u8 };
pub const JobTag = enum {
    insert,
    // remove,
};
pub const Job = union(JobTag) {
    insert: Insert,
    // remove: struct {
    //     x: usize,
    //     y: usize,
    //     z: usize,
    // },
};

allocator: Allocator,

id: usize,
grid: *State,

// used to assign material index to a given brick
bucket_storage: BucketStorage,

wake_mutex: Mutex,
wake_event: Condition,

job_mutex: Mutex,
job_queue: *JobQueue,

sleep: Signal,
shutdown: Signal,

pub fn init(id: usize, worker_count: usize, grid: *State, allocator: Allocator, initial_queue_capacity: usize) !Worker {
    std.debug.assert(worker_count != 0);

    var job_queue = try allocator.create(JobQueue);
    job_queue.* = JobQueue.init(allocator);
    errdefer job_queue.deinit();
    try job_queue.ensureTotalCapacity(initial_queue_capacity);

    // calculate bricks in this worker's bucket
    const bucket_storage = blk: {
        var brick_count = std.math.divFloor(usize, grid.bricks.len, worker_count) catch unreachable; // assert(worker_count != 0)
        var material_count = std.math.divFloor(usize, grid.material_indices.len, worker_count) catch unreachable;
        // buckets store values segmenting using 2048 to split into different sizes. We rem 2048 to get a accurate length of the bucket
        material_count -= material_count % 2048;
        const start_index = @intCast(u32, material_count * id);

        if (id == worker_count - 1) {
            brick_count += std.math.rem(usize, grid.bricks.len, worker_count) catch unreachable;
            material_count += std.math.rem(usize, grid.material_indices.len, worker_count) catch unreachable;
        }

        break :blk try BucketStorage.init(allocator, start_index, brick_count, material_count);
    };
    errdefer bucket_storage.deinit();

    return Worker{
        .allocator = allocator,
        .id = id,
        .grid = grid,
        .bucket_storage = bucket_storage,
        .wake_mutex = .{},
        .wake_event = .{},
        .job_mutex = .{},
        .job_queue = job_queue,
        .sleep = Signal.init(false),
        .shutdown = Signal.init(false),
    };
}

pub fn registerJob(self: *Worker, job: Job) void {
    self.job_mutex.lock();
    self.job_queue.writeItem(job) catch {}; // TODO: report error somehow?
    self.job_mutex.unlock();

    if (self.sleep.load(.SeqCst) == false) {
        self.wake_event.signal();
    }
}

pub fn work(self: *Worker) void {
    // do not create a thread name if it will not be used
    const c_thread_name: [:0]const u8 = blk: {
        if (tracy.enabled) {
            // create thread name
            var thread_name_buffer: [32:0]u8 = undefined;
            const thread_name = std.fmt.bufPrint(thread_name_buffer[0..], "worker {d}", .{self.id}) catch std.debug.panic("failed to print thread name", .{});
            break :blk std.cstr.addNullByte(self.allocator, thread_name) catch std.debug.panic("failed to add '0' sentinel", .{});
        } else {
            break :blk "worker";
        }
    };
    defer if (tracy.enabled) self.allocator.free(c_thread_name);

    tracy.SetThreadName(c_thread_name);
    const worker_zone = tracy.ZoneN(@src(), "grid work");
    defer worker_zone.End();

    life_loop: while (self.shutdown.load(.SeqCst) == false) {
        self.job_mutex.lock();
        if (self.sleep.load(.SeqCst) == false) {
            var i: usize = 0;
            work_loop: while (self.job_queue.*.readItem()) |job| {
                self.job_mutex.unlock();
                switch (job) {
                    .insert => |insert_job| {
                        self.performInsert(insert_job);
                    },
                }
                self.job_mutex.lock();
                i += 1;

                if (self.shutdown.load(.SeqCst)) break :life_loop;
                if (self.sleep.load(.SeqCst)) break :work_loop;
            }
        }
        defer self.job_mutex.unlock();
        self.wake_event.wait(&self.job_mutex);
    }

    self.job_queue.deinit();
    self.allocator.destroy(self.job_queue);
    self.bucket_storage.deinit();
}

// perform a insert in the grid
fn performInsert(self: *Worker, insert_job: Insert) void {
    const actual_y = ((self.grid.device_state.dim_y * 8) - 1) - insert_job.y;

    const grid_index = gridAt(self.grid.*.device_state, insert_job.x, actual_y, insert_job.z);
    var entry = self.grid.grid[grid_index];

    // if entry is empty we need to populate the entry first
    if (entry.@"type" == .empty) {
        // atomically fetch previous brick count and then add 1 to count
        const active_bricks = self.grid.*.active_bricks.fetchAdd(1, .SeqCst);
        entry = State.GridEntry{
            // TODO: loaded, or unloaded ??
            .@"type" = .loaded,
            .data = @intCast(u30, active_bricks),
        };

        const higher_grid_index = higherGridAt(self.grid.*.device_state, insert_job.x, actual_y, insert_job.z);
        self.grid.higher_order_grid_mutex.lock();
        defer self.grid.higher_order_grid_mutex.unlock();
        self.grid.higher_order_grid[higher_grid_index] += 1;
    }

    const brick_index = @intCast(usize, entry.data);
    var brick = self.grid.bricks[brick_index];

    // set the voxel to exist
    const nth_bit = brickAt(insert_job.x, actual_y, insert_job.z);

    // set the color information for the given voxel
    { // shift material position voxels that are after this voxel
        const was_set: bool = (brick.solid_mask & @as(i512, 1) << nth_bit) != 0;
        const voxels_in_brick = countBits(brick.solid_mask, 512);
        // TODO: error
        // std.debug.print("heisenbug\n", .{});
        const bucket = self.bucket_storage.getBrickBucket(brick_index, voxels_in_brick, self.grid.*.material_indices, was_set) catch {
            std.debug.panic("at {d} {d} {d} no more buckets", .{ insert_job.x, insert_job.y, insert_job.z });
        };
        brick.material_index = bucket.start_index;

        // move all color data
        const bits_before = countBits(brick.solid_mask, nth_bit);
        if (was_set == false) {
            var i: u32 = voxels_in_brick;
            while (i > bits_before) : (i -= 1) {
                const base_index = brick.material_index + i;
                self.grid.*.material_indices[base_index] = self.grid.material_indices[base_index - 1];
            }
        }

        self.grid.*.material_indices[brick.material_index + bits_before] = insert_job.material_index;

        // material indices is stored as 32bit on GPU and 8bit on CPU
        // we divide by for to store the correct *GPU* index
        brick.material_index /= 4;
    }

    // set voxel
    brick.solid_mask |= @as(i512, 1) << nth_bit;

    // store changes
    self.grid.*.bricks[@intCast(usize, entry.data)] = brick;
    self.grid.*.grid[grid_index] = entry;
}

// TODO: test
/// get brick index from global index coordinates
inline fn brickAt(x: usize, y: usize, z: usize) u9 {
    const brick_x: usize = @rem(x, 8);
    const brick_y: usize = @rem(y, 8);
    const brick_z: usize = @rem(z, 8);
    return @intCast(u9, brick_x + 8 * (brick_z + 8 * brick_y));
}

/// get grid index from global index coordinates
inline fn gridAt(device_state: State.Device, x: usize, y: usize, z: usize) usize {
    const grid_x: u32 = @intCast(u32, x / 8);
    const grid_y: u32 = @intCast(u32, y / 8);
    const grid_z: u32 = @intCast(u32, z / 8);
    return @intCast(usize, grid_x + device_state.dim_x * (grid_z + device_state.dim_z * grid_y));
}

/// get higher grid index from global index coordinates
inline fn higherGridAt(device_state: State.Device, x: usize, y: usize, z: usize) usize {
    const higher_grid_x: u32 = @intCast(u32, x / (8 * 4));
    const higher_grid_y: u32 = @intCast(u32, y / (8 * 4));
    const higher_grid_z: u32 = @intCast(u32, z / (8 * 4));
    return @intCast(usize, higher_grid_x + device_state.higher_dim_x * (higher_grid_z + device_state.higher_dim_z * higher_grid_y));
}

/// count the set bits of a i512, up to range_to (exclusive)
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
