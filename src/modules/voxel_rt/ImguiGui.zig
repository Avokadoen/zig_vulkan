const imgui = @import("imgui");

const render = @import("../render.zig");
const Context = render.Context;

const Camera = @import("Camera.zig");
const Pipeline = @import("Pipeline.zig"); // TODO: circular dependency :( ...

pub const StateBinding = struct {
    camera_ptr: *Camera,
};

pub const Config = struct {
    camera_window_active: bool = true,
};

// build voxel_rt gui for the ImguiPipeline and handle state propagation
const ImguiGui = @This();

state_binding: StateBinding,

camera_window_active: bool,

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
    };
}

// Starts a new imGui frame and sets up windows and ui elements
pub fn newFrame(self: *ImguiGui, ctx: Context, pipeline: *Pipeline) void {
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
        "Control panel",
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
    }
    imgui.igEnd();

    self.drawCameraWindowIfEnabled();

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
    _ = imgui.igSliderInt("samples per pixel", &self.state_binding.camera_ptr.d_camera.samples_per_pixel, 1, 32, null, 0);

    var camera_origin: [3]f32 = self.state_binding.camera_ptr.d_camera.origin;
    const camera_origin_changed = imgui.igInputFloat3("camera position", &camera_origin, null, 0);
    if (camera_origin_changed) {
        self.state_binding.camera_ptr.setOrigin(camera_origin);
    }
}
