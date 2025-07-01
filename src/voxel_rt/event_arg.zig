const Context = @import("../render.zig").Context;

pub const EventArgument = struct {
    ctx: Context,
    delta_time: f32,
};
