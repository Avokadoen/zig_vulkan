const render = @import("../render/render.zig");
const sc = render.swapchain;
const descriptor = render.descriptor;

const za = @import("zalgebra");
const Vec2 = @Vector(2, f32);

const Camera = @This();

move_speed: f32,
zoom_speed: f32,

sync_desc_ptr: *descriptor.SyncDescriptor,

pub fn zoomIn(self: *Camera, delta_time: f32) void {
    const dt = delta_time;
    const fields = &self.sync_desc_ptr.*.ubo.uniform_data.view.data;
    fields.*[0][0] += (fields.*[0][0] * (self.zoom_speed * dt)) + dt;
    fields.*[1][1] += (fields.*[1][1] * (self.zoom_speed * dt)) + dt;
    fields.*[2][2] += (fields.*[2][2] * (self.zoom_speed * dt)) + dt;
    self.sync_desc_ptr.ubo.mark_dirty();
}

pub fn zoomOut(self: *Camera, delta_time: f32) void {
    const dt = delta_time;
    const fields = &self.sync_desc_ptr.*.ubo.uniform_data.view.data;
    fields.*[0][0] -= (fields.*[0][0] * (self.zoom_speed * dt)) + dt;
    fields.*[1][1] -= (fields.*[1][1] * (self.zoom_speed * dt)) + dt;
    fields.*[2][2] -= (fields.*[2][2] * (self.zoom_speed * dt)) + dt;
    self.sync_desc_ptr.ubo.mark_dirty();
}

pub fn translate(self: *Camera, delta_time: f32, dir: Vec2) void {
    const velocity = za.Vec2.scale(za.Vec2.norm(dir), self.move_speed * delta_time);
    const fields = &self.sync_desc_ptr.*.ubo.uniform_data.view.data;
    fields.*[3][0] += velocity[0];
    fields.*[3][1] += velocity[1];
    self.sync_desc_ptr.ubo.mark_dirty();
}

pub fn getPosition(self: Camera) Vec2 {
    const fields = self.sync_desc_ptr.*.ubo.uniform_data.view.fields;
    return za.Vec2.new(fields[3][0], fields[3][1]);
}

pub fn getZoom(self: Camera) Vec2 {
    const fields = self.sync_desc_ptr.*.ubo.uniform_data.view.fields;
    return za.Vec2.new(fields[0][0], fields[1][1]);
}
