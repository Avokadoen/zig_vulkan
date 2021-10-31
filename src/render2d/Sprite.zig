const zlm = @import("zlm");

const DB = @import("DB.zig");
const types = @import("util_types.zig");
const Rectangle = types.Rectangle;
const TextureHandle = types.TextureHandle;

/// A opaque sprite handle, can be used to manipulate a given sprite
const Sprite = @This();

db_ptr: *DB,
db_id: usize,

pub inline fn init() void {
    @compileError("call render2d.createSprite() instead");
}

/// set sprite position
pub inline fn setPosition(self: Sprite, pos: zlm.Vec2) void {
    self.db_ptr.positions.items[self.db_id] = pos;
}

pub inline fn getPosition(self: Sprite) zlm.Vec2 {
    return self.db_ptr.positions.items[self.db_id];
}

/// set sprite size in pixels
pub inline fn setSize(self: Sprite, scale: zlm.Vec2) void {
    self.db_ptr.scales.items[self.db_id] = scale;
}

pub inline fn getSize(self: Sprite) zlm.Vec2 {
    return self.db_ptr.scales.items[self.db_id];
}

/// set sprite rotation
pub inline fn setRotation(self: Sprite, rotation: f32) void {
    self.db_ptr.rotations.items[self.db_id] = zlm.toRadians(rotation);
}

pub inline fn getRotation(self: Sprite) f32 {
    return zlm.toDegrees(self.db_ptr.rotations.items[self.db_id]);
}

/// Update sprite image to a new handle
pub inline fn setTexture(self: Sprite, new_handle: TextureHandle) void {
    self.db_ptr.uv_indices.items[self.db_id] = new_handle;
}

pub inline fn getTexture(self: Sprite) TextureHandle {
    return self.db_ptr.uv_indices.items[self.db_id];
}

/// get the bounding rectangle of the sprite
pub inline fn getRectangle(self: Sprite) Rectangle {
    const position = self.db_ptr.positions.items[self.db_id];
    const scale = self.db_ptr.scales.items[self.db_id];
    return Rectangle{
        .pos = position,
        .width = scale.x,
        .height = scale.y,
    };
}

/// Scale sprite to a given height while preserving ratio
pub fn scaleToHeight(self: Sprite, height: f32) void {
    const rect = self.getRectangle();
    const ratio = @intToFloat(f32, rect.height) / @intToFloat(f32, rect.width);
    self.scales.items[self.db_id] = zlm.Vec2{
        .x = height * ratio,
        .y = height,
    };
}
