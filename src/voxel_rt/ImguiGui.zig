const std = @import("std");

const zgui = @import("zgui");
const vk = @import("vulkan");

const ecez = @import("ecez");

const render = @import("../render.zig");
const Context = render.Context;

const camera = @import("camera.zig");
const sun = @import("sun.zig");
const brick_state = @import("brick/state.zig");
const Pipeline = @import("Pipeline.zig");
const GraphicsPipeline = @import("GraphicsPipeline.zig");
const benchmark = @import("benchmark.zig");

pub const StateBinding = struct {
    /// used in benchmark report
    grid_device: brick_state.components.Device,
    gfx_pipeline_shader_constants: *GraphicsPipeline.PushConstant,
};

const MetricState = struct {
    update_frame_timings: bool,
    frame_times: [128]f32,
    min_frame_time: f32,
    max_frame_time: f32,
};

// build voxel_rt gui for the ImguiPipeline and handle state propagation
const ImguiGui = @This();

state_binding: StateBinding,

camera_window_active: bool,
metrics_window_active: bool,
post_process_window_active: bool,
sun_window_active: bool,

metrics_state: MetricState,

benchmark_entity: ecez.Entity,

pub const Config = struct {
    camera_window_active: bool = true,
    metrics_window_active: bool = true,
    post_process_window_active: bool = true,
    sun_window_active: bool = true,
    update_frame_timings: bool = true,
};
pub fn init(gui_width: f32, gui_height: f32, storage: anytype, state_binding: StateBinding, config: Config) error{OutOfMemory}!ImguiGui {
    // Color scheme
    const StyleCol = zgui.StyleCol;
    const style = zgui.getStyle();
    style.setColor(StyleCol.title_bg, [4]f32{ 0.1, 0.1, 0.1, 0.85 });
    style.setColor(StyleCol.title_bg_active, [4]f32{ 0.15, 0.15, 0.15, 0.9 });
    style.setColor(StyleCol.menu_bar_bg, [4]f32{ 0.1, 0.1, 0.1, 0.8 });
    style.setColor(StyleCol.header, [4]f32{ 0.1, 0.1, 0.1, 0.8 });
    style.setColor(StyleCol.check_mark, [4]f32{ 0, 1, 0, 1 });

    // Dimensions
    zgui.io.setDisplaySize(gui_width, gui_height);
    zgui.io.setDisplayFramebufferScale(1.0, 1.0);

    const benchmark_entity = try storage.createEntity(.{});

    return ImguiGui{
        .state_binding = state_binding,
        .camera_window_active = config.camera_window_active,
        .metrics_window_active = config.metrics_window_active,
        .post_process_window_active = config.post_process_window_active,
        .sun_window_active = config.sun_window_active,
        .metrics_state = .{
            .update_frame_timings = config.update_frame_timings,
            .frame_times = [_]f32{0} ** 128,
            .min_frame_time = std.math.floatMax(f32),
            .max_frame_time = std.math.floatMin(f32),
        },
        .benchmark_entity = benchmark_entity,
    };
}

/// handle window resizing
pub fn handleRescale(self: ImguiGui, gui_width: f32, gui_height: f32) void {
    _ = self;

    zgui.io.setDisplaySize(gui_width, gui_height);
}

// Starts a new imGui frame and sets up windows and ui elements
pub fn newFrame(
    self: *ImguiGui,
    ctx: Context,
    storage: anytype,
    pipeline: *Pipeline,
    camera_ptr: *camera.components.Camera,
    device_camera: *camera.components.DeviceCamera,
    sun_ptr: *sun.components.Sun,
    device_sun: *sun.components.DeviceSun,
    update_metrics: bool,
    dt: f32,
) !void {
    zgui.newFrame();

    const style = zgui.getStyle();
    const rounding = style.window_rounding;
    style.window_rounding = 0; // no rounding for top menu

    zgui.setNextWindowSize(
        .{
            .w = @floatFromInt(pipeline.swapchain.extent.width),
            .h = 0,
            .cond = .always,
        },
    );
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    _ = zgui.begin("Main menu", .{ .flags = .{
        .menu_bar = true,
        .no_move = true,
        .no_resize = true,
        .no_title_bar = true,
        .no_scrollbar = true,
        .no_scroll_with_mouse = true,
        .no_collapse = true,
        .no_background = true,
    } });
    style.window_rounding = rounding;

    blk: {
        if (zgui.beginMenuBar() == false) break :blk;
        defer zgui.endMenuBar();

        if (zgui.beginMenu("Windows", true) == false) break :blk;
        defer zgui.endMenu();

        if (zgui.menuItem("Camera", .{ .selected = self.camera_window_active, .enabled = true })) {
            self.camera_window_active = !self.camera_window_active;
        }
        if (zgui.menuItem("Metrics", .{ .selected = self.metrics_window_active, .enabled = true })) {
            self.metrics_window_active = !self.metrics_window_active;
        }
        if (zgui.menuItem("Post process", .{ .selected = self.post_process_window_active, .enabled = true })) {
            self.post_process_window_active = !self.post_process_window_active;
        }
        if (zgui.menuItem("Sun", .{ .selected = self.sun_window_active, .enabled = true })) {
            self.sun_window_active = !self.sun_window_active;
        }
    }
    zgui.end();

    blk: {
        if (!self.metrics_state.update_frame_timings or !update_metrics) {
            break :blk;
        }
        std.mem.rotate(f32, self.metrics_state.frame_times[0..], 1);
        const frame_time = dt * std.time.ms_per_s;
        self.metrics_state.frame_times[self.metrics_state.frame_times.len - 1] = frame_time;
        self.metrics_state.min_frame_time = @min(self.metrics_state.min_frame_time, frame_time);
        self.metrics_state.max_frame_time = @max(self.metrics_state.max_frame_time, frame_time);
    }

    self.drawCameraWindowIfEnabled(camera_ptr, device_camera);
    try self.drawMetricsWindowIfEnabled(ctx, storage, camera_ptr, device_camera, sun_ptr, device_sun);
    self.drawPostProcessWindowIfEnabled();
    self.drawPostSunWindowIfEnabled(sun_ptr, device_sun);

    // imgui.igSetNextWindowPos(.{ .x = 650, .y = 20 }, imgui.ImGuiCond_FirstUseEver, .{ .x = 0, .y = 0 });
    // imgui.igShowDemoWindow(null);

    zgui.render();
}

