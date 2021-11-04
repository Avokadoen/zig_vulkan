const zlm = @import("zlm");

pub const TextureHandle = c_int;

pub const UV = struct {
    min: zlm.Vec2,
    max: zlm.Vec2,
};

pub const Rectangle = struct {
    pos: zlm.Vec2,
    width: f32,
    height: f32,
};

const BufferUpdateRateEnum = enum {
    always,
    every_ms,
};
pub const BufferUpdateRate = union(BufferUpdateRateEnum) {
    always: void,
    every_ms: u32,
};
