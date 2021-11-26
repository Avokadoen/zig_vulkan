const render = @import("../render/render.zig");
const sc = render.swapchain;
const descriptor = render.descriptor;

const zlm = @import("zlm");

const Camera = @This();

move_speed: f32,
zoom_speed: f32,

view: sc.ViewportScissor,

sync_desc_ptr: *descriptor.SyncDescriptor,

pub fn zoomIn(self: *Camera, delta_time: f32) void {
    const dt = delta_time;
    const fields = &self.sync_desc_ptr.*.ubo.uniform_data.view.fields;
    fields.*[0][0] += (fields.*[0][0] * (self.zoom_speed * dt)) + dt;
    fields.*[1][1] += (fields.*[1][1] * (self.zoom_speed * dt)) + dt;
    fields.*[2][2] += (fields.*[2][2] * (self.zoom_speed * dt)) + dt;
    self.sync_desc_ptr.ubo.mark_dirty();
}

pub fn zoomOut(self: *Camera, delta_time: f32) void {
    const dt = delta_time;
    const fields = &self.sync_desc_ptr.*.ubo.uniform_data.view.fields;
    fields.*[0][0] -= (fields.*[0][0] * (self.zoom_speed * dt)) + dt;
    fields.*[1][1] -= (fields.*[1][1] * (self.zoom_speed * dt)) + dt;
    fields.*[2][2] -= (fields.*[2][2] * (self.zoom_speed * dt)) + dt;
    self.sync_desc_ptr.ubo.mark_dirty();
}

pub fn translate(self: *Camera, delta_time: f32, dir: zlm.Vec2) void {
    const velocity = dir.normalize().scale(self.move_speed * delta_time);
    const fields = &self.sync_desc_ptr.*.ubo.uniform_data.view.fields;
    fields.*[3][0] += velocity.x;
    fields.*[3][1] += velocity.y;
    self.sync_desc_ptr.ubo.mark_dirty();
}

pub fn getPosition(self: Camera) zlm.Vec2 {
    const fields = self.sync_desc_ptr.*.ubo.uniform_data.view.fields;
    return zlm.Vec2.new(fields[3][0], fields[3][1]);
}

pub fn getZoom(self: Camera) zlm.Vec2 {
    const fields = self.sync_desc_ptr.*.ubo.uniform_data.view.fields;
    return zlm.Vec2.new(fields[0][0], fields[1][1]);
}
