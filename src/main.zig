const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const glfw = @import("glfw");
const za = @import("zalgebra");

const render = @import("render/render.zig");
const swapchain = render.swapchain;
const consts = render.consts;

const input = @import("input.zig");
const render2d = @import("render2d/render2d.zig");

// TODO: API topology
const VoxelRT = @import("voxel_rt/VoxelRT.zig");
const BrickGrid = @import("voxel_rt/brick/Grid.zig");
const gpu_types = @import("voxel_rt/gpu_types.zig");
const vox = VoxelRT.vox;
const terrain = @import("voxel_rt/terrain/terrain.zig");

pub const application_name = "zig vulkan";

// TODO: wrap this in render to make main seem simpler :^)
var window: glfw.Window = undefined;
var delta_time: f64 = 0;

var activate_sprint: bool = false;
var call_translate: u8 = 0;
var camera_translate = za.Vec3.zero();

var call_yaw = false;
var call_pitch = false;
var mouse_delta = za.Vec2.zero();

var push_terrain_changes = true;

pub fn main() anyerror!void {
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
    window = glfw.Window.create(1920, 1080, application_name, null, null, 
    .{ 
        .center_cursor = true, 
        .client_api = .no_api,
        // .maximized = true,
        // .scale_to_monitor = true,
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

    // init input module with iput handler functions
    try input.init(window, keyInputFn, mouseBtnInputFn, cursorPosInputFn);
    defer input.deinit();

    var my_texture: render2d.TextureHandle = undefined;
    var my_sprite: render2d.Sprite = undefined;
    var draw_api = blk: {
        var init_api = try render2d.init(allocator, ctx, 1);
        my_texture = try init_api.loadEmptyTexture(1280, 720);

        {
            const window_size = try window.getSize();
            const window_w = @intToFloat(f32, window_size.width);
            const window_h = @intToFloat(f32, window_size.height);
            const scale = za.Vec2.new(window_w, window_h);

            const pos = za.Vec2.new((window_w - scale[0]) * 0.5, (window_h - scale[1]) * 0.5);
            my_sprite = try init_api.createSprite(my_texture, pos, 0, scale);
        }
        break :blk try init_api.initDrawApi(.{ .every_ms = 99999 });
    };
    defer draw_api.deinit();

    draw_api.handleWindowResize(window);
    defer draw_api.noHandleWindowResize(window);

    var grid = try BrickGrid.init(allocator, 64, 64, 64, .{ .min_point = [3]f32{ -32, -32, -32 } });
    defer grid.deinit();

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
        albedo_color[index] = .{ .color = za.Vec4.new(@intToFloat(f32, rgba.r) / 255, @intToFloat(f32, rgba.g) / 255, @intToFloat(f32, rgba.b) / 255, @intToFloat(f32, rgba.a) / 255) };
        materials[index] = .{ .@"type" = .lambertian, .type_index = 0, .albedo_index = @intCast(u15, index) };
    }

    // Test what we are loading
    for (model.xyzi_chunks[0]) |xyzi| {
        grid.insert(@intCast(usize, xyzi.x), @intCast(usize, xyzi.z), @intCast(usize, xyzi.y), xyzi.color_index);
    }
    const terrain_thread = try std.Thread.spawn(.{}, terrain.generate, .{ 420, 4, 20, &grid });
    defer terrain_thread.join();

    var voxel_rt = try VoxelRT.init(allocator, ctx, &grid, &draw_api.state.subo.ubo.my_texture, .{});
    defer voxel_rt.deinit(ctx);

    try voxel_rt.pushAlbedo(ctx, albedo_color[0..]);
    try voxel_rt.pushMaterials(ctx, materials[0..]);

    var prev_frame = std.time.milliTimestamp();
    try window.setInputMode(glfw.Window.InputMode.cursor, glfw.Window.InputModeCursor.disabled);
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
            voxel_rt.camera.turnYaw(-mouse_delta[0] * dt);
        }
        if (call_pitch) {
            voxel_rt.camera.turnPitch(mouse_delta[1] * dt);
        }
        if (call_translate > 0 or call_yaw or call_pitch) {
            try voxel_rt.debugMoveCamera(ctx);
            call_yaw = false;
            call_pitch = false;
            mouse_delta[0] = 0;
            mouse_delta[1] = 0;
        }
        if (push_terrain_changes) {
            try voxel_rt.debugUpdateTerrain(ctx);
        }

        {
            voxel_rt.brick_grid.*.pollWorkers(dt);
            //
            try voxel_rt.compute(ctx);

            // Render 2d stuff
            try draw_api.draw();
        }

        // Poll for and process events
        try glfw.pollEvents();
        prev_frame = current_frame;
    }
}

fn keyInputFn(event: input.KeyEvent) void {
    if (event.action == .press) {
        switch (event.key) {
            input.Key.w => {
                call_translate += 1;
                camera_translate[2] -= 1;
            },
            input.Key.s => {
                call_translate += 1;
                camera_translate[2] += 1;
            },
            input.Key.d => {
                call_translate += 1;
                camera_translate[0] += 1;
            },
            input.Key.a => {
                call_translate += 1;
                camera_translate[0] -= 1;
            },
            input.Key.left_control => {
                call_translate += 1;
                camera_translate[1] += 1;
            },
            input.Key.left_shift => activate_sprint = true,
            input.Key.space => {
                call_translate += 1;
                camera_translate[1] -= 1;
            },
            input.Key.t => push_terrain_changes = !push_terrain_changes,
            input.Key.escape => window.setShouldClose(true),
            else => {},
        }
    } else if (event.action == .release) {
        switch (event.key) {
            input.Key.w => {
                call_translate -= 1;
                camera_translate[2] += 1;
            },
            input.Key.s => {
                call_translate -= 1;
                camera_translate[2] -= 1;
            },
            input.Key.d => {
                call_translate -= 1;
                camera_translate[0] -= 1;
            },
            input.Key.a => {
                call_translate -= 1;
                camera_translate[0] += 1;
            },
            input.Key.left_control => {
                call_translate -= 1;
                camera_translate[1] -= 1;
            },
            input.Key.left_shift => {
                activate_sprint = false;
            },
            input.Key.space => {
                call_translate -= 1;
                camera_translate[1] += 1;
            },
            else => {},
        }
    }
}

fn mouseBtnInputFn(event: input.MouseButtonEvent) void {
    if (event.action == input.Action.press) {
        if (event.button == input.MouseButton.left) {} else if (event.button == input.MouseButton.right) {}
    }
    if (event.action == input.Action.release) {
        if (event.button == input.MouseButton.left) {} else if (event.button == input.MouseButton.right) {}
    }
}

fn cursorPosInputFn(event: input.CursorPosEvent) void {
    const State = struct {
        var prev_event: ?input.CursorPosEvent = null;
    };
    defer State.prev_event = event;

    // let prev_event be defined before processing input
    if (State.prev_event) |p_event| {
        mouse_delta[0] += @floatCast(f32, event.x - p_event.x);
        mouse_delta[1] += @floatCast(f32, event.y - p_event.y);
    }
    call_yaw = call_yaw or mouse_delta[0] < -0.00001 or mouse_delta[0] > 0.00001;
    call_pitch = call_pitch or mouse_delta[1] < -0.00001 or mouse_delta[1] > 0.00001;
}
