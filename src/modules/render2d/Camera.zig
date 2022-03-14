const render = @import("../render.zig");
const sc = render.swapchain;
const descriptor = render.descriptor;

const za = @import("zalgebra");
const Vec2 = @Vector(2, f32);

const Camera = @This();

move_speed: f32,
zoom_speed: f32,

// location to apply changes to
sync_descs: []descriptor.SyncDescriptor,

pub fn zoomIn(self: *Camera, delta_time: f32) void {
    const dt = delta_time;
    for (self.sync_descs) |*descript| {
        const fields = &descript.*.ubo.uniform_data.view.data;
        fields.*[0][0] += (fields.*[0][0] * (self.zoom_speed * dt)) + dt;
        fields.*[1][1] += (fields.*[1][1] * (self.zoom_speed * dt)) + dt;
        fields.*[2][2] += (fields.*[2][2] * (self.zoom_speed * dt)) + dt;
        descript.ubo.mark_dirty();
    }
}

pub fn zoomOut(self: *Camera, delta_time: f32) void {
    const dt = delta_time;
    for (self.sync_descs) |*descript| {
        const fields = &descript.*.ubo.uniform_data.view.data;
        fields.*[0][0] -= (fields.*[0][0] * (self.zoom_speed * dt)) + dt;
        fields.*[1][1] -= (fields.*[1][1] * (self.zoom_speed * dt)) + dt;
        fields.*[2][2] -= (fields.*[2][2] * (self.zoom_speed * dt)) + dt;
        descript.ubo.mark_dirty();
    }
}

pub fn translate(self: *Camera, delta_time: f32, dir: Vec2) void {
    const velocity = za.Vec2.scale(za.Vec2.norm(dir), self.move_speed * delta_time);
    for (self.sync_descs) |*descript| {
        const fields = &descript.*.ubo.uniform_data.view.data;
        fields.*[3][0] += velocity[0];
        fields.*[3][1] += velocity[1];
        descript.ubo.mark_dirty();
    }
}

pub fn getPosition(self: Camera) Vec2 {
    // assumption: all sync_descs view matrices are identical ...
    const fields = self.sync_descs[0].ubo.uniform_data.view.fields;
    return za.Vec2.new(fields[3][0], fields[3][1]);
}

pub fn getZoom(self: Camera) Vec2 {
    // assumption: all sync_descs view matrices are identical ...
    const fields = self.sync_descs[0].ubo.uniform_data.view.fields;
    return za.Vec2.new(fields[0][0], fields[1][1]);
}
