const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// Source: https://vulkan-tutorial.com

const dbg = std.builtin.mode == std.builtin.Mode.Debug;

const ecs = @import("ecs");
const zalgebra = @import("zalgebra");

const c = @import("c.zig"); 
const vk = @import("vulkan");

const renderer = @import("renderer/renderer.zig");
const constants = renderer.constant;

const GLFWError = error{ FailedToInit, WindowCreationFailed };

pub const application_name = "zig vulkan";

// TODO: rewrite this
fn handleGLFWError() noreturn {
    var description: [*c][*c]u8 = null;
    switch (c.glfwGetError(description)) {
        c.GLFW_NOT_INITIALIZED => {
            // TODO: use stderr
            // std.debug.print("Error description: {s}", .{std.mem.span(description.*)});
            std.debug.panic("GLFW not initialized, call glfwInit()", .{});
        },
        else => |err_code| {
            std.debug.panic("unhandeled glfw error {d}", .{err_code});
        },
    }
}

pub fn main() anyerror!void {
    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    // TODO: use c_allocator in optimized compile mode since we have to link with libc anyways
    // create a gpa with default configuration
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak = gpa.deinit();
        if (leak) {
            // TODO: lazy error handling can be improved
            // If error occur here we are screwed anyways
            stderr.print("leak detected in gpa!", .{}) catch unreachable;
        }
    }

    // Initialize the library *
    if (c.glfwInit() == c.GLFW_FALSE) {
        return GLFWError.FailedToInit;
    }
    defer c.glfwTerminate();

    // Tell glfw that we are planning to use a custom API (not opengl)
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    // We will not support resizing window (yet)
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_FALSE);

    if (c.glfwVulkanSupported() == c.GLFW_FALSE) {
        std.debug.panic("vulkan not supported on device (glfw)", .{});
    }

    // Create a windowed mode window and its OpenGL context
    var window: *c.GLFWwindow = blk: {
        if (c.glfwCreateWindow(640, 480, application_name, null, null)) |created_window| {
            break :blk created_window;
        } else {
            handleGLFWError();
        }
    };
    defer c.glfwDestroyWindow(window);

    // Make the window's context current
    c.glfwMakeContextCurrent(window);

    // TODO: find a way to convert to const
    var writers = renderer.Writers{ .stdout = &stdout, .stderr = &stderr };
    // Construct our vulkan instance
    const ctx = try renderer.Context.init(&gpa.allocator, application_name, window, &writers);
    defer ctx.deinit();

    // const gfx_pipe
    const pipeline = try renderer.ApplicationPipeline.init(&gpa.allocator, ctx);
    defer pipeline.deinit(ctx);

    // Loop until the user closes the window
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        // Render here
        pipeline.draw(ctx);

        // Swap front and back buffers
        c.glfwSwapBuffers(window);

        // Poll for and process events
        c.glfwPollEvents();
    }
}
