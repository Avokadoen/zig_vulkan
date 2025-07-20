/// This file contains logic to perform a simple benchmark report to test the renderer
const std = @import("std");
const za = @import("zalgebra");

const ecez = @import("ecez");
const tracy = @import("ztracy");

const render = @import("../render.zig");

const BrickState = @import("brick/State.zig");
const camera = @import("camera.zig");

const EventArgument = @import("event_arg.zig").EventArgument;

pub const components = struct {
    pub const Benchmark = struct {
        timer: f32,
        path_point_fraction: f32,
        path_orientation_fraction: f32,
    };

    pub const Report = struct {
        sun_enabled: bool,
        brick_dimensions: [3]f32,
        min_delta_time: f32,
        max_delta_time: f32,
        delta_time_sum: f32,
        delta_time_sum_samples: u32,
    };
};

pub const queries = struct {
    // TODO: benchmark should have control over camera if getAny
    //       i.e camera.user_input_diabled is not needed
    pub const Benchmark = ecez.QueryAny(struct {
        entity: ecez.Entity,
        benchmark: *components.Benchmark,
        report: *components.Report,
    }, .{}, .{});
};

pub fn CreateSystems(comptime Storage: type) type {
    return struct {
        pub const sub_storage = struct {
            const Benchmark = Storage.Subset(.{ *components.Benchmark, *components.Report });
        };

        pub const systems = struct {
            /// Update benchmark and camera state, return true if benchmark has completed
            pub fn update(
                ctx: *render.context.queries.PhysicalDeviceProperties,
                benchmark_query: *queries.Benchmark,
                camera_query: *camera.queries.Camera,
                benchmark_storage: *sub_storage.Benchmark,
                event_arg: EventArgument,
            ) void {
                const transfer_zone = tracy.ZoneN(@src(), "sun update");
                defer transfer_zone.End();

                const physical_device_properties = ctx.getAny().?.properties;
                const benchmark_entity = benchmark_query.getAny() orelse return;
                // Camera should always exist
                const camera_entity = camera_query.getAny() orelse unreachable;

                benchmark_entity.benchmark.timer += event_arg.delta_time;

                const path_point_index: usize = @intFromFloat(@divFloor(benchmark_entity.benchmark.timer, benchmark_entity.benchmark.path_point_fraction));
                if (path_point_index < Configuration.path_points.len - 1) {
                    const path_point_lerp_pos = @rem(benchmark_entity.benchmark.timer, benchmark_entity.benchmark.path_point_fraction) / benchmark_entity.benchmark.path_point_fraction;
                    const left = Configuration.path_points[path_point_index];
                    const right = Configuration.path_points[path_point_index + 1];
                    camera_entity.device.origin = left.lerp(right, path_point_lerp_pos).data;
                }

                const path_orientation_index: usize = @intFromFloat(@divFloor(benchmark_entity.benchmark.timer, benchmark_entity.benchmark.path_orientation_fraction));
                if (path_orientation_index < Configuration.path_orientations.len - 1) {
                    const path_orientation_lerp_pos = @rem(benchmark_entity.benchmark.timer, benchmark_entity.benchmark.path_orientation_fraction) / benchmark_entity.benchmark.path_orientation_fraction;
                    const left = Configuration.path_orientations[path_orientation_index];
                    const right = Configuration.path_orientations[path_orientation_index + 1];
                    camera_entity.camera.yaw = left.lerp(right, path_orientation_lerp_pos);
                    camera_entity.camera.pitch = za.Quat.identity();
                }

                camera.propogatePitchChange(camera_entity.camera, camera_entity.device);

                benchmark_entity.report.min_delta_time = @min(benchmark_entity.report.min_delta_time, event_arg.delta_time);
                benchmark_entity.report.max_delta_time = @max(benchmark_entity.report.max_delta_time, event_arg.delta_time);
                benchmark_entity.report.delta_time_sum += event_arg.delta_time;
                benchmark_entity.report.delta_time_sum_samples += 1;

                const print_report = benchmark_entity.benchmark.timer >= Configuration.benchmark_duration;
                if (print_report) {
                    const device_name = physical_device_properties.device_name[0..];
                    const delta_time_sum_samples_f: f32 = @floatFromInt(benchmark_entity.report.delta_time_sum_samples);
                    const average_dt = benchmark_entity.report.delta_time_sum / delta_time_sum_samples_f;

                    const report_fmt = "{s: <25}: {d:>8.3}\n{s: <25}: {d:>8.3}\n{s: <25}: {d:>8.3}\n";
                    const sun_fmt = "{s: <25}: {any}\n";
                    const camera_fmt = "Camera state info:\n{s: <30}: (x = {d}, y = {d})\n{s: <30}: {d}\n{s: <30}: {d}\n";
                    std.log.info("\n{s:-^50}\n{s: <25}: {s}\n" ++ report_fmt ++ "{s: <25}: {any}\n" ++ sun_fmt ++ camera_fmt, .{
                        "BENCHMARK REPORT",
                        "GPU",
                        device_name,
                        "Min frame time",
                        benchmark_entity.report.min_delta_time * std.time.ms_per_s,
                        "Max frame time",
                        benchmark_entity.report.max_delta_time * std.time.ms_per_s,
                        "Avg frame time",
                        average_dt * std.time.ms_per_s,
                        "Brick state info",
                        benchmark_entity.report.brick_dimensions,
                        "Sun enabled",
                        benchmark_entity.report.sun_enabled,
                        " > image dimensions",
                        camera_entity.device.image_width,
                        camera_entity.device.image_height,
                        " > max bounce",
                        camera_entity.device.max_bounce,
                        " > samples per pixel",
                        camera_entity.device.samples_per_pixel,
                    });

                    // benchmark is done, remove components from entity
                    benchmark_storage.unsetComponents(benchmark_entity.entity, .{ components.Benchmark, components.Report });
                }
            }
        };
    };
}

/// Initialize a benchmark by creating the benchmark entity, set camera to inital benchmark state
pub fn createBenchmarkComponents(
    camera_ptr: *camera.components.Camera,
    device_ptr: *camera.components.DeviceCamera,
    brick_dimensions: [3]f32,
    sun_enabled: bool,
) struct {
    benchmark: components.Benchmark,
    report: components.Report,
} {
    const path_point_fraction = Configuration.benchmark_duration / @as(f32, @floatFromInt(Configuration.path_points.len));
    const path_orientation_fraction = Configuration.benchmark_duration / @as(f32, @floatFromInt(Configuration.path_orientations.len));

    // initialize camera state
    camera.disableInput(camera_ptr);
    device_ptr.origin = Configuration.path_points[0].data;

    // HACK: use yaw quat as orientation and ignore pitch
    camera_ptr.yaw = Configuration.path_orientations[0];
    camera_ptr.pitch = za.Quat.identity();
    camera.propogatePitchChange(camera_ptr, device_ptr);

    return .{
        .benchmark = components.Benchmark{
            .timer = 0,
            .path_point_fraction = path_point_fraction,
            .path_orientation_fraction = path_orientation_fraction,
        },
        .report = components.Report{
            .sun_enabled = sun_enabled,
            .min_delta_time = std.math.floatMax(f32),
            .brick_dimensions = brick_dimensions,
            .max_delta_time = 0,
            .delta_time_sum = 0,
            .delta_time_sum_samples = 0,
        },
    };
}

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
