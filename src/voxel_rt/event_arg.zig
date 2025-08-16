const VoxelRT = @import("../VoxelRT.zig");

pub const EventArgument = struct {
    delta_time: f32,
    voxel_rt: *const VoxelRT,
};
