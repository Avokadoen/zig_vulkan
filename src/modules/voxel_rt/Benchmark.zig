/// This file contains logic to perform a simple benchmark report to test the renderer
const std = @import("std");
const za = @import("zalgebra");
const tracy = @import("ztracy");

const BrickState = @import("brick/State.zig");
const Camera = @import("Camera.zig");
const Context = @import("../render.zig").Context;

const Benchmark = @This();

brick_state: BrickState,
sun_enabled: bool,
camera: *Camera,
timer: f32,

path_point_fraction: f32,
path_orientation_fraction: f32,

report: Report,

/// You should probably use VoxelRT.createBenchmark ...
pub fn init(camera: *Camera, brick_state: BrickState, sun_enabled: bool) Benchmark {
    const zone = tracy.ZoneN(@src(), @typeName(Benchmark) ++ " " ++ @src().fn_name);
    defer zone.End();

    const path_point_fraction = Configuration.benchmark_duration / @intToFloat(f32, Configuration.path_points.len);
    const path_orientation_fraction = Configuration.benchmark_duration / @intToFloat(f32, Configuration.path_orientations.len);

    // initialize camera state
    camera.disableInput();
    camera.d_camera.origin = Configuration.path_points[0].data;
    // HACK: use yaw quat as orientation and ignore pitch
    camera.yaw = Configuration.path_orientations[0];
    camera.pitch = za.Quat.identity();
    camera.propogatePitchChange();

    return Benchmark{
        .brick_state = brick_state,
        .sun_enabled = sun_enabled,
        .camera = camera,
        .timer = 0,
        .path_point_fraction = path_point_fraction,
        .path_orientation_fraction = path_orientation_fraction,
        .report = Report.init(brick_state),
    };
}

/// Update benchmark and camera state, return true if benchmark has completed
pub fn update(self: *Benchmark, dt: f32) bool {
    const zone = tracy.ZoneN(@src(), @typeName(Benchmark) ++ " " ++ @src().fn_name);
    defer zone.End();

    self.timer += dt;

    const path_point_index = @floatToInt(usize, @divFloor(self.timer, self.path_point_fraction));
    if (path_point_index < Configuration.path_points.len - 1) {
        const path_point_lerp_pos = @rem(self.timer, self.path_point_fraction) / self.path_point_fraction;
        const left = Configuration.path_points[path_point_index];
        const right = Configuration.path_points[path_point_index + 1];
        self.camera.d_camera.origin = left.lerp(right, path_point_lerp_pos).data;
    }

    const path_orientation_index = @floatToInt(usize, @divFloor(self.timer, self.path_orientation_fraction));
    if (path_orientation_index < Configuration.path_orientations.len - 1) {
        const path_orientation_lerp_pos = @rem(self.timer, self.path_orientation_fraction) / self.path_orientation_fraction;
        const left = Configuration.path_orientations[path_orientation_index];
        const right = Configuration.path_orientations[path_orientation_index + 1];
        self.camera.yaw = left.lerp(right, path_orientation_lerp_pos);
        self.camera.pitch = za.Quat.identity();
    }

    self.camera.propogatePitchChange();

    self.report.min_delta_time = std.math.min(self.report.min_delta_time, dt);
    self.report.max_delta_time = std.math.max(self.report.max_delta_time, dt);
    self.report.delta_time_sum += dt;
    self.report.delta_time_sum_samples += 1;

    return self.timer >= Configuration.benchmark_duration;
}

pub fn printReport(self: Benchmark, device_name: []const u8) void {
    const zone = tracy.ZoneN(@src(), @typeName(Benchmark) ++ " " ++ @src().fn_name);
    defer zone.End();

    self.report.print(device_name, self.camera.d_camera, self.sun_enabled);
}

