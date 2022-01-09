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
const Octree = @import("voxel_rt/Octree.zig");

pub const application_name = "zig vulkan";

// TODO: wrap this in render to make main seem simpler :^)
var window: glfw.Window = undefined;
var delta_time: f64 = 0;

var call_translate: u8 = 0;
var camera_translate = za.Vec3.zero();
var mouse_delta = za.Vec3.zero();

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
    window = glfw.Window.create(800, 800, application_name, null, null, .{ .focused = true, .center_cursor = true, .client_api = .no_api }) catch |err| {
        try stderr.print("failed to create window, code: {}", .{err});
        return;
    };
    defer window.destroy();
    try window.setInputMode(glfw.Window.InputMode.cursor, glfw.Window.InputModeCursor.disabled);

    const ctx = try render.Context.init(allocator, application_name, &window);
    defer ctx.deinit();

    // init input module with iput handler functions
    try input.init(window, keyInputFn, mouseBtnInputFn, cursorPosInputFn);
    defer input.deinit();

    var my_texture: render2d.TextureHandle = undefined;
    var my_sprite: render2d.Sprite = undefined;
    var draw_api = blk: {
        var init_api = try render2d.init(allocator, ctx, 1);

        my_texture = try init_api.loadTexture("../assets/images/tiger.jpg"[0..]);

        {
            const window_size = try window.getSize();
            const windowf = @intToFloat(f32, window_size.height);
            const size = @intToFloat(f32, window_size.height);
            const scale = za.Vec2.new(size, size);

            const pos = za.Vec2.new((windowf - scale[0]) * 0.5, (windowf - scale[0]) * 0.5);
            my_sprite = try init_api.createSprite(my_texture, pos, 0, scale);
        }
        break :blk try init_api.initDrawApi(.{ .every_ms = 9999 });
    };
    defer draw_api.deinit();

    draw_api.handleWindowResize(window);
    defer draw_api.noHandleWindowResize(window);

    var octree = blk: {
        const min_point = za.Vec3.new(-0.5, -0.5, -1.0);
        var builder = Octree.Builder.init(std.testing.allocator);
        break :blk try builder.withFloats(min_point, 1.0).withInts(2, 10).build(8 * 5);
    };
    octree.insert(&za.Vec3.new(0, 0, 0), 0);
    octree.insert(&za.Vec3.new(0.99, 0, 0), 1);

    var voxel_rt = try VoxelRT.init(allocator, ctx, octree, &draw_api.state.subo.ubo.my_texture);
    defer voxel_rt.deinit(ctx);

    var prev_frame = std.time.milliTimestamp();
    // Loop until the user closes the window
    while (!window.shouldClose()) {
        const current_frame = std.time.milliTimestamp();
        delta_time = @intToFloat(f64, current_frame - prev_frame) / @as(f64, std.time.ms_per_s);
        // f32 variant of delta_time
        const dt = @floatCast(f32, delta_time);

        if (call_translate > 0) {
            voxel_rt.camera.translate(dt, camera_translate);
            try voxel_rt.debug(ctx);
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
            input.Key.space => {
                call_translate += 1;
                camera_translate[1] -= 1;
            },
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
    std.debug.print("cursor pos: {s} {d}, {d} {s}\n", .{ "{", event.x, event.y, "}" });
}
