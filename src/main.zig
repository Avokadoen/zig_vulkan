const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const glfw = @import("glfw");
const za = @import("zalgebra");
const tracy = @import("tracy.zig");

const render = @import("modules/render.zig");
const consts = render.consts;

const Input = @import("modules/Input.zig");
const InputModeCursor = Input.InputModeCursor;

// TODO: API topology
const VoxelRT = @import("modules/VoxelRT.zig");
const BrickGrid = VoxelRT.BrickGrid;
const gpu_types = VoxelRT.gpu_types;
const vox = VoxelRT.vox;
const terrain = VoxelRT.terrain;

pub const application_name = "zig vulkan";
pub const internal_render_resolution = za.GenericVector(2, u32).new(1920, 1080);

// TODO: wrap this in render to make main seem simpler :^)
var delta_time: f64 = 0;

var activate_sprint: bool = false;
var call_translate: u8 = 0;
var camera_translate = za.Vec3.zero();

var input: Input = undefined;
var call_yaw = false;
var call_pitch = false;
var mouse_delta = za.Vec2.zero();
var mouse_ignore_frames: u32 = 5;

pub fn main() anyerror!void {
    tracy.InitThread();
    tracy.SetThreadName("main thread");
    const main_zone = tracy.ZoneN(@src(), "main");
    defer main_zone.End();

    const stderr = std.io.getStdErr().writer();

    // create a gpa with default configuration
    var alloc = if (consts.enable_validation_layers) std.heap.GeneralPurposeAllocator(.{}){} else std.heap.c_allocator;
    defer {
        if (consts.enable_validation_layers) {
            const leak = alloc.deinit();
            if (leak) {
                stderr.print("leak detected in gpa!", .{}) catch unreachable;
            }
        }
    }
    const allocator = if (consts.enable_validation_layers) alloc.allocator() else alloc;

    // Initialize the library *
    try glfw.init(.{});
    defer glfw.terminate();

    if (!glfw.vulkanSupported()) {
        std.debug.panic("vulkan not supported on device (glfw)", .{});
    }

    // zig fmt: off
    // Create a windowed mode window
    var window = glfw.Window.create(3840, 2160, application_name, null, null, 
        .{ 
            .center_cursor = true, 
            .client_api = .no_api,
            .maximized = true,
            .scale_to_monitor = true,
            .focused = true, 
        }
    ) catch |err| {
        try stderr.print("failed to create window, code: {}", .{err});
        return;
    };
    // zig fmt: on
    defer window.destroy();

    const ctx = try render.Context.init(allocator, application_name, &window);
    defer ctx.deinit();

    var grid = try BrickGrid.init(allocator, 64, 32, 64, .{
        .min_point = [3]f32{ -32, -16, -32 },
        .material_indices_per_brick = 128,
    });
    defer grid.deinit();

    // force workers to sleep while terrain generate
    grid.sleepWorkers();

    const model = try vox.load(false, allocator, "../assets/models/monu10.vox");
    defer model.deinit();

    var albedo_color: [256]gpu_types.Albedo = undefined;
    var materials: [256]gpu_types.Material = undefined;
    // insert terrain color
    for (terrain.color_data) |color, i| {
        albedo_color[i] = color;
    }
    // insert terrain materials
    for (terrain.material_data) |material, i| {
        materials[i] = material;
    }

    const terrain_len = terrain.material_data.len;
    for (model.rgba_chunk[terrain_len..]) |rgba, i| {
        const index = i + terrain_len;
        albedo_color[index] = .{
            // zig fmt: off
            .color = za.Vec4.new(
                @intToFloat(f32, rgba.r) / 255, 
                @intToFloat(f32, rgba.g) / 255, 
                @intToFloat(f32, rgba.b) / 255, 
                @intToFloat(f32, rgba.a) / 255
            ).data,
            // zig fmt: on
        };
        materials[index] = .{ .@"type" = .lambertian, .type_index = 0, .albedo_index = @intCast(u15, index) };
    }

    // Test what we are loading
    for (model.xyzi_chunks[0]) |xyzi| {
        grid.insert(@intCast(usize, xyzi.x), @intCast(usize, xyzi.z), @intCast(usize, xyzi.y), xyzi.color_index);
    }

    // generate terrain on CPU
    try terrain.generateCpu(4, allocator, 420, 4, 20, &grid);
    grid.wakeWorkers();

    var voxel_rt = try VoxelRT.init(allocator, ctx, &grid, .{
        .internal_resolution_width = internal_render_resolution.x(),
        .internal_resolution_height = internal_render_resolution.y(),
    });
    defer voxel_rt.deinit(allocator, ctx);

    try voxel_rt.pushAlbedo(ctx, albedo_color[0..]);
    try voxel_rt.pushMaterials(ctx, materials[0..]);

    var prev_frame = std.time.milliTimestamp();
    try window.setInputMode(glfw.Window.InputMode.cursor, glfw.Window.InputModeCursor.disabled);

    // init input module with default input handler functions
    input = try Input.init(
        allocator,
        window,
        gameKeyInputFn,
        mouseBtnInputFn,
        gameCursorPosInputFn,
    );
    defer input.deinit(allocator);
    try input.setInputModeCursor(.disabled);
    input.setImguiWantInput(false);

    // Loop until the user closes the window
    while (!window.shouldClose()) {
        const current_frame = std.time.milliTimestamp();
        delta_time = @intToFloat(f64, current_frame - prev_frame) / @as(f64, std.time.ms_per_s);
        // f32 variant of delta_time
        const dt = @floatCast(f32, delta_time);

        if (call_translate > 0) {
            if (activate_sprint) {
                voxel_rt.camera.activateSprint();
            } else {
                voxel_rt.camera.disableSprint();
            }
            voxel_rt.camera.translate(dt, camera_translate);
        }
        if (call_yaw) {
            voxel_rt.camera.turnYaw(-mouse_delta.x() * dt);
        }
        if (call_pitch) {
            voxel_rt.camera.turnPitch(mouse_delta.y() * dt);
        }
        if (call_translate > 0 or call_yaw or call_pitch) {
            call_yaw = false;
            call_pitch = false;
            mouse_delta.data[0] = 0;
            mouse_delta.data[1] = 0;
            // try voxel_rt.debugUpdateTerrain(ctx);
        }
        try voxel_rt.updateGridDelta(ctx);

        try voxel_rt.draw(ctx);

        // Poll for and process events
        try glfw.pollEvents();
        prev_frame = current_frame;

        input.updateCursor() catch {};

        tracy.FrameMark();
    }
}

