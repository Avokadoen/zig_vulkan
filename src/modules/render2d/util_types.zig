const std = @import("std");

const Vec2 = @Vector(2, f32);

pub const TextureHandle = struct {
    id: c_int,
    width: f32,
    height: f32,
};

/// ImageHandle represent a image. Keep in mind variables are read only: 
///        - changes to this struct will not change rendered image
///        - one should avoid storing copies of this struct in api user code since they might become out of sync
/// Use the render2d API functions to get correct reads and sets for images
pub const ImageHandle = struct {
    pub const IdType = usize;

    id: IdType,
    is_dirty: bool,
    /// the width of the original image
    source_width: i32,
    /// the height of the original image
    source_height: i32,
    /// current width
    width: i32,
    /// current height
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
    never,
    always,
    every_ms,
};

pub const BufferUpdateRate = union(BufferUpdateRateEnum) {
    never: void,
    always: void,
    every_ms: u32,
};
