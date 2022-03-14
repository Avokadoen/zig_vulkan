const std = @import("std");

const Vec2 = @Vector(2, f32);

pub const TextureHandle = struct {
    id: c_int,
    width: f32,
    height: f32,
};

pub const ImageHandle = struct {
    id: usize,
    width: i32,
    height: i32,
};

pub const UV = struct {
    min: Vec2,
    max: Vec2,
};

pub const Rectangle = struct {
    pos: Vec2,
    width: f32,
    height: f32,

    // TODO: test
    pub fn contains(self: Rectangle, point: Vec2) bool {
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
