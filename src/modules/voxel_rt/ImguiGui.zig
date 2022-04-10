const imgui = @import("imgui");

const render = @import("../render.zig");
const Context = render.Context;

const Camera = @import("Camera.zig");
const Pipeline = @import("Pipeline.zig"); // TODO: circular dependency :( ...

pub const StateBinding = struct {
    camera_ptr: *Camera,
};

// build voxel_rt gui for the ImguiPipeline and handle state propagation
const ImguiGui = @This();

state_binding: StateBinding,

pub fn init(state_binding: StateBinding) ImguiGui {
    return ImguiGui{ .state_binding = state_binding };
}

// Starts a new imGui frame and sets up windows and ui elements
pub fn newFrame(self: *ImguiGui, ctx: Context, pipeline: *Pipeline) void {
    _ = ctx;
    _ = pipeline;
    imgui.igNewFrame();

    imgui.igSetNextWindowSize(.{ .x = 400, .y = 500 }, imgui.ImGuiCond_FirstUseEver);
    _ = imgui.igBegin("Camera settings", null, 0);
    var camera_changed = false;
    camera_changed = camera_changed or imgui.igSliderInt("max bounces", &self.state_binding.camera_ptr.d_camera.max_bounce, 1, 10, null, 0);
    camera_changed = camera_changed or imgui.igSliderInt("samples per pixel", &self.state_binding.camera_ptr.d_camera.samples_per_pixel, 1, 8, null, 0);

    var camera_origin: [3]f32 = self.state_binding.camera_ptr.d_camera.origin;
    const camera_origin_changed = camera_changed or imgui.igInputFloat3("camera position", &camera_origin, null, 0);
    if (camera_origin_changed) {
        camera_changed = true;
        self.state_binding.camera_ptr.setOrigin(camera_origin);
    }
    imgui.igEnd();

    // // Init imGui windows and elements
    // imgui.igText("Cam");
    // imgui.igText("some more text");

    // imgui.igText("Camera");
    // _ = imgui.igInputInt("max bounce", &self.state_bindings.camera.max_bounce, 0, 0, 0);

    // if (imgui.igButton("Count", .{ .x = 0, .y = 0 })) {
    //     State.counter += 1;
    // }
    // imgui.igSameLine(0, 10);
    // imgui.igText("counter = %d", State.counter);

    // imgui.igSetNextWindowSize(.{ .x = 200, .y = 200 }, imgui.ImGuiCond_FirstUseEver);
    // _ = imgui.igBegin("External settings", null, 0);
    // _ = imgui.igCheckbox("cool yes?", &self.state_bindings.cool_yes);
    // imgui.igEnd();

    // imgui.igSetNextWindowPos(.{ .x = 650, .y = 20 }, imgui.ImGuiCond_FirstUseEver, .{ .x = 0, .y = 0 });
    // imgui.igShowDemoWindow(null);

    imgui.igRender();

    if (camera_changed) {
        // camera is propagated as a push constant
    }
}
