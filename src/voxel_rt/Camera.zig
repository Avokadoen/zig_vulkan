const std = @import("std");
const za = @import("zalgebra");
const Vec3 = @Vector(3, f32);

const default_viewport_height = 2;
const default_samples_per_pixel = 4;
const default_turn_rate = 0.8;
const default_normal_speed = 1;
// how much to multiply normal speed in the event sprint is missing
const default_sprint_scale = 2;
const default_origin = za.Vec3.zero();
const default_max_bounce = 4;

pub const Config = struct {
    viewport_height: ?f32 = null,
    origin: ?Vec3 = null,
    samples_per_pixel: ?i32 = null,
    max_bounce: ?i32 = null,
    turn_rate: ?f32 = null,
    normal_speed: ?f32 = null,
    sprint_speed: ?f32 = null,
};

const Camera = @This();

turn_rate: f32,

normal_speed: f32,
sprint_speed: f32,
movement_speed: f32,

/// changes to viewport_x should call propogatePitchChange
viewport_width: f32,
viewport_height: f32,

pitch: za.Quat,
yaw: za.Quat,

vertical_fov: f32,
d_camera: Device,

/// Do not use this function
/// Exist purely to highlight the Camera.Builder
pub fn init(vertical_fov: f32, image_width: u32, image_height: u32, config: Config) Camera {
    const math = std.math;

    const aspect_ratio = @intToFloat(f32, image_width) / @intToFloat(f32, image_height);

    const inv_180: comptime_float = comptime blk: {
        break :blk 1.0 / 180.0;
    };

    const viewport_height = blk: {
        const theta = vertical_fov * math.pi * inv_180;
        const height = config.viewport_height orelse default_viewport_height;
        break :blk height * math.tan(theta * 0.5);
    };
    const viewport_width = aspect_ratio * viewport_height;
    const o = config.origin orelse default_origin;

    const forward = za.Vec3.forward();
    const right = za.Vec3.norm(za.Vec3.cross(za.Vec3.up(), forward));
    const up = za.Vec3.norm(za.Vec3.cross(forward, right));

    const horizontal = za.Vec3.scale(right, viewport_width);
    const vertical = za.Vec3.scale(up, viewport_height);

    const lower_left_corner = o - za.Vec3.scale(horizontal, 0.5) - za.Vec3.scale(vertical, 0.5) - forward;

    // TODO: Camera own texture ...
    // const render_texture = ;

    const normal_speed = config.normal_speed orelse default_normal_speed;
    return Camera{
        .turn_rate = config.turn_rate orelse default_turn_rate,
        .normal_speed = normal_speed,
        .sprint_speed = config.sprint_speed orelse normal_speed * default_sprint_scale,
        .movement_speed = normal_speed,
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .vertical_fov = vertical_fov,
        .pitch = za.Quat.zero(), // (1, 0, 0, 0)
        .yaw = za.Quat.zero(),
        .d_camera = Device{
            .image_width = image_width,
            .image_height = image_height,
            .horizontal = horizontal,
            .vertical = vertical,
            .lower_left_corner = lower_left_corner,
            .origin = o,
            .samples_per_pixel = config.samples_per_pixel orelse default_samples_per_pixel,
            .max_bounce = config.max_bounce orelse default_max_bounce,
        },
    };
}

/// set camera movement speed to sprint
pub fn activateSprint(self: *Camera) void {
    self.movement_speed = self.normal_speed * self.sprint_speed;
}

/// set camera movement speed to sprint
pub fn disableSprint(self: *Camera) void {
    self.movement_speed = self.normal_speed;
}

/// Move camera
pub fn translate(self: *Camera, delta_time: f32, by: Vec3) void {
    const norm = za.Vec3.norm(by);
    const delta = self.orientation().rotateVec(za.Vec3.scale(norm, delta_time * self.movement_speed));
    if (std.math.isNan(delta[0])) {
        return;
    }
    self.d_camera.origin += delta;
    self.propogatePitchChange();
}

pub fn turnPitch(self: *Camera, angle: f32) void {
    // Axis angle to quaternion: https://www.euclideanspace.com/maths/geometry/rotations/conversions/angleToQuaternion/index.htm
    const h_angle = angle * self.turn_rate;
    const i = std.math.sin(h_angle);
    const w = std.math.cos(h_angle);
    self.pitch = self.pitch.mult(za.Quat{ .w = w, .x = i, .y = 0.0, .z = 0.0 });
    self.propogatePitchChange();
}

pub fn turnYaw(self: *Camera, angle: f32) void {
    const h_angle = angle * self.turn_rate;
    const j = std.math.sin(h_angle);
    const w = std.math.cos(h_angle);
    self.yaw = self.yaw.mult(za.Quat{ .w = w, .x = 0.0, .y = j, .z = 0.0 });
    self.propogatePitchChange();
}

pub inline fn orientation(self: Camera) za.Quat {
    return self.yaw.mult(self.pitch).norm();
}

/// Get byte size of Camera's GPU data 
pub inline fn getGpuSize() u64 {
    return @sizeOf(Device);
}

inline fn forwardDir(self: Camera) Vec3 {
    return za.Vec3.norm(self.orientation().rotateVec(za.Vec3.new(0, 0, 1)));
}

inline fn propogatePitchChange(self: *Camera) void {
    const forward = self.forwardDir();
    const right = za.Vec3.norm(za.Vec3.cross(za.Vec3.up(), forward));
    const up = za.Vec3.norm(za.Vec3.cross(forward, right));

    self.d_camera.horizontal = za.Vec3.scale(right, self.viewport_width);
    self.d_camera.vertical = za.Vec3.scale(up, self.viewport_height);
    self.d_camera.lower_left_corner = self.lowerLeftCorner();
}

inline fn lowerLeftCorner(self: Camera) Vec3 {
    return self.d_camera.origin - za.Vec3.scale(self.d_camera.horizontal, 0.5) - za.Vec3.scale(self.d_camera.vertical, 0.5) - self.forwardDir();
}

// uniform Camera, binding: 1
pub const Device = extern struct {
    image_width: u32,
    image_height: u32,

    horizontal: Vec3,
    vertical: Vec3,
    lower_left_corner: Vec3,
    origin: Vec3,
    samples_per_pixel: i32,
    max_bounce: i32,
};