fn gameKeyInputFn(event: Input.KeyEvent) void {
    if (event.action == .press) {
        switch (event.key) {
            Input.Key.w => {
                call_translate += 1;
                camera_translate.data[2] -= 1;
            },
            Input.Key.s => {
                call_translate += 1;
                camera_translate.data[2] += 1;
            },
            Input.Key.d => {
                call_translate += 1;
                camera_translate.data[0] += 1;
            },
            Input.Key.a => {
                call_translate += 1;
                camera_translate.data[0] -= 1;
            },
            Input.Key.left_control => {
                call_translate += 1;
                camera_translate.data[1] += 1;
            },
            Input.Key.left_shift => activate_sprint = true,
            Input.Key.space => {
                call_translate += 1;
                camera_translate.data[1] -= 1;
            },
            Input.Key.escape => {
                input.setCursorPosCallback(menuCursorPosInputFn);
                input.setKeyCallback(menuKeyInputFn);
                input.setInputModeCursor(.normal) catch {};
                input.setImguiWantInput(true);
            },
            else => {},
        }
    } else if (event.action == .release) {
        switch (event.key) {
            Input.Key.w => {
                call_translate -= 1;
                camera_translate.data[2] += 1;
            },
            Input.Key.s => {
                call_translate -= 1;
                camera_translate.data[2] -= 1;
            },
            Input.Key.d => {
                call_translate -= 1;
                camera_translate.data[0] -= 1;
            },
            Input.Key.a => {
                call_translate -= 1;
                camera_translate.data[0] += 1;
            },
            Input.Key.left_control => {
                call_translate -= 1;
                camera_translate.data[1] -= 1;
            },
            Input.Key.left_shift => {
                activate_sprint = false;
            },
            Input.Key.space => {
                call_translate -= 1;
                camera_translate.data[1] += 1;
            },
            else => {},
        }
    }
}

fn menuKeyInputFn(event: Input.KeyEvent) void {
    if (event.action == .press) {
        switch (event.key) {
            Input.Key.escape => {
                input.setCursorPosCallback(gameCursorPosInputFn);
                input.setKeyCallback(gameKeyInputFn);
                input.setImguiWantInput(false);
                input.setInputModeCursor(.disabled) catch {};

                // ignore first 5 frames of input after
                mouse_ignore_frames = 5;
            },
            else => {},
        }
    }
}

fn mouseBtnInputFn(event: Input.MouseButtonEvent) void {
    if (event.action == Input.Action.press) {
        if (event.button == Input.MouseButton.left) {} else if (event.button == Input.MouseButton.right) {}
    }
    if (event.action == Input.Action.release) {
        if (event.button == Input.MouseButton.left) {} else if (event.button == Input.MouseButton.right) {}
    }
}

fn gameCursorPosInputFn(event: Input.CursorPosEvent) void {
    const State = struct {
        var prev_event: ?Input.CursorPosEvent = null;
    };
    defer State.prev_event = event;

    if (mouse_ignore_frames == 0) {
        // let prev_event be defined before processing Input
        if (State.prev_event) |p_event| {
            mouse_delta.data[0] += @floatCast(f32, event.x - p_event.x);
            mouse_delta.data[1] += @floatCast(f32, event.y - p_event.y);
        }
        call_yaw = call_yaw or mouse_delta.x() < -0.00001 or mouse_delta.x() > 0.00001;
        call_pitch = call_pitch or mouse_delta.y() < -0.00001 or mouse_delta.y() > 0.00001;
    }
    mouse_ignore_frames = if (mouse_ignore_frames > 0) mouse_ignore_frames - 1 else 0;
}

fn menuCursorPosInputFn(event: Input.CursorPosEvent) void {
    _ = event;
}
