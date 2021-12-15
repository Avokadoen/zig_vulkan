const std = @import("std");
const zlm = @import("zlm");

pub const TextureHandle = struct {
    id: c_int,
    width: f32,
    height: f32,
};

pub const UV = struct {
    min: zlm.Vec2,
    max: zlm.Vec2,
};

pub const Rectangle = struct {
    pos: zlm.Vec2,
    width: f32,
    height: f32,

    // TODO: test
    pub fn contains(self: Rectangle, point: zlm.Vec2) bool {
        const x_delta = self.pos.x - point.x;
        const y_delta = self.pos.y - point.y;
        return std.math.absFloat(x_delta) < self.width * 0.5 and std.math.absFloat(y_delta) < self.height * 0.5;
    }
};

const BufferUpdateRateEnum = enum {
    always,
    every_ms,
};

pub const BufferUpdateRate = union(BufferUpdateRateEnum) {
    always: void,
    every_ms: u32,
};

