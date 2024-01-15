const std = @import("std");
const za = @import("zalgebra");
const tracy = @import("ztracy");
const Vec3 = @Vector(3, f32);

pub const Config = struct {
    viewport_height: f32 = 2,
    origin: Vec3 = za.Vec3.zero().data,
    samples_per_pixel: u32 = 1,
    max_ray_bounce: u32 = 0,
    turn_rate: f32 = 0.1,
    normal_speed: f32 = 1,
    sprint_speed: f32 = 2,
    user_input_diabled: bool = false,
};

const Camera = @This();

turn_rate: f32,

normal_speed: f32,
sprint_speed: f32,
movement_speed: f32,

user_input_diabled: bool,

/// changes to viewport_x should call propogatePitchChange
viewport_width: f32,
viewport_height: f32,

pitch: za.Quat,
yaw: za.Quat,

vertical_fov: f32,

max_ray_bounces: i32,
samples_per_pixel: i32,
d_camera: Device,

pub fn init(vertical_fov: f32, image_width: u32, image_height: u32, config: Config) Camera {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    const aspect_ratio = @as(f32, @floatFromInt(image_width)) / @as(f32, @floatFromInt(image_height));

    const a: comptime_float = std.math.pi * (1.0 / 180.0);
    const viewport_height = blk: {
        const theta = vertical_fov * a;
        const height = config.viewport_height;
        break :blk height * @tan(theta * 0.5);
    };
    const viewport_width = aspect_ratio * viewport_height;

    const forward = za.Vec3.forward();
    const right = za.Vec3.up().cross(forward).norm();
    const up = forward.cross(right).norm();

    const horizontal = right.scale(viewport_width);
    const vertical = up.scale(viewport_height);
    const lower_left_corner = config.origin - horizontal.scale(0.5).data - vertical.scale(0.5).data - forward.data;

    return Camera{
        .turn_rate = config.turn_rate,
        .normal_speed = config.normal_speed,
        .sprint_speed = config.sprint_speed,
        .movement_speed = config.normal_speed,
        .user_input_diabled = config.user_input_diabled,
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .pitch = za.Quat.identity(),
        .yaw = za.Quat.identity(),
        .vertical_fov = vertical_fov,
        .max_ray_bounces = @intCast(config.max_ray_bounce),
        .samples_per_pixel = @intCast(config.samples_per_pixel),
        .d_camera = Device{
            .image_width = image_width,
            .image_height = image_height,
            .horizontal = horizontal.data,
            .vertical = vertical.data,
            .lower_left_corner = lower_left_corner,
            .current_sample = 0,
            .origin = config.origin,
        },
    };
}

/// set camera movement speed to sprint
pub fn activateSprint(self: *Camera) void {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    self.movement_speed = self.normal_speed * self.sprint_speed;
}

/// set camera movement speed to normal speed
pub fn disableSprint(self: *Camera) void {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    self.movement_speed = self.normal_speed;
}

pub fn setOrigin(self: *Camera, origin: Vec3) void {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    self.d_camera.origin = origin;
    self.propogatePitchChange();
}

pub fn disableInput(self: *Camera) void {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    self.user_input_diabled = true;
}

pub fn enableInput(self: *Camera) void {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    self.user_input_diabled = false;
}

/// camera should always be reset after being used
/// programtically to avoid invalid camera state
pub fn reset(self: *Camera) void {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    self.enableInput();
    self.yaw = za.Quat.identity();
    self.pitch = za.Quat.identity();
    self.propogatePitchChange();
}

/// Move camera
pub fn translate(self: *Camera, delta_time: f32, by: za.Vec3) void {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (self.user_input_diabled) return;

    const norm = by.norm();
    const delta = self.orientation().rotateVec(norm.scale(delta_time * self.movement_speed));
    if (std.math.isNan(delta.x())) {
        return;
    }
    self.d_camera.origin += delta.data;
    self.propogatePitchChange();
}

pub fn turnPitch(self: *Camera, angle: f32) void {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (self.user_input_diabled) return;

    // Axis angle to quaternion: https://www.euclideanspace.com/maths/geometry/rotations/conversions/angleToQuaternion/index.htm
    const h_angle = angle * self.turn_rate;
    const i = @sin(h_angle);
    const w = @cos(h_angle);
    const prev_pitch = self.pitch;
    self.pitch = self.pitch.mul(za.Quat{ .w = w, .x = i, .y = 0.0, .z = 0.0 });

    // arbitrary restrict rotation so that camera does not become inversed
    const euler_x_rotation = self.pitch.extractEulerAngles().x();
    if (@abs(euler_x_rotation) >= 90) {
        self.pitch = prev_pitch;
    }

    self.propogatePitchChange();
}

pub fn turnYaw(self: *Camera, angle: f32) void {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (self.user_input_diabled) return;

    const h_angle = angle * self.turn_rate;
    const j = @sin(h_angle);
    const w = @cos(h_angle);
    self.yaw = self.yaw.mul(za.Quat{ .w = w, .x = 0.0, .y = j, .z = 0.0 });
    self.propogatePitchChange();
}

pub inline fn orientation(self: Camera) za.Quat {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    return self.yaw.mul(self.pitch).norm();
}

inline fn forwardDir(self: Camera) za.Vec3 {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    return self.orientation().rotateVec(za.Vec3.new(0, 0, 1));
}

// used to update values that depend on camera orientation
pub inline fn propogatePitchChange(self: *Camera) void {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    const forward = self.forwardDir();
    const right = za.Vec3.up().cross(forward).norm();
    const up = forward.cross(right).norm();

    self.d_camera.horizontal = right.scale(self.viewport_width).data;
    self.d_camera.vertical = up.scale(self.viewport_height).data;
    self.d_camera.lower_left_corner = self.lowerLeftCorner();
}

inline fn lowerLeftCorner(self: Camera) Vec3 {
    const zone = tracy.ZoneN(@src(), @typeName(Camera) ++ " " ++ @src().fn_name);
    defer zone.End();

    const @"0.5": @Vector(3, f32) = @splat(@as(f32, 0.5));
    return self.d_camera.origin - self.d_camera.horizontal * @"0.5" - self.d_camera.vertical * @"0.5" - self.forwardDir().data;
}

pub inline fn totalRayCount(self: Camera) u64 {
    return self.rayCountPerSampleIter() * @as(u64, @intCast(self.samples_per_pixel));
}

pub inline fn rayCountPerSampleIter(self: Camera) u64 {
    const pixel_count: u64 = @intCast(self.d_camera.image_width * self.d_camera.image_height);
    return pixel_count;
}

// uniform Camera, binding: 1
pub const Device = extern struct {
    horizontal: [3]f32,
    image_width: c_uint,
    vertical: [3]f32,
    image_height: c_uint,
    lower_left_corner: [3]f32,
    current_sample: c_uint,
    origin: [3]f32,
};
