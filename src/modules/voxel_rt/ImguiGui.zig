const std = @import("std");

const imgui = @import("imgui");

const render = @import("../render.zig");
const Context = render.Context;

const Camera = @import("Camera.zig");
const Pipeline = @import("Pipeline.zig");
const GraphicsPipeline = @import("GraphicsPipeline.zig");

pub const StateBinding = struct {
    camera_ptr: *Camera,
    gfx_pipeline_shader_constants: *GraphicsPipeline.PushConstant,
};

pub const Config = struct {
    camera_window_active: bool = true,
    metrics_window_active: bool = true,
    post_process_window_active: bool = true,
    update_frame_timings: bool = true,
};

const MetricState = struct {
    update_frame_timings: bool,
    prev_frame_ts: i128,
    frame_times: [50]f32,
    min_frame_time: f32,
    max_frame_time: f32,
};

// build voxel_rt gui for the ImguiPipeline and handle state propagation
const ImguiGui = @This();

state_binding: StateBinding,

camera_window_active: bool,
metrics_window_active: bool,
post_process_window_active: bool,

metrics_state: MetricState,

pub fn init(gui_width: f32, gui_height: f32, state_binding: StateBinding, config: Config) ImguiGui {
    // Color scheme
    const style = imgui.igGetStyle();
    style.Colors[imgui.ImGuiCol_TitleBg] = imgui.ImVec4{ .x = 0.1, .y = 0.1, .z = 0.1, .w = 0.85 };
    style.Colors[imgui.ImGuiCol_TitleBgActive] = imgui.ImVec4{ .x = 0.15, .y = 0.15, .z = 0.15, .w = 0.9 };
    style.Colors[imgui.ImGuiCol_MenuBarBg] = imgui.ImVec4{ .x = 0.1, .y = 0.1, .z = 0.1, .w = 0.8 };
    style.Colors[imgui.ImGuiCol_Header] = imgui.ImVec4{ .x = 0.1, .y = 0.1, .z = 0.1, .w = 0.8 };
    style.Colors[imgui.ImGuiCol_CheckMark] = imgui.ImVec4{ .x = 0, .y = 1, .z = 0, .w = 1 };

    // Dimensions
    const io = imgui.igGetIO();
    io.DisplaySize = imgui.ImVec2.init(gui_width, gui_height);
    io.DisplayFramebufferScale = imgui.ImVec2.init(1, 1);

    return ImguiGui{
        .state_binding = state_binding,
        .camera_window_active = config.camera_window_active,
        .metrics_window_active = config.metrics_window_active,
        .post_process_window_active = config.post_process_window_active,

        .metrics_state = .{
            .update_frame_timings = config.update_frame_timings,
            .prev_frame_ts = std.time.nanoTimestamp(),
            .frame_times = [_]f32{0} ** 50,
            .min_frame_time = std.math.f32_max,
            .max_frame_time = std.math.f32_min,
        },
    };
}

/// handle window resizing
pub fn handleRescale(self: ImguiGui, gui_width: f32, gui_height: f32) void {
    _ = self;

    const io = imgui.igGetIO();
    io.DisplaySize = imgui.ImVec2.init(gui_width, gui_height);
}

// Starts a new imGui frame and sets up windows and ui elements
pub fn newFrame(self: *ImguiGui, ctx: Context, pipeline: *Pipeline, update_metrics: bool) void {
    _ = ctx;
    _ = pipeline;
    imgui.igNewFrame();

    const style = imgui.igGetStyle();
    const rounding = style.WindowRounding;
    style.WindowRounding = 0; // no rounding for top menu

    imgui.igSetNextWindowSize(
        .{
            .x = @intToFloat(f32, pipeline.swapchain.extent.width),
            .y = 0,
        },
        imgui.ImGuiCond_Always,
    );
    imgui.igSetNextWindowPos(.{ .x = 0, .y = 0 }, imgui.ImGuiCond_Always, .{ .x = 0, .y = 0 });
    _ = imgui.igBegin(
        "Main menu",
        null,
        imgui.ImGuiWindowFlags_MenuBar |
            imgui.ImGuiWindowFlags_NoMove |
            imgui.ImGuiWindowFlags_NoResize |
            imgui.ImGuiWindowFlags_NoTitleBar |
            imgui.ImGuiWindowFlags_NoScrollbar |
            imgui.ImGuiWindowFlags_NoScrollWithMouse |
            imgui.ImGuiWindowFlags_NoCollapse |
            imgui.ImGuiWindowFlags_NoBackground,
    );
    style.WindowRounding = rounding;

    blk: {
        if (imgui.igBeginMenuBar() == false) break :blk;
        defer imgui.igEndMenuBar();

        if (imgui.igBeginMenu("Windows", true) == false) break :blk;
        defer imgui.igEndMenu();

        if (imgui.igMenuItemBool("Camera", null, self.camera_window_active, true)) {
            self.camera_window_active = !self.camera_window_active;
        }
        if (imgui.igMenuItemBool("Metrics", null, self.metrics_window_active, true)) {
            self.metrics_window_active = !self.metrics_window_active;
        }
        if (imgui.igMenuItemBool("Post process", null, self.post_process_window_active, true)) {
            self.post_process_window_active = !self.post_process_window_active;
        }
    }
    imgui.igEnd();

    blk: {
        if (!self.metrics_state.update_frame_timings or !update_metrics) {
            break :blk;
        }
        const now = std.time.nanoTimestamp();
        const frame_time = @intToFloat(f32, now - self.metrics_state.prev_frame_ts) / std.time.ns_per_ms;
        self.metrics_state.prev_frame_ts = now;
        std.mem.copy(f32, self.metrics_state.frame_times[0..], self.metrics_state.frame_times[1..]);
        self.metrics_state.frame_times[49] = frame_time;
        self.metrics_state.min_frame_time = std.math.min(self.metrics_state.min_frame_time, frame_time);
        self.metrics_state.max_frame_time = std.math.max(self.metrics_state.max_frame_time, frame_time);
    }

    self.drawCameraWindowIfEnabled();
    self.drawMetricsWindowIfEnabled();
    self.drawPostProcessWindowIfEnabled();

    // imgui.igSetNextWindowPos(.{ .x = 650, .y = 20 }, imgui.ImGuiCond_FirstUseEver, .{ .x = 0, .y = 0 });
    // imgui.igShowDemoWindow(null);

    imgui.igRender();
}