pub const Report = struct {
    const Vec3U = za.GenericVector(3, u32);

    min_delta_time: f32,
    max_delta_time: f32,

    delta_time_sum: f32,
    delta_time_sum_samples: u32,
    brick_dim: Vec3U,

    pub fn init(brick_state: BrickState) Report {
        const zone = tracy.ZoneN(@src(), @typeName(Report) ++ " " ++ @src().fn_name);
        defer zone.End();

        return Report{
            .min_delta_time = std.math.f32_max,
            .max_delta_time = 0,
            .delta_time_sum = 0,
            .delta_time_sum_samples = 0,
            .brick_dim = Vec3U.new(
                brick_state.device_state.voxel_dim_x,
                brick_state.device_state.voxel_dim_y,
                brick_state.device_state.voxel_dim_z,
            ),
        };
    }

    pub fn average(self: Report) f32 {
        const zone = tracy.ZoneN(@src(), @typeName(Report) ++ " " ++ @src().fn_name);
        defer zone.End();

        return self.delta_time_sum / @intToFloat(f32, self.delta_time_sum_samples);
    }

    pub fn print(self: Report, device_name: []const u8, d_camera: Camera.Device, sun_enabled: bool) void {
        const zone = tracy.ZoneN(@src(), @typeName(Report) ++ " " ++ @src().fn_name);
        defer zone.End();

        const report_fmt = "{s: <25}: {d:>8.3}\n{s: <25}: {d:>8.3}\n{s: <25}: {d:>8.3}\n";
        const sun_fmt = "{s: <25}: {any}\n";
        const camera_fmt = "Camera state info:\n{s: <30}: (x = {d}, y = {d})\n{s: <30}: {d}\n{s: <30}: {d}\n";
        std.log.info("\n{s:-^50}\n{s: <25}: {s}\n" ++ report_fmt ++ "{s: <25}: {any}\n" ++ sun_fmt ++ camera_fmt, .{
            "BENCHMARK REPORT",
            "GPU",
            device_name,
            "Min frame time",
            self.min_delta_time * std.time.ms_per_s,
            "Max frame time",
            self.max_delta_time * std.time.ms_per_s,
            "Avg frame time",
            self.average() * std.time.ms_per_s,
            "Brick state info",
            self.brick_dim.data,
            "Sun enabled",
            sun_enabled,
            " > image dimensions",
            d_camera.image_width,
            d_camera.image_height,
            " > max bounce",
            d_camera.max_bounce,
            " > samples per pixel",
            d_camera.samples_per_pixel,
        });
    }
};

// TODO: these are static for now, but should be configured through a file
// TODO: there should also be gui functionality to record paths and orientations
//       in such a file ...
pub const Configuration = struct {

    // total duration of benchmarks in seconds
    pub const benchmark_duration: f32 = 60;

    pub const path_points = [_]za.Vec3{
        za.Vec3.new(0, 0, 0),
        za.Vec3.new(2, 5, 0),
        za.Vec3.new(3, 5, 5),
        za.Vec3.new(5, 2, 1),
        za.Vec3.new(10, 0, 10),
        za.Vec3.new(20, -20, 20),
        za.Vec3.new(10, -25, 15),
        za.Vec3.new(10, -22, 20),
        za.Vec3.new(10, -30, 25),
        za.Vec3.new(5, -10, 10),
        za.Vec3.new(0, 13, 0),
    };

    pub const path_orientations = [_]za.Quat{
        za.Quat.identity(),
        za.Quat.fromEulerAngles(za.Vec3.new(0, 45, 0)),
        za.Quat.fromEulerAngles(za.Vec3.new(10, -20, 0)),
        za.Quat.fromEulerAngles(za.Vec3.new(20, 180, 0)),
        za.Quat.fromEulerAngles(za.Vec3.new(50, 90, 0)),
        za.Quat.fromEulerAngles(za.Vec3.new(60, 0, 0)),
        za.Quat.fromEulerAngles(za.Vec3.new(80, -10, 0)),
        za.Quat.fromEulerAngles(za.Vec3.new(75, -40, 0)),
        za.Quat.fromEulerAngles(za.Vec3.new(80, -10, 0)),
        za.Quat.fromEulerAngles(za.Vec3.new(80, -90, 0)),
        za.Quat.fromEulerAngles(za.Vec3.new(0, -145, 0)),
    };
};
