const Context = @import("../render.zig").Context;
const VoxelRT = @import("../VoxelRT.zig");

pub const EventArgument = struct {
    ctx: Context,
    delta_time: f32,
    voxel_rt: *const VoxelRT,
};