inline fn drawCameraWindowIfEnabled(self: *ImguiGui) void {
    if (self.camera_window_active == false) return;

    imgui.igSetNextWindowSize(.{ .x = 400, .y = 500 }, imgui.ImGuiCond_FirstUseEver);
    const early_exit = imgui.igBegin("Camera", &self.camera_window_active, imgui.ImGuiWindowFlags_None) == false;
    defer imgui.igEnd();
    if (early_exit) return;

    _ = imgui.igSliderInt("max bounces", &self.state_binding.camera_ptr.d_camera.max_bounce, 1, 32, null, 0);
    imguiToolTip("how many times a ray is allowed to bounce before terminating", .{});
    _ = imgui.igSliderInt("samples per pixel", &self.state_binding.camera_ptr.d_camera.samples_per_pixel, 1, 32, null, 0);
    imguiToolTip("how many rays per pixel", .{});

    _ = imgui.igInputFloat("move speed", &self.state_binding.camera_ptr.normal_speed, 0, 0, null, 0);
    _ = imgui.igInputFloat("turn rate", &self.state_binding.camera_ptr.turn_rate, 0, 0, null, 0);

    var camera_origin: [3]f32 = self.state_binding.camera_ptr.d_camera.origin;
    const camera_origin_changed = imgui.igInputFloat3("camera position", &camera_origin, null, 0);
    if (camera_origin_changed) {
        self.state_binding.camera_ptr.setOrigin(camera_origin);
    }
}

inline fn drawMetricsWindowIfEnabled(self: *ImguiGui) void {
    if (self.post_process_window_active == false) return;

    imgui.igSetNextWindowSize(.{ .x = 400, .y = 500 }, imgui.ImGuiCond_FirstUseEver);
    const early_exit = imgui.igBegin("Metrics", &self.post_process_window_active, imgui.ImGuiWindowFlags_None) == false;
    defer imgui.igEnd();
    if (early_exit) return;

    imgui.igPlotLinesFloatPtr("Frame times", &self.metrics_state.frame_times, 50, 0, "", self.metrics_state.min_frame_time, self.metrics_state.max_frame_time, imgui.ImVec2{ .x = 0, .y = 80 }, @sizeOf(f32));
    imgui.igText("Recent frame time: %f", self.metrics_state.frame_times[49]);
    imgui.igText("Minimum frame time: %f", self.metrics_state.min_frame_time);
    imgui.igText("Maximum frame time: %f", self.metrics_state.max_frame_time);
}

inline fn drawPostProcessWindowIfEnabled(self: *ImguiGui) void {
    if (self.post_process_window_active == false) return;

    imgui.igSetNextWindowSize(.{ .x = 400, .y = 500 }, imgui.ImGuiCond_FirstUseEver);
    const early_exit = imgui.igBegin("Post process", &self.post_process_window_active, imgui.ImGuiWindowFlags_None) == false;
    defer imgui.igEnd();
    if (early_exit) return;

    const none_flag = imgui.ImGuiInputTextFlags_None;
    _ = imgui.igInputInt("Samples", &self.state_binding.gfx_pipeline_shader_constants.samples, 1, 2, none_flag);
    imguiToolTip("Higher sample count result in less noise\nThis comes at the cost of performance", .{});
    _ = imgui.igSliderFloat("Distribution bias", &self.state_binding.gfx_pipeline_shader_constants.distribution_bias, 0, 1, null, none_flag);
    _ = imgui.igSliderFloat("Pixel Multiplier", &self.state_binding.gfx_pipeline_shader_constants.pixel_multiplier, 1, 3, null, none_flag);
    imguiToolTip("should be kept low", .{});
    _ = imgui.igSliderFloat("Inverse Hue Tolerance", &self.state_binding.gfx_pipeline_shader_constants.inverse_hue_tolerance, 2, 30, null, none_flag);
}

const ToolTipConfig = struct {
    offset_from_start: f32 = 0,
    spacing: f32 = 10,
};
fn imguiToolTip(comptime tip: [*c]const u8, config: ToolTipConfig) void {
    imgui.igSameLine(config.offset_from_start, config.spacing);
    imgui.igTextDisabled("(?)");
    if (imgui.igIsItemHovered(imgui.ImGuiHoveredFlags_None)) {
        imgui.igBeginTooltip();
        imgui.igPushTextWrapPos(450);
        imgui.igTextUnformatted(tip, null);
        imgui.igPopTextWrapPos();
        imgui.igEndTooltip();
    }
}