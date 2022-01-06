const std = @import("std");
const za = @import("zalgebra");

const Camera = @This();

samples_per_pixel: i32,
max_bounce: i32,
turn_rate: f32,

normal_speed: f32,
sprint_speed: f32,
movement_speed: f32,

viewport_width: f32,
viewport_height: f32,

pitch: za.Quat,
yaw: za.Quat,

vertical_fov: f32,
gpu_state: GpuState,

/// Do not use this function
/// Exist purely to highlight the Camera.Builder
pub fn init() Camera {
    @compileError("Camera.init() is not supported, use Camera.Builder.init()");
}

/// Get byte size of Camera's GPU data 
pub inline fn getGpuSize() u64 {
    return @sizeOf(GpuState);
}

/// Builder for the Camera struct
pub const Builder = struct {
    const default_samples_per_pixel = 4;
    const default_max_bounce = 3;
    const default_turn_rate = 0.025;
    const default_normal_speed = 1;
    // how much to multiply normal speed in the event sprint is missing
    const default_sprint_scale = 2;
    const default_origin = za.Vec3.zero();

    vertical_fov: f32,
    image_height: i32,
    image_width: i32,
    aspect_ratio: ?f32,
    viewport_height: ?f32,
    origin: ?za.Vec3,
    samples_per_pixel: ?i32,
    max_bounce: ?i32,
    turn_rate: ?f32,
    normal_speed: ?f32,
    sprint_speed: ?f32,

    /// init a Camera.Builder
    pub fn init(vertical_fov: f32, image_width: i32, image_height: i32) Builder {
        return .{
            .vertical_fov = vertical_fov,
            .image_width = image_width,
            .image_height = image_height,
            .aspect_ratio = null,
            .viewport_height = null,
            .origin = null,
            .samples_per_pixel = null,
            .max_bounce = null,
            .turn_rate = null,
            .normal_speed = null,
            .sprint_speed = null,
        };
    }

    // TODO: pointer to camera gpu buffer?
    /// build a camera structu with configured values and default values for the rest
    pub fn build(self: Builder) !Camera {
        const math = std.math;

        const aspect_ratio = self.image_width / self.image_height;

        const inv_180 = comptime blk: {
            break :blk 1 / 180;
        };

        const viewport_height = blk: {
            const theta = self.vertical_fov * math.pi * inv_180;
            const height = self.viewport_height orelse 2;
            break :blk height * math.tan(theta * 0.5);
        };
        const viewport_width = aspect_ratio * viewport_height;
        const origin = self.origin orelse za.Vec3.zero;

        const forward = za.Vec3.forward();
        const right = za.Vec3.norm(za.Vec3.cross(za.Vec3.up(), forward));
        const up = za.Vec3.norm(za.Vec3.cross(forward, right));

        const horizontal = right * viewport_width;
        const vertical = up * viewport_height;

        const lower_left_corner = origin - horizontal * 0.5 - vertical * 0.5 - forward;

        // TODO: Camera own texture ...
        // const render_texture = ;

        const normal_speed = self.normal_speed orelse default_normal_speed;
        return Camera{
            .turn_rate = self.turn_rate orelse default_turn_rate,
            .normal_speed = normal_speed,
            .sprint_speed = self.sprint_speed orelse normal_speed * default_sprint_scale,
            .movement_speed = normal_speed,
            .viewport_width = viewport_width,
            .viewport_height = viewport_height,
            .vertical_fov = self.vertical_fov,
            .pitch = za.Quat.zero(), // (1, 0, 0, 0)
            .yap = za.Quat.zero(),
            .gpu_state = GpuState{
                .image_width = self.image_width,
                .image_height = self.image_height,
                .horizontal = horizontal,
                .vertical = vertical,
                .lower_left_corner = lower_left_corner,
                .origin = self.origin orelse default_origin,
                .samples_per_pixel = self.sample_per_pixel orelse default_samples_per_pixel,
                .max_bounce = self.max_bounce orelse default_max_bounce,
            },
        };
    }
};

// uniform Camera, binding: 1
const GpuState = extern struct {
    image_width: i32,
    image_height: i32,

    horizontal: za.Vec3,
    vertical: za.Vec3,

    lower_left_corner: za.Vec3,
    origin: za.Vec3,

    samples_per_pixel: i32,
    max_bounce: i32,
};
