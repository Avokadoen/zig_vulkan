const zlm = @import("zlm");

const DB = @import("DB.zig");
const types = @import("util_types.zig");
const Rectangle = types.Rectangle;
const TextureHandle = types.TextureHandle;

/// A opaque sprite handle, can be used to manipulate a given sprite
const Sprite = @This();

db_ptr: *DB,
db_id: DB.Id,
layer: usize,

pub inline fn init() void {
    @compileError("call render2d.createSprite() instead");
}

/// set sprite position
pub inline fn setPosition(self: *Sprite, pos: zlm.Vec2) void {
    const index = self.db_ptr.getIndex(&self.db_id);
    self.db_ptr.positions.updateAt(index, pos);
}

pub inline fn getPosition(self: *Sprite) zlm.Vec2 {
    const index = self.db_ptr.getIndex(&self.db_id);
    return self.db_ptr.positions.storage.items[index];
}

/// set sprite size in pixels
pub fn setSize(self: *Sprite, scale: zlm.Vec2) void {
    const index = self.db_ptr.getIndex(&self.db_id);
    self.db_ptr.scales.updateAt(index, scale);
}

pub inline fn getSize(self: *Sprite) zlm.Vec2 {
    const index = self.db_ptr.getIndex(&self.db_id);
    return self.db_ptr.scales.storage.items[index];
}

/// set sprite rotation, counter clockwise degrees
pub inline fn setRotation(self: *Sprite, rotation: f32) void {
    const index = self.db_ptr.getIndex(&self.db_id);
    self.db_ptr.rotations.updateAt(index, zlm.toRadians(rotation));
}

pub inline fn getRotation(self: *Sprite) f32 {
    const index = self.db_ptr.getIndex(&self.db_id);
    return zlm.toDegrees(self.db_ptr.rotations.storage.items[index]);
}

/// Update sprite image to a new handle
pub inline fn setTexture(self: *Sprite, new_handle: TextureHandle) void {
    const index = self.db_ptr.getIndex(&self.db_id);
    self.db_ptr.uv_indices.updateAt(index, new_handle.id);
    self.db_ptr.uv_meta.items[@intCast(usize, new_handle.id)] = new_handle;
}

pub inline fn getTexture(self: *Sprite) TextureHandle {
    const index = self.db_ptr.getIndex(&self.db_id);
    const uv_index = self.db_ptr.uv_indices.storage.items[index];
    return self.db_ptr.uv_meta.items[uv_index];
}

/// Update the sprite layer
pub inline fn setLayer(self: *Sprite, layer: usize) !void {
    if (self.layer == layer) return;

    try self.db_ptr.applyLayer(&self.db_id, self.layer, layer);
    self.layer = layer;
}

/// get the bounding rectangle of the sprite
pub inline fn getRectangle(self: *Sprite) Rectangle {
    const position = self.getPosition();
    const scale = self.getSize();
    return Rectangle{
        .pos = position,
        .width = scale.x,
        .height = scale.y,
    };
}

/// Scale sprite to a given height while preserving ratio
pub fn scaleToHeight(self: *Sprite, height: f32) void {
    const rect = self.getRectangle();
    const ratio = @intToFloat(f32, rect.height) / @intToFloat(f32, rect.width);
    const index = self.db_ptr.getIndex(&self.db_id);
    self.scales.items[index] = zlm.Vec2{
        .x = height * ratio,
        .y = height,
    };
}