fn drawCameraWindowIfEnabled(self: *ImguiGui, camera_ptr: *camera.components.Camera, device_camera: *camera.components.DeviceCamera) void {
    if (self.camera_window_active == false) return;

    zgui.setNextWindowSize(.{
        .w = 400,
        .h = 500,
        .cond = .first_use_ever,
    });
    const camera_open = zgui.begin("Camera", .{ .popen = &self.camera_window_active });
    defer zgui.end();
    if (camera_open == false) return;

    _ = zgui.sliderInt("max bounces", .{
        .v = &device_camera.max_bounce,
        .min = 1,
        .max = 32,
    });
    imguiToolTip("how many times a ray is allowed to bounce before terminating", .{});
    _ = zgui.sliderInt("samples per pixel", .{
        .v = &device_camera.samples_per_pixel,
        .min = 1,
        .max = 32,
    });
    imguiToolTip("how many rays per pixel", .{});

    _ = zgui.inputFloat("move speed", .{
        .v = &camera_ptr.normal_speed,
    });
    _ = zgui.inputFloat("turn rate", .{
        .v = &camera_ptr.turn_rate,
    });

    var camera_origin: [3]f32 = [_]f32{ 0, 0, 0 }; // self.state_binding.camera_ptr.d_camera.origin; // TODO
    const camera_origin_changed = zgui.inputFloat3("position", .{ .v = &camera_origin });
    if (camera_origin_changed) {
        camera.setOrigin(camera_ptr, device_camera, camera_origin);
    }
}

fn drawMetricsWindowIfEnabled(
    self: *ImguiGui,
    ctx: Context,
    storage: anytype,
    camera_ptr: *camera.components.Camera,
    device_camera: *camera.components.DeviceCamera,
    sun_ptr: *sun.components.Sun,
    device_sun: *sun.components.DeviceSun,
) error{OutOfMemory}!void {
    if (self.metrics_window_active == false) return;

    zgui.setNextWindowSize(.{
        .w = 400,
        .h = 500,
        .cond = .first_use_ever,
    });
    const metrics_open = zgui.begin("Metrics", .{ .popen = &self.metrics_window_active });
    defer zgui.end();
    if (metrics_open == false) return;

    const zero_index = std.mem.indexOf(u8, &ctx.physical_device_properties.device_name, &[_]u8{0});
    zgui.textUnformatted(ctx.physical_device_properties.device_name[0..zero_index.?]);

    if (zgui.plot.beginPlot("Frame times", .{})) {
        defer zgui.plot.endPlot();

        // x axis
        zgui.plot.setupAxis(.x1, .{ .label = "frame" });
        zgui.plot.setupAxisLimits(.x1, .{ .min = 0, .max = self.metrics_state.frame_times.len });

        // y axis
        zgui.plot.setupAxis(.y1, .{ .label = "time (ms)" });
        zgui.plot.setupAxisLimits(.y1, .{ .min = 0, .max = @floatCast(30) });

        zgui.plot.setupFinish();

        zgui.plot.plotLineValues("Frame times", f32, .{
            .v = &self.metrics_state.frame_times,
        });
    }

    zgui.text("Recent frame time: {d:>8.3}", .{self.metrics_state.frame_times[self.metrics_state.frame_times.len - 1]});
    zgui.text("Minimum frame time: {d:>8.3}", .{self.metrics_state.min_frame_time});
    zgui.text("Maximum frame time: {d:>8.3}", .{self.metrics_state.max_frame_time});

    if (zgui.collapsingHeader("Benchmark", .{})) {
        const benchmark_active = storage.hasComponents(self.benchmark_entity, .{benchmark.components.Benchmark});
        if (benchmark_active) {
            // imgui.igPushItemFlag(ImGuiButtonFlags_Disabled, true);
            zgui.pushStyleVar1f(.{ .idx = .alpha, .v = zgui.getStyle().alpha * 0.5 });
        }
        if (zgui.button("Start benchmark", .{ .w = 200, .h = 80 })) {
            if (benchmark_active == false) {
                // reset sun to avoid any difference in lighting affecting performance
                if (device_sun.enabled > 0 and sun_ptr.animate) {
                    const reset_sun = sun.createSunComponents(.{});
                    sun_ptr.* = reset_sun.sun;
                    device_sun.* = reset_sun.device;
                }

                try storage.setComponents(self.benchmark_entity, benchmark.createBenchmarkComponents(
                    camera_ptr,
                    device_camera,
                    [_]f32{
                        @floatFromInt(self.state_binding.grid_device.dim_x),
                        @floatFromInt(self.state_binding.grid_device.dim_y),
                        @floatFromInt(self.state_binding.grid_device.dim_z),
                    },
                    device_sun.enabled > 0,
                ));
            }
        }
        imguiToolTip("benchmark will control camera and create a report to stdout", .{});
        if (benchmark_active) {
            zgui.popStyleVar(.{});
        }
    }
}

