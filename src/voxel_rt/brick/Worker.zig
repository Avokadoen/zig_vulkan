const std = @import("std");
const Allocator = std.mem.Allocator;

const State = @import("State.zig");

/// Parallel workers that does insert and remove work on the grid
/// each worker get one kernel thread
const Worker = @This();

/// a FIFO queue of jobs for a given worker
const JobQueue = std.fifo.LinearFifo(Job, .Dynamic);

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

id: usize,
grid: *State,

wake_mutex: std.Thread.Mutex,
wake_event: std.Thread.Condition,

// FIFO list
job_mutex: std.Thread.Mutex,
job_queue: JobQueue,

kill_self: bool = false,

pub fn init(id: usize, grid: *State, allocator: Allocator, initial_queue_capacity: usize) !Worker {
    var job_queue = JobQueue.init(allocator);
    try job_queue.ensureTotalCapacity(initial_queue_capacity);
    return Worker{ .id = id, .grid = grid, .wake_mutex = .{}, .wake_event = .{}, .job_mutex = .{}, .job_queue = job_queue };
}

pub fn registerJob(self: *Worker, job: Job) void {
    self.job_mutex.lock();
    self.job_queue.writeItem(job) catch {}; // TODO: report error somehow?
    self.job_mutex.unlock();

    self.wake_event.signal();
}

pub fn work(self: *Worker) void {
    while (self.kill_self == false) {
        self.wake_mutex.lock();
        defer self.wake_mutex.unlock();

        // if there is work to be done
        self.job_mutex.lock();
        const next = self.job_queue.readItem();
        self.job_mutex.unlock();

        if (next) |job| {
            switch (job) {
                .insert => |insert_job| {
                    self.performInsert(insert_job);
                },
            }
        } else {
            std.debug.print("worker {d} going to sleep, no work\n", .{self.id});
            self.wake_event.wait(&self.wake_mutex);
            std.debug.print("worker {d} waking up\n", .{self.id});
        }
    }

    self.job_queue.deinit();
}

// perform a insert in the grid
fn performInsert(self: *Worker, insert_job: Insert) void {
    const actual_y = ((self.grid.device_state.dim_y * 8) - 1) - insert_job.y;

    const grid_index = gridAt(self.grid.*.device_state, insert_job.x, actual_y, insert_job.z);
    var entry = self.grid.grid[grid_index];

    // if entry is empty we need to populate the entry first
    if (entry.@"type" == .empty) {
        self.grid.active_bricks_mutex.lock();
        entry = State.GridEntry{
            // TODO: loaded, or unloaded ??
            .@"type" = .loaded,
            .data = @intCast(u30, self.grid.active_bricks),
        };
        self.grid.*.active_bricks += 1;
        self.grid.*.active_bricks_mutex.unlock();
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
        const bucket = self.grid.bucket_storage.getBrickBucket(brick_index, voxels_in_brick, self.grid.*.material_indices, was_set) catch {
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
