const std = @import("std");
const za = @import("zalgebra");
const Vec3 = @Vector(3, f32);

const ecez = @import("ecez");

pub const components = struct {
    pub const Camera = struct {
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

        pub inline fn orientation(self: Camera) za.Quat {
            return self.yaw.mul(self.pitch).norm();
        }

        pub inline fn forwardDir(self: Camera) za.Vec3 {
            return self.orientation().rotateVec(za.Vec3.new(0, 0, 1));
        }

        pub inline fn lowerLeftCorner(self: Camera, device: DeviceCamera) Vec3 {
            const @"0.5": Vec3 = @splat(0.5);
            return device.origin - device.horizontal * @"0.5" - device.vertical * @"0.5" - self.forwardDir().data;
        }
    };

    pub const DeviceCamera = extern struct {
        image_width: u32,
        image_height: u32,
        horizontal: Vec3,
        vertical: Vec3,
        lower_left_corner: Vec3,
        origin: Vec3,
        samples_per_pixel: i32,
        max_bounce: i32,
    };
};

pub const queries = struct {
    pub const Camera = ecez.QueryAny(struct {
        camera: *components.Camera,
        device: *components.DeviceCamera,
    }, .{}, .{});
};

pub const Config = struct {
    viewport_height: f32 = 2,
    origin: Vec3 = za.Vec3.zero().data,
    samples_per_pixel: i32 = 2,
    max_bounce: i32 = 2,
    turn_rate: f32 = 0.1,
    normal_speed: f32 = 1,
    sprint_speed: f32 = 2,
    user_input_diabled: bool = false,
};
pub fn createCameraComponents(vertical_fov: f32, image_width: u32, image_height: u32, config: Config) struct {
    camera: components.Camera,
    device: components.DeviceCamera,
} {
    const aspect_ratio: f32 = @as(f32, @floatFromInt(image_width)) / @as(f32, @floatFromInt(image_height));

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

    return .{
        .camera = components.Camera{
            .turn_rate = config.turn_rate,
            .normal_speed = config.normal_speed,
            .sprint_speed = config.sprint_speed,
            .movement_speed = config.normal_speed,
            .user_input_diabled = config.user_input_diabled,
            .viewport_width = viewport_width,
            .viewport_height = viewport_height,
            .pitch = za.Quat.identity(),
            .yaw = za.Quat.identity(),
        },
        .device = components.DeviceCamera{
            .image_width = image_width,
            .image_height = image_height,
            .horizontal = horizontal.data,
            .vertical = vertical.data,
            .lower_left_corner = lower_left_corner,
            .origin = config.origin,
            .samples_per_pixel = config.samples_per_pixel,
            .max_bounce = config.max_bounce + 1, // + 1 so that max bounce of 0 means only primary ray for the user of API ...
        },
    };
}

/// set camera movement speed to sprint
pub fn activateSprint(camera_ptr: *components.Camera) void {
    camera_ptr.movement_speed = camera_ptr.normal_speed * camera_ptr.sprint_speed;
}

/// set camera movement speed to normal speed
pub fn disableSprint(camera_ptr: *components.Camera) void {
    camera_ptr.movement_speed = camera_ptr.normal_speed;
}

pub fn setOrigin(camera_ptr: *components.Camera, device_ptr: *components.DeviceCamera, origin: Vec3) void {
    device_ptr.origin = origin;
    propogatePitchChange(camera_ptr, device_ptr);
}

pub fn disableInput(camera_ptr: *components.Camera) void {
    camera_ptr.user_input_diabled = true;
}

/// camera should always be reset after being used
/// programtically to avoid invalid camera state
pub fn reset(camera_ptr: *components.Camera, device_ptr: *components.DeviceCamera) void {
    camera_ptr.user_input_diabled = false;
    camera_ptr.yaw = za.Quat.identity();
    camera_ptr.pitch = za.Quat.identity();

    propogatePitchChange(camera_ptr, device_ptr);
}

/// Move camera
pub fn translate(camera_ptr: *components.Camera, device_ptr: *components.DeviceCamera, delta_time: f32, by: za.Vec3) void {
    if (camera_ptr.user_input_diabled) return;

    const norm = by.norm();
    const delta = camera_ptr.orientation().rotateVec(norm.scale(delta_time * camera_ptr.movement_speed));
    if (std.math.isNan(delta.x() + delta.y() + delta.z())) {
        return;
    }
    device_ptr.origin += delta.data;

    propogatePitchChange(camera_ptr, device_ptr);
}

pub fn turnPitch(camera_ptr: *components.Camera, device_ptr: *components.DeviceCamera, angle: f32) void {
    if (camera_ptr.user_input_diabled) return;

    // Axis angle to quaternion: https://www.euclideanspace.com/maths/geometry/rotations/conversions/angleToQuaternion/index.htm
    const h_angle = angle * camera_ptr.turn_rate;
    const i = @sin(h_angle);
    const w = @cos(h_angle);
    const prev_pitch = camera_ptr.pitch;
    camera_ptr.pitch = camera_ptr.pitch.mul(za.Quat{ .w = w, .x = i, .y = 0.0, .z = 0.0 });

    // arbitrary restrict rotation so that camera does not become inversed
    const euler_x_rotation = camera_ptr.pitch.extractEulerAngles().x();
    if (@abs(euler_x_rotation) >= 90) {
        camera_ptr.pitch = prev_pitch;
    }

    propogatePitchChange(camera_ptr, device_ptr);
}

pub fn turnYaw(camera_ptr: *components.Camera, device_ptr: *components.DeviceCamera, angle: f32) void {
    if (camera_ptr.user_input_diabled) return;

    const h_angle = angle * camera_ptr.turn_rate;
    const j = @sin(h_angle);
    const w = @cos(h_angle);
    camera_ptr.yaw = camera_ptr.yaw.mul(za.Quat{ .w = w, .x = 0.0, .y = j, .z = 0.0 });

    propogatePitchChange(camera_ptr, device_ptr);
}

// used to update values that depend on camera orientation
pub inline fn propogatePitchChange(camera_ptr: *components.Camera, device_ptr: *components.DeviceCamera) void {
    const forward = camera_ptr.forwardDir();
    const right = za.Vec3.up().cross(forward).norm();
    const up = forward.cross(right).norm();

    device_ptr.horizontal = right.scale(camera_ptr.viewport_width).data;
    device_ptr.vertical = up.scale(camera_ptr.viewport_height).data;
    device_ptr.lower_left_corner = camera_ptr.lowerLeftCorner(device_ptr.*);
}
