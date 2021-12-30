const std = @import("std");
const Allocator = std.mem.Allocator;

const zlm = @import("zlm");

const render = @import("../render/render.zig");
const Context = render.Context;

const Self = @This();

comp_pipeline: render.ComputeDrawPipeline,

pub fn init(allocator: Allocator, ctx: Context, target_texture: *render.Texture) !Self {
    // place holder test compute pipeline
    const comp_pipeline = blk: {
        const Compute = render.ComputeDrawPipeline;
        const buffer_configs: [1]Compute.BufferConfig = .{.{ .size = @sizeOf(zlm.Vec2) * 2, .constant = false }};
        break :blk try Compute.init(allocator, ctx, "../../comp.comp.spv", target_texture, buffer_configs[0..]);
    };
    errdefer comp_pipeline.deinit(ctx);

    const test_data = [2]zlm.Vec2{
        .{ .x = 0, .y = 1 },
        .{ .x = 1, .y = 0 },
    };
    try comp_pipeline.buffers[0].transfer(ctx, zlm.Vec2, test_data[0..]);

    return Self{ .comp_pipeline = comp_pipeline };
}

// compute the next frame and draw it to target texture, note that it will not draw to any window
pub inline fn compute(self: Self, ctx: Context) !void {
    try self.comp_pipeline.compute(ctx);
}

pub fn deinit(self: Self, ctx: Context) void {
    self.comp_pipeline.deinit(ctx);
}
