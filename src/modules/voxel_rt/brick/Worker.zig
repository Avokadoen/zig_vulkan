const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const tracy = @import("ztracy");

const State = @import("State.zig");
const MaterialAllocator = @import("MaterialAllocator.zig");

/// Parallel workers that does insert and remove work on the grid
/// each worker get one kernel thread
const Worker = @This();

/// a FIFO queue of jobs for a given worker
const JobQueue = std.fifo.LinearFifo(Job, .Dynamic);
const Signal = std.atomic.Value(bool);

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
material_allocator: *MaterialAllocator,

wake_mutex: Mutex,
wake_event: Condition,

job_mutex: Mutex,
job_queue: *JobQueue,

sleep: Signal,
shutdown: Signal,

pub fn init(
    allocator: Allocator,
    id: usize,
    grid: *State,
    material_allocator: *MaterialAllocator,
    initial_queue_capacity: usize,
) !Worker {
    var job_queue = try allocator.create(JobQueue);
    job_queue.* = JobQueue.init(allocator);
    errdefer job_queue.deinit();
    try job_queue.ensureTotalCapacity(initial_queue_capacity);

    return Worker{
        .allocator = allocator,
        .id = id,
        .grid = grid,
        .material_allocator = material_allocator,
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

    if (self.sleep.load(.seq_cst) == false) {
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

    life_loop: while (self.shutdown.load(.seq_cst) == false) {
        self.job_mutex.lock();
        if (self.sleep.load(.seq_cst) == false) {
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

                if (self.shutdown.load(.seq_cst)) break :life_loop;
                if (self.sleep.load(.seq_cst)) break :work_loop;
            }
        }
        defer self.job_mutex.unlock();
        self.wake_event.wait(&self.job_mutex);
    }

    self.job_queue.deinit();
    self.allocator.destroy(self.job_queue);
    self.material_allocator.deinit(self.allocator);
}

// perform a insert in the grid
fn performInsert(self: *Worker, insert_job: Insert) void {
    std.debug.assert(insert_job.x < self.grid.device_state.voxel_dim_x);
    std.debug.assert(insert_job.y < self.grid.device_state.voxel_dim_y);
    std.debug.assert(insert_job.z < self.grid.device_state.voxel_dim_z);

    // Flip Y for more intutive coordinates
    const flipped_y = self.grid.device_state.voxel_dim_y - 1 - insert_job.y;

    const grid_index = gridAt(self.grid.*.device_state, insert_job.x, flipped_y, insert_job.z);
    const brick_status_index = grid_index / 32;
    const brick_status_offset: u5 = @intCast(grid_index % 32);
    const brick_status = self.grid.brick_statuses[brick_status_index].read(brick_status_offset);
    const brick_index = blk: {
        if (brick_status == .loaded) {
            break :blk self.grid.brick_indices[grid_index];
        }

        // if entry is empty we need to populate the entry first
        const higher_grid_index = higherGridAt(self.grid.*.device_state, insert_job.x, flipped_y, insert_job.z);
        self.grid.higher_order_grid_mutex.lock();
        self.grid.*.higher_order_grid[higher_grid_index] += 1;
        self.grid.higher_order_grid_mutex.unlock();
        self.grid.higher_order_grid_delta.registerDelta(higher_grid_index);

        // atomically fetch previous brick count and then add 1 to count
        break :blk self.grid.*.active_bricks.fetchAdd(1, .monotonic);
    };

    const occupancy_from = brick_index * State.brick_bytes;
    const occupancy_to = brick_index * State.brick_bytes + State.brick_bytes;
    const brick_occupancy = self.grid.brick_occupancy[occupancy_from..occupancy_to];
    var brick_material_index = &self.grid.brick_start_indices[brick_index];

    // set the voxel to exist
    const nth_bit = voxelAt(insert_job.x, flipped_y, insert_job.z);

    // set the color information for the given voxel
    {
        // set the brick's material index if unset
        if (brick_material_index.* == State.Brick.unset_index) {
            // We store 4 material indices per word (1 byte per material)
            const material_entry = self.material_allocator.nextEntry();
            brick_material_index.value = @intCast(material_entry);
            brick_material_index.type = .voxel_start_index;

            // store brick material start index
            self.grid.bricks_start_indices_delta.registerDelta(brick_index);
        }

        std.debug.assert(brick_material_index.type == .voxel_start_index);
        std.debug.assert(brick_material_index.value == std.mem.alignForward(u31, brick_material_index.value, 16));

        const new_voxel_material_index = brick_material_index.value * 4 + nth_bit;
        const material_indices_unpacked = std.mem.sliceAsBytes(self.grid.*.material_indices);
        material_indices_unpacked[new_voxel_material_index] = insert_job.material_index;

        // material indices are packed in 32bit on GPU and 8bit on CPU
        // we divide by four to store the correct *GPU* index.
        // Example: index 8 point to *byte* 8 on host, 8 points to *word* 8 on gpu.
        self.grid.material_indices_deltas[0].registerDelta(new_voxel_material_index / 4);
    }

    // set voxel
    const mask_index = nth_bit / @bitSizeOf(u8);
    const mask_bit: u3 = @intCast(@rem(nth_bit, @bitSizeOf(u8)));
    brick_occupancy[mask_index] |= @as(u8, 1) << mask_bit;

    // store brick changes
    self.grid.bricks_occupancy_delta.registerDelta(occupancy_from + mask_index);

    // set the brick as loaded
    self.grid.brick_statuses[brick_status_index].write(.loaded, brick_status_offset);
    self.grid.brick_statuses_deltas[self.id].registerDelta(brick_status_index);

    // register brick index
    self.grid.brick_indices[grid_index] = brick_index;
    self.grid.brick_indices_deltas[self.id].registerDelta(grid_index);
}

// TODO: test
/// get brick index from global index coordinates
fn voxelAt(x: usize, y: usize, z: usize) State.BrickMapLog2 {
    const brick_x: usize = @rem(x, State.brick_dimension);
    const brick_y: usize = @rem(y, State.brick_dimension);
    const brick_z: usize = @rem(z, State.brick_dimension);
    return @intCast(brick_x + State.brick_dimension * (brick_z + State.brick_dimension * brick_y));
}

/// get grid index from global index coordinates
fn gridAt(device_state: State.Device, x: usize, y: usize, z: usize) usize {
    const grid_x: u32 = @intCast(x / State.brick_dimension);
    const grid_y: u32 = @intCast(y / State.brick_dimension);
    const grid_z: u32 = @intCast(z / State.brick_dimension);
    return @intCast(grid_x + device_state.dim_x * (grid_z + device_state.dim_z * grid_y));
}

/// get higher grid index from global index coordinates
fn higherGridAt(device_state: State.Device, x: usize, y: usize, z: usize) usize {
    // TODO: allow configuration of higher order grid
    const higher_order_size = State.brick_dimension * 4; // 4 bricks per higher order
    const higher_grid_x: u32 = @intCast(x / higher_order_size);
    const higher_grid_y: u32 = @intCast(y / higher_order_size);
    const higher_grid_z: u32 = @intCast(z / higher_order_size);
    return @intCast(higher_grid_x + device_state.higher_dim_x * (higher_grid_z + device_state.higher_dim_z * higher_grid_y));
}

/// count the set bits up to range_to (exclusive)
fn countBits(bits: [State.brick_bytes]u8, range_to: u32) u32 {
    var bit: State.BrickMap = @bitCast(bits);
    var count: State.BrickMap = 0;
    var i: u32 = 0;
    while (i < range_to and bit != 0) : (i += 1) {
        count += bit & 1;
        bit = bit >> 1;
    }
    return @intCast(count);
}
