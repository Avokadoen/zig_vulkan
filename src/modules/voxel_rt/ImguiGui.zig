const std = @import("std");

const imgui = @import("imgui");
const vk = @import("vulkan");

const render = @import("../render.zig");
const Context = render.Context;

const Camera = @import("Camera.zig");
const Sun = @import("Sun.zig");
const BrickState = @import("brick/State.zig");
const Pipeline = @import("Pipeline.zig");
const GraphicsPipeline = @import("GraphicsPipeline.zig");
const Benchmark = @import("Benchmark.zig");

pub const StateBinding = struct {
    camera_ptr: *Camera,
    /// used in benchmark report
    grid_state: BrickState,
    sun_ptr: *Sun,
    gfx_pipeline_shader_constants: *GraphicsPipeline.PushConstant,
};

pub const Config = struct {
    camera_window_active: bool = true,
    metrics_window_active: bool = true,
    post_process_window_active: bool = true,
    sun_window_active: bool = true,
    update_frame_timings: bool = true,
};

const MetricState = struct {
    update_frame_timings: bool,
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
sun_window_active: bool,

device_properties: vk.PhysicalDeviceProperties,

metrics_state: MetricState,

benchmark: ?Benchmark = null,

pub fn init(ctx: Context, gui_width: f32, gui_height: f32, state_binding: StateBinding, config: Config) ImguiGui {
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
        .sun_window_active = config.sun_window_active,
        .device_properties = ctx.getPhysicalDeviceProperties(),
        .metrics_state = .{
            .update_frame_timings = config.update_frame_timings,
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
pub fn newFrame(self: *ImguiGui, ctx: Context, pipeline: *Pipeline, update_metrics: bool, dt: f32) void {
    _ = ctx;
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
        if (imgui.igMenuItemBool("Sun", null, self.sun_window_active, true)) {
            self.sun_window_active = !self.sun_window_active;
        }
    }
    imgui.igEnd();

    blk: {
        if (!self.metrics_state.update_frame_timings or !update_metrics) {
            break :blk;
        }
        std.mem.rotate(f32, self.metrics_state.frame_times[0..], 1);
        const frame_time = dt * std.time.ms_per_s;
        self.metrics_state.frame_times[49] = frame_time;
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
    const camera_origin_changed = imgui.igInputFloat3("position", &camera_origin, null, 0);
    if (camera_origin_changed) {
        self.state_binding.camera_ptr.setOrigin(camera_origin);
    }
}

inline fn drawMetricsWindowIfEnabled(self: *ImguiGui) void {
    if (self.metrics_window_active == false) return;

    imgui.igSetNextWindowSize(.{ .x = 400, .y = 500 }, imgui.ImGuiCond_FirstUseEver);
    const early_exit = imgui.igBegin("Metrics", &self.metrics_window_active, imgui.ImGuiWindowFlags_None) == false;
    defer imgui.igEnd();
    if (early_exit) return;

    imgui.igTextUnformatted(self.device_properties.device_name[0..], null);

    imgui.igPlotLinesFloatPtr(
        "Frame times",
        &self.metrics_state.frame_times,
        self.metrics_state.frame_times.len,
        0,
        "",
        self.metrics_state.min_frame_time,
        self.metrics_state.max_frame_time,
        imgui.ImVec2{ .x = 0, .y = 80 },
        @sizeOf(f32),
    );

    const zigImguiText = struct {
        pub inline fn fmt(buffer: []u8, begin: []const u8, number: f32) void {
            const fmt_str = "{s:<7} frame time: {d:>8.3}";
            const ok = std.fmt.bufPrint(buffer[0..], fmt_str, .{ begin, number }) catch {
                imgui.igTextUnformatted("error", null);
                return;
            };
            if (buffer.len - 1 <= ok.len) {
                imgui.igTextUnformatted("error", null);
                return;
            }
            buffer[ok.len] = 0;
            imgui.igTextUnformatted(buffer[0..].ptr, null);
        }
    }.fmt;
    var buffer: ["Minimum frame time: 99999999999999".len]u8 = undefined;
    zigImguiText(buffer[0..], "Recent", self.metrics_state.frame_times[self.metrics_state.frame_times.len - 1]);
    zigImguiText(buffer[0..], "Minimum", self.metrics_state.min_frame_time);
    zigImguiText(buffer[0..], "Maximum", self.metrics_state.max_frame_time);

    if (imgui.igCollapsingHeaderBoolPtr("Benchmark", null, imgui.ImGuiTreeNodeFlags_None)) {
        { // benchmark button
            const benchmark_active = self.benchmark != null;
            if (benchmark_active) {
                // TODO: use imgui.ImGuiButtonFlags_Disabled:
                //  using imgui.ImGuiButtonFlags_Disabled causes compile error in
                //  imgui library issue: https://github.com/prime31/zig-gamekit/issues/13
                const ImGuiButtonFlags_Disabled = 16384;
                imgui.igPushItemFlag(ImGuiButtonFlags_Disabled, true);
                imgui.igPushStyleVarFloat(imgui.ImGuiStyleVar_Alpha, imgui.igGetStyle().Alpha * 0.5);
            }
            if (imgui.igButton("Start benchmark", imgui.ImVec2{ .x = 200, .y = 80 })) {
                if (benchmark_active == false) {
                    // reset sun to avoid any difference in lighting affecting performance
                    if (self.state_binding.sun_ptr.animate) {
                        self.state_binding.sun_ptr.* = Sun.init(.{});
                    }
                    self.benchmark = Benchmark.init(self.state_binding.camera_ptr, self.state_binding.grid_state);
                }
            }
            imguiToolTip("benchmark will control camera and create a report to stdout", .{});
            if (benchmark_active) {
                imgui.igPopItemFlag();
                imgui.igPopStyleVar(1);
            }
        }
    }
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

inline fn drawPostSunWindowIfEnabled(self: *ImguiGui) void {
    if (self.sun_window_active == false) return;

    imgui.igSetNextWindowSize(.{ .x = 400, .y = 500 }, imgui.ImGuiCond_FirstUseEver);
    const early_exit = imgui.igBegin("Sun", &self.sun_window_active, imgui.ImGuiWindowFlags_None) == false;
    defer imgui.igEnd();
    if (early_exit) return;

    var enabled = (self.state_binding.sun_ptr.device_data.enabled > 0);
    _ = imgui.igCheckbox("enabled", &enabled);
    self.state_binding.sun_ptr.device_data.enabled = if (enabled) 1 else 0;

    _ = imgui.igDragFloat3("position", &self.state_binding.sun_ptr.device_data.position, 1, -10000, 10000, null, 0);
    _ = imgui.igColorEdit3("color", &self.state_binding.sun_ptr.device_data.color, 0);
    _ = imgui.igDragFloat("radius", &self.state_binding.sun_ptr.device_data.radius, 0, 0, 20, null, 0);

    if (imgui.igCollapsingHeaderBoolPtr("Animation", null, imgui.ImGuiTreeNodeFlags_None)) {
        _ = imgui.igCheckbox("animate", &self.state_binding.sun_ptr.animate);
        var speed: f32 = self.state_binding.sun_ptr.animate_speed / 3;
        const speed_changed = imgui.igInputFloat("speed", &speed, 0, 0, null, 0);
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
