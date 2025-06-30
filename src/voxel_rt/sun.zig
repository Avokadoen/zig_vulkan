const za = @import("zalgebra");
const math = @import("std").math;

const ecez = @import("ecez");

pub const components = struct {
    pub const Sun = struct {
        animate: bool,
        animate_speed: f32,
        slerp_index: usize,
        slerp_pos: f32,
        // used to rotate sun around grid
        slerp_orientations: [3]za.Quat,
        lerp_color: [3]za.Vec3,
        static_pos_vec: za.Vec3,
    };

    pub const DeviceSun = extern struct {
        position: [3]f32,
        enabled: u32,
        color: [3]f32,
        radius: f32,
    };
};

pub const Config = struct {
    animate: bool = true,
    animate_speed: f32 = 0.1,
    enabled: bool = true,
    color: [3]f32 = [_]f32{ 1, 1.1, 1 },
    radius: f32 = 5,
    sun_distance: f32 = 1000,
};
pub fn createSunComponents(config: Config) struct {
    sun: components.Sun,
    device: components.DeviceSun,
} {
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

    return .{
        .sun = components.Sun{
            .animate = config.animate,
            .animate_speed = config.animate_speed,
            .slerp_index = 0,
            .slerp_pos = 0,
            .slerp_orientations = slerp_orientations,
            .static_pos_vec = static_pos_vec,
            .lerp_color = lerp_color,
        },
        .device = components.DeviceSun{
            .enabled = @intCast(@intFromBool(config.enabled)),
            .position = static_pos_vec.data,
            .color = config.color,
            .radius = config.radius,
        },
    };
}

// TODO: this should be a system
pub inline fn update(sun_entity: ecez.Entity, storage: anytype, delta_time: f32) void {
    const sun = storage.getComponent(sun_entity, *components.Sun) catch unreachable;
    const device_sun = storage.getComponent(sun_entity, *components.DeviceSun) catch unreachable;

    if (sun.animate == false or device_sun.enabled == 0) return;

    const next_index = (sun.slerp_index + 1) % sun.slerp_orientations.len;
    {
        const quat_a = sun.slerp_orientations[sun.slerp_index];
        const quat_b = sun.slerp_orientations[next_index];
        device_sun.position = quat_a.slerp(quat_b, sun.slerp_pos).rotateVec(sun.static_pos_vec).data;
    }

    {
        const color_a = sun.lerp_color[sun.slerp_index];
        const color_b = sun.lerp_color[next_index];
        device_sun.color = color_a.lerp(color_b, sun.slerp_pos).data;
    }

    sun.slerp_pos += sun.animate_speed * delta_time;
    if (sun.slerp_pos > 1) {
        sun.slerp_pos = math.modf(sun.slerp_pos).fpart;
        sun.slerp_index = next_index;
    }
}
