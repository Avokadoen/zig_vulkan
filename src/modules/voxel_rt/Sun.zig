const za = @import("zalgebra");
const math = @import("std").math;

const tracy = @import("ztracy");

pub const Config = struct {
    animate: bool = true,
    animate_speed: f32 = 0.1,
    enabled: bool = true,
    color: [3]f32 = [_]f32{ 1, 1.1, 1 },
    radius: f32 = 5,
    sun_distance: f32 = 1000,
};

pub const Device = extern struct {
    position: [3]f32,
    enabled: u32,
    color: [3]f32,
    radius: f32,
};

const Sun = @This();

device_data: Device,

animate: bool,
animate_speed: f32,

slerp_index: usize,
slerp_pos: f32,
// used to rotate sun around grid
slerp_orientations: [3]za.Quat,
lerp_color: [3]za.Vec3,

static_pos_vec: za.Vec3,

pub fn init(config: Config) Sun {
    const zone = tracy.ZoneN(@src(), @typeName(Sun) ++ " " ++ @src().fn_name);
    defer zone.End();

    const slerp_orientations = [_]za.Quat{
        za.Quat.fromEulerAngles(za.Vec3.new(0, 0, 0)),
        za.Quat.fromEulerAngles(za.Vec3.new(0, 10, 120)),
        za.Quat.fromEulerAngles(za.Vec3.new(0, 0, 240)),
    };
    const static_pos_vec = za.Vec3.new(0, -config.sun_distance, 0);
    const lerp_color = [_]za.Vec3{
        za.Vec3.new(1, 0.99, 0.823),
        za.Vec3.new(0.9, 0.45, 0.45),
        za.Vec3.new(1, 0.7569, 0.5412),
    };

    return Sun{
        .device_data = .{
            .enabled = @as(u32, @intCast(@intFromBool(config.enabled))),
            .position = static_pos_vec.data,
            .color = config.color,
            .radius = config.radius,
        },
        .animate = config.animate,
        .animate_speed = config.animate_speed,
        .slerp_index = 0,
        .slerp_pos = 0,
        .slerp_orientations = slerp_orientations,
        .static_pos_vec = static_pos_vec,
        .lerp_color = lerp_color,
    };
}

pub inline fn update(self: *Sun, delta_time: f32) void {
    const zone = tracy.ZoneN(@src(), @typeName(Sun) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (self.animate == false or self.device_data.enabled == 0) return;

    const next_index = (self.slerp_index + 1) % self.slerp_orientations.len;
    {
        const quat_a = self.slerp_orientations[self.slerp_index];
        const quat_b = self.slerp_orientations[next_index];
        self.device_data.position = quat_a.slerp(quat_b, self.slerp_pos).rotateVec(self.static_pos_vec).data;
    }

    {
        const color_a = self.lerp_color[self.slerp_index];
        const color_b = self.lerp_color[next_index];
        self.device_data.color = color_a.lerp(color_b, self.slerp_pos).data;
    }

    self.slerp_pos += self.animate_speed * delta_time;
    if (self.slerp_pos > 1) {
        self.slerp_pos = math.modf(self.slerp_pos).fpart;
        self.slerp_index = next_index;
    }
}
