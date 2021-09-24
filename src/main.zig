const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// Source: https://vulkan-tutorial.com

const ecs = @import("ecs");
const za = @import("zalgebra");
const glfw = @import("glfw");

const renderer = @import("renderer/renderer.zig");
const swapchain = renderer.swapchain;
const consts = renderer.consts;

const input = @import("input.zig");

pub const application_name = "zig vulkan";

// TODO: wrap this in renderer to make main seem simpler :^)
var allocator: *Allocator = undefined;
var ctx: renderer.Context = undefined;
var sc_data: swapchain.Data = undefined;
var view: swapchain.ViewportScissor = undefined;
var subo: renderer.SyncUniformBuffer = undefined;
var gfx_pipeline: renderer.ApplicationGfxPipeline = undefined;

pub fn main() anyerror!void {
    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

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
    allocator = if (consts.enable_validation_layers) &alloc.allocator else alloc;
    
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
    ctx = try renderer.Context.init(allocator, application_name, &window, &writers);
    defer ctx.deinit();

    sc_data = try swapchain.Data.init(allocator, ctx, null);
    defer sc_data.deinit(ctx);

    view = swapchain.ViewportScissor.init(sc_data.extent);

    subo = try renderer.SyncUniformBuffer.init(allocator, ctx, sc_data.images.items.len, view.viewport[0]);
    defer subo.deinit(ctx);

    gfx_pipeline = try renderer.ApplicationGfxPipeline.init(allocator, ctx, &sc_data, &view, &subo);
    _ = window.setFramebufferSizeCallback(framebufferSizeCallbackFn);
    defer {
        _ = window.setFramebufferSizeCallback(null);
        gfx_pipeline.deinit(ctx);
    }

    _ = window.setKeyCallback(input.keyCallback); 
    defer _ = window.setKeyCallback(null);

    try input.init(inputFn);
    var input_thread = try std.Thread.spawn(.{}, input.handleInput, .{} );
    defer input_thread.join(); 
    
    // Loop until the user closes the window
    while (!window.shouldClose()) {
        { // TODO: these can be moved to a secondary thread
            // Render here
            try gfx_pipeline.draw(ctx);

            // Swap front and back buffers
            window.swapBuffers();
        }

        // Poll for and process events
        try glfw.pollEvents();
    }

    input.deinit();
}

fn inputFn(event: input.Event) void {
    // TODO: only tell ubo desired change for easier deltatime and less racy code!
    switch(event.key) {
        input.Key.w => subo.ubo.data.view.data[1][3] += 0.001,
        input.Key.s => subo.ubo.data.view.data[1][3] -= 0.001,
        input.Key.d => subo.ubo.data.view.data[0][3] -= 0.001,
        input.Key.a => subo.ubo.data.view.data[0][3] += 0.001,
        else => {},
    }   
} 

/// called by glfw to message pipelines about scaling
/// this should never be registered before pipeline init
fn framebufferSizeCallbackFn(window: ?*glfw.RawWindow, width: c_int, height: c_int) callconv(.C) void {
    _ = window;
    _ = width;
    _ = height;

    // recreate swapchain utilizing the old one 
    const old_swapchain = sc_data;
    sc_data = swapchain.Data.init(allocator, ctx, old_swapchain.swapchain) catch |err| {
        std.debug.panic("failed to resize swapchain, err {any}", .{err}) catch unreachable;
    };
    old_swapchain.deinit(ctx);

    // recreate view from swapchain extent
    view = swapchain.ViewportScissor.init(sc_data.extent);
    
    gfx_pipeline.sc_data = &sc_data;
    gfx_pipeline.view = &view;
    gfx_pipeline.requested_rescale_pipeline = true;
}

