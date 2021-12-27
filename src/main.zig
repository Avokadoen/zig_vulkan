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

    var my_textures: [4]render2d.TextureHandle = undefined;
    var my_sprites: [25]render2d.Sprite = undefined;
    var draw_api = blk: {
        var init_api = try render2d.init(allocator, ctx, 25);

        my_textures[0] = try init_api.loadTexture("../assets/images/grasstop.png"[0..]);
        my_textures[1] = try init_api.loadTexture("../assets/images/texture.jpg"[0..]);
        my_textures[2] = try init_api.loadTexture("../assets/images/bern_burger.jpg"[0..]);
        my_textures[3] = try init_api.loadTexture("../assets/images/tiger.jpg"[0..]);

        {
            const window_size = try window.getSize();
            const windowf = @intToFloat(f32, window_size.height);
            const size = @intToFloat(f32, window_size.height) / @as(f32, 5);
            const scale = zlm.Vec2.new(size, size);

            const pos_offset_x = (windowf - scale.x) * 0.5;
            const pos_offset_y = (windowf - scale.y) * 0.5;

            var rotation: f32 = 0;
            var i: f32 = 0;
            outer: while (i < 5) : (i += 1) {
                var j: f32 = 0;
                while (j < 5) : (j += 1) {
                    const index = i * 5 + j;
                    if (index > 24) break :outer;

                    const texture_handle = my_textures[@floatToInt(usize, @mod(index, 4))];
                    const pos = zlm.Vec2.new(j * scale.x - pos_offset_x, i * scale.y - pos_offset_y);
                    my_sprites[@floatToInt(usize, index)] = try init_api.createSprite(texture_handle, pos, rotation, scale);
                    rotation += 10;
                    rotation = @mod(rotation, 360);
                }
            }
        }
        break :blk try init_api.initDrawApi(.{ .every_ms = 14 });
    };
    defer draw_api.deinit();

    draw_api.handleWindowResize(window);
    defer draw_api.noHandleWindowResize(window);

    var camera = draw_api.createCamera(500, 2);
    var camera_translate = zlm.Vec2.zero;

    var sin_wave: f32 = 0;
    var sin_dir: f32 = 1;

    var prev_frame = std.time.milliTimestamp();

    try my_sprites[1].setLayer(2);
    my_sprites[1].setSize(zlm.Vec2.new(500, 500));
    my_sprites[1].setPosition(zlm.Vec2.new(150, 150));

    try my_sprites[0].setLayer(3);
    my_sprites[0].setSize(zlm.Vec2.new(500, 500));
    my_sprites[0].setPosition(zlm.Vec2.new(0, 0));
    my_sprites[0].setTexture(my_textures[2]);

    try my_sprites[0].setLayer(1);
    try my_sprites[12].setLayer(4);
    my_sprites[12].setSize(zlm.Vec2.new(100, 100));

    const comp_pipeline = try render.ComputePipeline.init(allocator, ctx, "../../comp.comp.spv", &draw_api.state.subo.ubo.my_texture);
    defer comp_pipeline.deinit(ctx);

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

        sin_wave += @floatCast(f32, delta_time);
        sin_dir = if (@mod(sin_wave, 2) < 1) 1 else -1;
        const offset = std.math.sin(sin_wave);
        for (my_sprites[2..]) |*my_sprite| {
            var pos = my_sprite.getPosition();
            pos.x += offset * sin_dir * 0.2;
            my_sprite.setPosition(pos);

            var rot = my_sprite.getRotation();
            rot -= @floatCast(f32, 60 * delta_time);
            my_sprite.setRotation(rot);
        }
        {
            // Test compute
            try comp_pipeline.compute(ctx);

            // Render here
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
