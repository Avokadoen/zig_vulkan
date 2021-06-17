const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
pub const OutOfMemory = error{OutOfMemory};
const ArrayList = std.ArrayList;
const dbg = std.builtin.mode == std.builtin.Mode.Debug;

const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});
const vk = @import("vulkan");

const GLFWError = error {
    FailedToInit,
    WindowCreationFailed
};

fn handleGLFWError() noreturn {
    var description: [*c][*c]u8 = null;
    switch (c.glfwGetError(description)) {
        c.GLFW_NOT_INITIALIZED => {
            // TODO: use stderr
            // std.debug.print("Error description: {s}", .{std.mem.span(description.*)});
            std.debug.panic("GLFW not initialized, call glfwInit", .{});
        },
        else => |err_code| {
            std.debug.panic("Unhandeled glfw error {d}", .{err_code});
        }
    }
}

pub fn main() anyerror!void {
    const stderr = std.io.getStdErr().writer();

    // TODO: use c_allocator in optimized compile mode since we have to link with libc anyways
    // create a gpa with default configuration
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak = gpa.deinit();
        if (leak) {
            // TODO: lazy error handling can be improved
            // If error occur here we are screwed anyways 
            stderr.print("Leak detected in gpa!", .{}) catch unreachable;
        }
    }

    // Initialize the library *
    if (c.glfwInit() == c.GLFW_FALSE) {
        return GLFWError.FailedToInit;
    }
    defer c.glfwTerminate();

    // Create a windowed mode window and its OpenGL context
    var window: *c.GLFWwindow = blk: {
        if (c.glfwCreateWindow(640, 480, "Hello World", null, null)) |created_window| {
            break :blk created_window;
        } else {
            handleGLFWError();
        }
    };   
    
    // Make the window's context current 
    c.glfwMakeContextCurrent(window);

    // Loop until the user closes the window 
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE)
    {
        // Render here 

        // Swap front and back buffers 
        c.glfwSwapBuffers(window);

        // Poll for and process events 
        c.glfwPollEvents();
    }

}
