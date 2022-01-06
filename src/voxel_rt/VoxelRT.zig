const std = @import("std");
const Allocator = std.mem.Allocator;

const zlm = @import("zlm");

const render = @import("../render/render.zig");
const Context = render.Context;

const Self = @This();
const Camera = @import("Camera.zig");
const gpu_types = @import("gpu_types.zig");

comp_pipeline: render.ComputeDrawPipeline,

pub fn init(allocator: Allocator, ctx: Context, target_texture: *render.Texture) !Self {
    // place holder test compute pipeline
    const comp_pipeline = blk: {
        const Compute = render.ComputeDrawPipeline;
        const buffer_configs = gpu_types.getAllBufferConfigs();
        break :blk try Compute.init(allocator, ctx, "../../raytracer.comp.spv", target_texture, Camera.getGpuSize(), buffer_configs[0..]);
    };
    errdefer comp_pipeline.deinit(ctx);

    // const test_data = [2]zlm.Vec2{
    //     .{ .x = 0, .y = 1 },
    //     .{ .x = 1, .y = 0 },
    // };
    // try comp_pipeline.buffers[0].transfer(ctx, zlm.Vec2, test_data[0..]);
    // uniform Camera, binding: 1
    // pub const Camera = extern struct {
    //     image_width: i32,
    //     image_height: i32,

    //     horizontal: zlm.Vec3,
    //     vertical: zlm.Vec3,

    //     lower_left_corner: zlm.Vec3,
    //     origin: zlm.Vec3,

    //     samples_per_pixel: i32,
    //     max_bounce: i32,
    // };

    return Self{ .comp_pipeline = comp_pipeline };
}

// compute the next frame and draw it to target texture, note that it will not draw to any window
pub inline fn compute(self: Self, ctx: Context) !void {
    try self.comp_pipeline.compute(ctx);
}

pub fn deinit(self: Self, ctx: Context) void {
    self.comp_pipeline.deinit(ctx);
}
