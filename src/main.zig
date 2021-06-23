const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const dbg = std.builtin.mode == std.builtin.Mode.Debug;

const ecs = @import("ecs");
const zalgebra = @import("zalgebra");

const c = @import("c.zig");
const vk = @import("vulkan");

const GLFWError = error {
    FailedToInit,
    WindowCreationFailed
};

// enable validation layer in debug
const enable_validation_layers = std.debug.builtin.mode == .Debug;
const application_name = "zig vulkan";
const engine_name = "nop";

// Base used to load initial instance
const BaseDispatch = struct {
    vkCreateInstance: vk.PfnCreateInstance,
    usingnamespace vk.BaseWrapper(@This());
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

// // source: https://github.com/andrewrk/zig-vulkan-triangle/blob/04c344e20451650b43b2b5b0216bb8d286813dfc/src/main.zig#L883
// fn debugCallback(
//     flags: vk.DebugReportFlagsEXT,
//     objType: vk.DebugReportObjectTypeEXT,
//     obj: u64,
//     location: usize,
//     code: i32,
//     layerPrefix: [*:0]const u8,
//     msg: [*:0]const u8,
//     userData: ?*c_void,
// ) callconv(.C) vk.Bool32 {
//     std.debug.warn("validation layer: {s}\n", .{msg});
//     return vk.FALSE;
// }

// fn setupDebugCallback() error{FailedToSetUpDebugCallback}!void {
//     if (!enableValidationLayers) return;

//     var createInfo = vk.DebugReportCallbackCreateInfoEXT {
        /// toint
//         .flags = vk.DebugReportFlagsEXT.error_bit_ext  vk.DebugReportFlagsEXT.warning_bit_ext,
//         .pfnCallback = debugCallback,
//         .pNext = null,
//         .pUserData = null,
//     };

//     if (CreateDebugReportCallbackEXT(&createInfo, null, &callback) != vk.SUCCESS) {
//         return error.FailedToSetUpDebugCallback;
//     }
// }

// fn CreateDebugReportCallbackEXT(
//     pCreateInfo: *const c.VkDebugReportCallbackCreateInfoEXT,
//     pAllocator: ?*const c.VkAllocationCallbacks,
//     pCallback: *c.VkDebugReportCallbackEXT,
// ) c.VkResult {
//     const func = @ptrCast(c.PFN_vkCreateDebugReportCallbackEXT, vk.GetInstanceProcAddr(
//         instance,
//         "vkCreateDebugReportCallbackEXT",
//     )) orelse return c.VK_ERROR_EXTENSION_NOT_PRESENT;
//     return func(instance, pCreateInfo, pAllocator, pCallback);
// }


// vk.Instance
fn createVkInstance() !vk.Instance {
    const appInfo = vk.ApplicationInfo {
        .p_next = null,
        .p_application_name = application_name,
        .application_version = vk.makeApiVersion(0, 0, 0, 1),
        .p_engine_name = engine_name,
        .engine_version = vk.makeApiVersion(0, 0, 0, 1),
        .api_version = vk.API_VERSION_1_2,
    };

    var glfw_extensions_count: u32 = 0;
    const glfw_extensions_raw = c.glfwGetRequiredInstanceExtensions(&glfw_extensions_count);

    const vkb = try BaseDispatch.load(c.glfwGetInstanceProcAddress);
    const instanceInfo = vk.InstanceCreateInfo {
        .p_next = null,
        .flags = undefined,
        .p_application_info = &appInfo,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = @intCast(u32, glfw_extensions_count),
        .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, glfw_extensions_raw),
    };
    return try vkb.createInstance(instanceInfo, null);
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

    // Tell glfw that we are planning to use a custom API (not opengl)
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    // We will not support resizing window (yet)
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_FALSE);

    if (c.glfwVulkanSupported() == c.GLFW_FALSE) {
         std.debug.panic("Vulkan not supported on device (glfw)", .{});
    }

    // Create a windowed mode window and its OpenGL context
    var window: *c.GLFWwindow = blk: {
        if (c.glfwCreateWindow(640, 480, application_name, null, null)) |created_window| {
            break :blk created_window;
        } else {
            handleGLFWError();
        }
    };   
    
    // Make the window's context current 
    c.glfwMakeContextCurrent(window);
    // Construct our vulkan instance
    const vkInstance = try createVkInstance();

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
