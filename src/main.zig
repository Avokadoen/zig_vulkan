const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// Source: https://vulkan-tutorial.com

const dbg = std.builtin.mode == std.builtin.Mode.Debug;

const ecs = @import("ecs");
const zalgebra = @import("zalgebra");
const glfw = @import("glfw");
const stbi = @import("stbi");

const c = @import("c.zig"); 
const vk = @import("vulkan");

const renderer = @import("renderer/renderer.zig");
const consts = renderer.consts;

const GLFWError = error{ FailedToInit, WindowCreationFailed };

pub const application_name = "zig vulkan";
var pipeline: renderer.ApplicationGfxPipeline = undefined;

pub fn main() anyerror!void {
    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    // TODO: use c_allocator in optimized compile mode since we have to link with libc anyways
    // create a gpa with default configuration
    var alloc = if (consts.enable_validation_layers) std.heap.GeneralPurposeAllocator(.{}){} else std.heap.c_allocator;
    defer {
        if (consts.enable_validation_layers) {
            const leak = alloc.deinit();
            if (leak) {
                // TODO: lazy error handling can be improved
                // If error occur here we are screwed anyways
                stderr.print("leak detected in gpa!", .{}) catch unreachable;
            }
        }
    }
    var allocator = if (consts.enable_validation_layers) &alloc.allocator else alloc;
    
    // Initialize the library *
    try glfw.init();
    defer glfw.terminate();

    if (!glfw.vulkanSupported()) {
        std.debug.panic("vulkan not supported on device (glfw)", .{});
    }

    // Tell glfw that we are planning to use a custom API (not opengl)
    try glfw.Window.hint(glfw.client_api, glfw.no_api);

    // Create a windowed mode window 
    var window = glfw.Window.create(800, 600, application_name, null, null) catch |err| {
        try stderr.print("failed to create window, code: {}", .{err});
        return;
    };
    defer window.destroy();

    var writers = renderer.Writers{ .stdout = &stdout, .stderr = &stderr };
    // Construct our vulkan instance
    const ctx = try renderer.Context.init(allocator, application_name, &window, &writers);
    defer ctx.deinit();

    // const gfx_pipe
    pipeline = try renderer.ApplicationGfxPipeline.init(allocator, ctx);
    _ = window.setFramebufferSizeCallback(framebufferSizeCallbackFn);
    defer {
        _ = window.setFramebufferSizeCallback(null);
        pipeline.deinit(ctx);
    }
    
    const my_texture = try renderer.Texture.from_file(ctx, allocator, pipeline.command_pool, "assets\\images\\texture.jpg"[0..]);
    defer my_texture.deinit(ctx);

    // Loop until the user closes the window
    while (!window.shouldClose()) {
        // Render here
        try pipeline.draw(ctx);

        // Swap front and back buffers
        window.swapBuffers();

        // Poll for and process events
        try glfw.pollEvents();
    }
}

fn framebufferSizeCallbackFn(window: ?*glfw.RawWindow, width: c_int, height: c_int) callconv(.C) void {
    _ = window;
    _ = width;
    _ = height;
    pipeline.requested_rescale_pipeline = true;
}
