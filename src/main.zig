const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const glfw = @import("glfw");
const zlm = @import("zlm");

const render = @import("render/render.zig");
const swapchain = render.swapchain;
const consts = render.consts;

const input = @import("input.zig");
const render2d = @import("render2d/render2d.zig");

const VoxelRT = @import("voxel_rt/VoxelRT.zig");

pub const application_name = "zig vulkan";

// TODO: wrap this in render to make main seem simpler :^)
var window: glfw.Window = undefined;
var delta_time: f64 = 0;

var zoom_in = false;
var zoom_out = false;
var move_up = false;
var move_left = false;
var move_right = false;
var move_down = false;

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

    // Create a windowed mode window
    window = glfw.Window.create(800, 800, application_name, null, null, .{ .client_api = .no_api }) catch |err| {
        try stderr.print("failed to create window, code: {}", .{err});
        return;
    };
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

        my_texture = try init_api.loadTexture("../assets/images/grasstop.png"[0..]);

        {
            const window_size = try window.getSize();
            const windowf = @intToFloat(f32, window_size.height);
            const size = @intToFloat(f32, window_size.height);
            const scale = zlm.Vec2.new(size, size);

            const pos = zlm.Vec2.new((windowf - scale.x) * 0.5, (windowf - scale.y) * 0.5);
            my_sprite = try init_api.createSprite(my_texture, pos, 0, scale);
        }
        break :blk try init_api.initDrawApi(.{ .every_ms = 9999 });
    };
    defer draw_api.deinit();

    draw_api.handleWindowResize(window);
    defer draw_api.noHandleWindowResize(window);

    var camera = draw_api.createCamera(500, 2);
    var camera_translate = zlm.Vec2.zero;

    const voxel_rt = try VoxelRT.init(allocator, ctx, &draw_api.state.subo.ubo.my_texture);
    defer voxel_rt.deinit(ctx);

    var prev_frame = std.time.milliTimestamp();
    // Loop until the user closes the window
    while (!window.shouldClose()) {
        const current_frame = std.time.milliTimestamp();
        delta_time = @intToFloat(f64, current_frame - prev_frame) / @as(f64, std.time.ms_per_s);
        // f32 variant of delta_time
        const dt = @floatCast(f32, delta_time);

        if (zoom_in) {
            camera.zoomIn(dt);
        }
        if (zoom_out) {
            camera.zoomOut(dt);
        }

        var call_translate = false;
        if (move_up) {
            camera_translate.y -= 1;
            call_translate = true;
        }
        if (move_down) {
            camera_translate.y += 1;
            call_translate = true;
        }
        if (move_right) {
            camera_translate.x += 1;
            call_translate = true;
        }
        if (move_left) {
            camera_translate.x -= 1;
            call_translate = true;
        }
        if (call_translate) {
            camera.translate(dt, camera_translate);
            camera_translate = zlm.Vec2.zero;
        }

        {
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
            input.Key.w => move_up = true,
            input.Key.s => move_down = true,
            input.Key.d => move_left = true,
            input.Key.a => move_right = true,
            input.Key.escape => window.setShouldClose(true),
            else => {},
        }
    } else if (event.action == .release) {
        switch (event.key) {
            input.Key.w => move_up = false,
            input.Key.s => move_down = false,
            input.Key.d => move_left = false,
            input.Key.a => move_right = false,
            else => {},
        }
    }
}

fn mouseBtnInputFn(event: input.MouseButtonEvent) void {
    if (event.action == input.Action.press) {
        if (event.button == input.MouseButton.left) {
            zoom_in = true;
        } else if (event.button == input.MouseButton.right) {
            zoom_out = true;
        }
    }
    if (event.action == input.Action.release) {
        if (event.button == input.MouseButton.left) {
            zoom_in = false;
        } else if (event.button == input.MouseButton.right) {
            zoom_out = false;
        }
    }
}

fn cursorPosInputFn(event: input.CursorPosEvent) void {
    _ = event;
    // std.debug.print("cursor pos: {s} {d}, {d} {s}\n", .{"{", event.x, event.y, "}"});
}