inline fn drawPostProcessWindowIfEnabled(self: *ImguiGui) void {
    if (self.post_process_window_active == false) return;

    zgui.setNextWindowSize(.{
        .w = 400,
        .h = 500,
        .cond = .first_use_ever,
    });
    const post_window_open = zgui.begin("Post process", .{ .popen = &self.post_process_window_active });
    defer zgui.end();
    if (post_window_open == false) return;

    _ = zgui.inputInt("Samples", .{ .v = &self.state_binding.gfx_pipeline_shader_constants.samples, .step_fast = 2 });
    imguiToolTip("Higher sample count result in less noise\nThis comes at the cost of performance", .{});

    _ = zgui.sliderFloat("Distribution bias", .{
        .v = &self.state_binding.gfx_pipeline_shader_constants.distribution_bias,
        .min = 0,
        .max = 1,
    });
    _ = zgui.sliderFloat("Pixel Multiplier", .{
        .v = &self.state_binding.gfx_pipeline_shader_constants.pixel_multiplier,
        .min = 1,
        .max = 3,
    });
    imguiToolTip("should be kept low", .{});
    _ = zgui.sliderFloat("Inverse Hue Tolerance", .{
        .v = &self.state_binding.gfx_pipeline_shader_constants.inverse_hue_tolerance,
        .min = 2,
        .max = 30,
    });
}

inline fn drawPostSunWindowIfEnabled(self: *ImguiGui, sun_ptr: *sun.components.Sun, device_sun: *sun.components.DeviceSun) void {
    if (self.sun_window_active == false) return;

    zgui.setNextWindowSize(.{
        .w = 400,
        .h = 500,
        .cond = .first_use_ever,
    });

    const sun_open = zgui.begin("Sun", .{ .popen = &self.sun_window_active });
    defer zgui.end();
    if (sun_open == false) return;

    var enabled = device_sun.enabled > 0;
    _ = zgui.checkbox("enabled", .{ .v = &enabled });
    device_sun.enabled = if (enabled) 1 else 0;

    _ = zgui.dragFloat3("position", .{
        .v = &device_sun.position,
        .speed = 1,
        .min = -10000,
        .max = 10000,
    });
    _ = zgui.colorEdit3("color", .{
        .col = &device_sun.color,
    });
    _ = zgui.dragFloat("radius", .{
        .v = &device_sun.radius,
        .speed = 1,
        .min = 0,
        .max = 20,
    });

    if (zgui.collapsingHeader("Animation", .{})) {
        _ = zgui.checkbox("animate", .{
            .v = &sun_ptr.animate,
        });
        var speed: f32 = sun_ptr.animate_speed / 3;
        const speed_changed = zgui.inputFloat("speed", .{ .v = &speed });
        imguiToolTip("how long a day and night last in seconds", .{});
        if (speed_changed) {
            sun_ptr.animate_speed = speed * 3;
        }
    }
}

const ToolTipConfig = struct {
    offset_from_start: f32 = 0,
    spacing: f32 = 10,
};
fn imguiToolTip(comptime tip: []const u8, config: ToolTipConfig) void {
    zgui.sameLine(.{
        .offset_from_start_x = config.offset_from_start,
        .spacing = config.spacing,
    });
    zgui.textDisabled("(?)", .{});
    if (zgui.isItemHovered(.{})) {
        _ = zgui.beginTooltip();
        zgui.pushTextWrapPos(450);
        zgui.textUnformatted(tip);
        zgui.popTextWrapPos();
        zgui.endTooltip();
    }
}
