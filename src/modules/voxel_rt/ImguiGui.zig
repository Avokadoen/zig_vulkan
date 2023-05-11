const std = @import("std");

const zgui = @import("zgui");
const vk = @import("vulkan");
const tracy = @import("ztracy");

const render = @import("../render.zig");
const Context = render.Context;

const Camera = @import("Camera.zig");
const Sun = @import("Sun.zig");
const BrickState = @import("brick/State.zig");
const Pipeline = @import("Pipeline.zig");
const GraphicsPipeline = @import("GraphicsPipeline.zig");
const Benchmark = @import("Benchmark.zig");
const TraverseRayPipeline = @import("TraverseRayPipeline.zig");

pub const StateBinding = struct {
    camera_ptr: *Camera,
    /// used in benchmark report, TODO: remove this field (brick_grid_state is the same)
    grid_state: BrickState,
    sun_ptr: *Sun,
    gfx_pipeline_shader_constants: *GraphicsPipeline.PushConstant,
    brick_grid_state: *TraverseRayPipeline.BrickGridState,
};

pub const Config = struct {
    camera_window_active: bool = true,
    metrics_window_active: bool = true,
    post_process_window_active: bool = true,
    sun_window_active: bool = true,
    grid_settings_window_active: bool = true,
    update_frame_timings: bool = true,
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
grid_settings_window_active: bool,

device_properties: vk.PhysicalDeviceProperties,

metrics_state: MetricState,

benchmark: ?Benchmark = null,

pub fn init(ctx: Context, gui_width: f32, gui_height: f32, state_binding: StateBinding, config: Config) ImguiGui {
    const zone = tracy.ZoneN(@src(), @typeName(ImguiGui) ++ " " ++ @src().fn_name);
    defer zone.End();

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

    return ImguiGui{
        .state_binding = state_binding,
        .camera_window_active = config.camera_window_active,
        .metrics_window_active = config.metrics_window_active,
        .post_process_window_active = config.post_process_window_active,
        .sun_window_active = config.sun_window_active,
        .grid_settings_window_active = config.grid_settings_window_active,
        .device_properties = ctx.getPhysicalDeviceProperties(),
        .metrics_state = .{
            .update_frame_timings = config.update_frame_timings,
            .frame_times = [_]f32{0} ** 128,
            .min_frame_time = std.math.f32_max,
            .max_frame_time = std.math.f32_min,
        },
    };
}

/// handle window resizing
pub fn handleRescale(self: ImguiGui, gui_width: f32, gui_height: f32) void {
    const zone = tracy.ZoneN(@src(), @typeName(ImguiGui) ++ " " ++ @src().fn_name);
    defer zone.End();

    _ = self;

    zgui.io.setDisplaySize(gui_width, gui_height);
}

// Starts a new imGui frame and sets up windows and ui elements
pub fn newFrame(self: *ImguiGui, ctx: Context, pipeline: *Pipeline, update_metrics: bool, dt: f32) void {
    const zone = tracy.ZoneN(@src(), @typeName(ImguiGui) ++ " " ++ @src().fn_name);
    defer zone.End();

    zgui.newFrame();

    const style = zgui.getStyle();
    const rounding = style.window_rounding;
    style.window_rounding = 0; // no rounding for top menu

    zgui.setNextWindowSize(
        .{
            .w = @intToFloat(f32, pipeline.swapchain.extent.width),
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
        if (zgui.menuItem("Grid settings", .{ .selected = self.sun_window_active, .enabled = true })) {
            self.grid_settings_window_active = !self.grid_settings_window_active;
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
        self.metrics_state.min_frame_time = std.math.min(self.metrics_state.min_frame_time, frame_time);
        self.metrics_state.max_frame_time = std.math.max(self.metrics_state.max_frame_time, frame_time);
    }

    self.benchmark = blk: {
        if (self.benchmark) |*b| {
            if (b.update(dt)) {
                self.state_binding.camera_ptr.reset();
                b.printReport(self.device_properties.device_name[0..]);
                break :blk null;
            }
        }
        break :blk self.benchmark;
    };

    self.drawCameraWindowIfEnabled();
    self.drawMetricsWindowIfEnabled();
    self.drawPostProcessWindowIfEnabled();
    self.drawPostSunWindowIfEnabled();
    self.drawGridSettingsWindowIfEnabled(ctx, pipeline);

    // imgui.igSetNextWindowPos(.{ .x = 650, .y = 20 }, imgui.ImGuiCond_FirstUseEver, .{ .x = 0, .y = 0 });
    // imgui.igShowDemoWindow(null);

    zgui.render();
}

inline fn drawCameraWindowIfEnabled(self: *ImguiGui) void {
    if (self.camera_window_active == false) return;

    const zone = tracy.ZoneN(@src(), @typeName(ImguiGui) ++ " " ++ @src().fn_name);
    defer zone.End();

    zgui.setNextWindowSize(.{
        .w = 400,
        .h = 500,
        .cond = .first_use_ever,
    });
    const camera_open = zgui.begin("Camera", .{ .popen = &self.camera_window_active });
    defer zgui.end();
    if (camera_open == false) return;

    _ = zgui.sliderInt("max bounces", .{
        .v = &self.state_binding.camera_ptr.d_camera.max_bounce,
        .min = 0,
        .max = 32,
    });
    imguiToolTip("how many times a ray is allowed to bounce before terminating", .{});
    _ = zgui.sliderInt("samples per pixel", .{
        .v = &self.state_binding.camera_ptr.d_camera.samples_per_pixel,
        .min = 1,
        .max = 32,
    });
    imguiToolTip("how many rays per pixel", .{});

    _ = zgui.inputFloat("move speed", .{ .v = &self.state_binding.camera_ptr.normal_speed });
    _ = zgui.inputFloat("turn rate", .{ .v = &self.state_binding.camera_ptr.turn_rate });

    var camera_origin: [3]f32 = self.state_binding.camera_ptr.d_camera.origin;
    const camera_origin_changed = zgui.inputFloat3("position", .{ .v = &camera_origin });
    if (camera_origin_changed) {
        self.state_binding.camera_ptr.setOrigin(camera_origin);
    }
}

inline fn drawMetricsWindowIfEnabled(self: *ImguiGui) void {
    if (self.metrics_window_active == false) return;

    const zone = tracy.ZoneN(@src(), @typeName(ImguiGui) ++ " " ++ @src().fn_name);
    defer zone.End();

    zgui.setNextWindowSize(.{
        .w = 400,
        .h = 500,
        .cond = .first_use_ever,
    });
    const metrics_open = zgui.begin("Metrics", .{ .popen = &self.metrics_window_active });
    defer zgui.end();
    if (metrics_open == false) return;

    const zero_index = std.mem.indexOf(u8, &self.device_properties.device_name, &[_]u8{0});
    zgui.textUnformatted(self.device_properties.device_name[0..zero_index.?]);

    if (zgui.plot.beginPlot("Frame times", .{})) {
        defer zgui.plot.endPlot();

        // x axis
        zgui.plot.setupAxis(.x1, .{ .label = "frame" });
        zgui.plot.setupAxisLimits(.x1, .{ .min = 0, .max = self.metrics_state.frame_times.len });

        // y axis
        zgui.plot.setupAxis(.y1, .{ .label = "time (ms)" });
        zgui.plot.setupAxisLimits(.y1, .{ .min = 0, .max = @floatCast(f64, 30) });

        zgui.plot.setupFinish();

        zgui.plot.plotLineValues("Frame times", f32, .{
            .v = &self.metrics_state.frame_times,
        });
    }

    zgui.text("Recent frame time: {d:>8.3}", .{self.metrics_state.frame_times[self.metrics_state.frame_times.len - 1]});
    zgui.text("Minimum frame time: {d:>8.3}", .{self.metrics_state.min_frame_time});
    zgui.text("Maximum frame time: {d:>8.3}", .{self.metrics_state.max_frame_time});

    if (zgui.collapsingHeader("Benchmark", .{})) {
        const benchmark_active = self.benchmark != null;
        if (benchmark_active) {
            // imgui.igPushItemFlag(ImGuiButtonFlags_Disabled, true);
            zgui.pushStyleVar1f(.{ .idx = .alpha, .v = zgui.getStyle().alpha * 0.5 });
        }
        if (zgui.button("Start benchmark", .{ .w = 200, .h = 80 })) {
            if (benchmark_active == false) {
                // reset sun to avoid any difference in lighting affecting performance
                if (self.state_binding.sun_ptr.device_data.enabled > 0 and self.state_binding.sun_ptr.animate) {
                    self.state_binding.sun_ptr.* = Sun.init(.{});
                }
                self.benchmark = Benchmark.init(
                    self.state_binding.camera_ptr,
                    self.state_binding.grid_state,
                    (self.state_binding.sun_ptr.device_data.enabled > 0),
                );
            }
        }
        imguiToolTip("benchmark will control camera and create a report to stdout", .{});
        if (benchmark_active) {
            // imgui.igPopItemFlag();
            zgui.popStyleVar(.{});
        }
    }
}

inline fn drawPostProcessWindowIfEnabled(self: *ImguiGui) void {
    if (self.post_process_window_active == false) return;

    const zone = tracy.ZoneN(@src(), @typeName(ImguiGui) ++ " " ++ @src().fn_name);
    defer zone.End();

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

fn drawGridSettingsWindowIfEnabled(self: *ImguiGui, ctx: Context, pipeline: *Pipeline) void {
    if (self.grid_settings_window_active == false) return;

    const zone = tracy.ZoneN(@src(), @typeName(ImguiGui) ++ " " ++ @src().fn_name);
    defer zone.End();

    zgui.setNextWindowSize(.{
        .w = 400,
        .h = 500,
        .cond = .first_use_ever,
    });

    const grid_open = zgui.begin("Grid settings", .{ .popen = &self.grid_settings_window_active });
    defer zgui.end();
    if (grid_open == false) return;

    var change_occured = false;
    change_occured = change_occured or zgui.dragFloat("scale##grid", .{
        .v = &self.state_binding.brick_grid_state.scale,
        .speed = 0.1,
        .min = 0.1,
        .max = 1000,
    });
    change_occured = change_occured or zgui.dragFloat3("position##grid", .{
        .v = &self.state_binding.brick_grid_state.min_point,
        .speed = 0.5,
        .min = -10000,
        .max = 10000,
    });

    if (change_occured) {
        // transfer brick grid state to GPU. If it fails, then we ignore it.
        pipeline.transferCurrentBrickGridState(ctx) catch {};
    }
}

inline fn drawPostSunWindowIfEnabled(self: *ImguiGui) void {
    if (self.sun_window_active == false) return;

    const zone = tracy.ZoneN(@src(), @typeName(ImguiGui) ++ " " ++ @src().fn_name);
    defer zone.End();

    zgui.setNextWindowSize(.{
        .w = 400,
        .h = 500,
        .cond = .first_use_ever,
    });

    const sun_open = zgui.begin("Sun", .{ .popen = &self.sun_window_active });
    defer zgui.end();
    if (sun_open == false) return;

    var enabled = (self.state_binding.sun_ptr.device_data.enabled > 0);
    _ = zgui.checkbox("enabled", .{ .v = &enabled });
    self.state_binding.sun_ptr.device_data.enabled = if (enabled) 1 else 0;

    _ = zgui.dragFloat3("position", .{
        .v = &self.state_binding.sun_ptr.device_data.position,
        .speed = 1,
        .min = -10000,
        .max = 10000,
    });
    _ = zgui.colorEdit3("color", .{ .col = &self.state_binding.sun_ptr.device_data.color });
    _ = zgui.dragFloat("radius", .{ .v = &self.state_binding.sun_ptr.device_data.radius, .speed = 1, .min = 0, .max = 20 });

    if (zgui.collapsingHeader("Animation", .{})) {
        _ = zgui.checkbox("animate", .{ .v = &self.state_binding.sun_ptr.animate });
        var speed: f32 = self.state_binding.sun_ptr.animate_speed / 3;
        const speed_changed = zgui.inputFloat("speed", .{ .v = &speed });
        imguiToolTip("how long a day and night last in seconds", .{});
        if (speed_changed) {
            self.state_binding.sun_ptr.animate_speed = speed * 3;
        }
        // TODO: allow these to be changed: (?)
        // slerp_orientations: [3]za.Quat,
        // lerp_color: [3]za.Vec3,
        // static_pos_vec: za.Vec3,
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
        if (zgui.beginTooltip()) {
            zgui.pushTextWrapPos(450);
            zgui.textUnformatted(tip);
            zgui.popTextWrapPos();
            zgui.endTooltip();
        }
    }
}
