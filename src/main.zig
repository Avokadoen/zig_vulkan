const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const dbg = std.builtin.mode == std.builtin.Mode.Debug;

// TODO: update, see: https://github.com/prime31/zig-ecs/pull/10
// const ecs = @import("ecs");
const zalgebra = @import("zalgebra");

const c = @import("c.zig");
const vk = @import("vulkan");

const GLFWError = error {
    FailedToInit,
    WindowCreationFailed
};

// enable validation layer in debug
const enable_validation_layers = std.builtin.mode == .Debug;
const application_name = "zig vulkan";
const engine_name = "nop";

const BaseDispatch = vk.BaseWrapper([_]vk.BaseCommand{
    .create_instance,
    .enumerate_instance_extension_properties,
    .enumerate_instance_layer_properties,
});

const InstanceDispath = vk.InstanceWrapper([_]vk.InstanceCommand{
    .destroy_instance,
});

const GfxContext = struct {
    const Self = @This();

    vkb: BaseDispatch,
    vki: InstanceDispath,

    instance: vk.Instance,
    allocator: *Allocator,

    // Caller should make sure to call deinit
    pub fn init(allocator: *Allocator) !Self {
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

        // load base dispatch wrapper
        const vkb = try BaseDispatch.load(c.glfwGetInstanceProcAddress);

        // TODO: move to checkExtensions fn
        // // query extensions available
        // var supported_extensions_count: u32 = 0;
        // // ignore result, TODO: handle "VkResult.incomplete"
        // _ = try vkb.enumerateInstanceExtensionProperties(null, &supported_extensions_count, null);
        // var extensions = try ArrayList(vk.ExtensionProperties).initCapacity(allocator, supported_extensions_count);
        // _ = try vkb.enumerateInstanceExtensionProperties(null, &supported_extensions_count, extensions.items.ptr);
        // extensions.items.len = supported_extensions_count;
        // defer extensions.deinit();

        // for (extensions.items) |ext| {
        //     std.debug.print("{s}\n", .{ext.extension_name});
        // }

        const instanceInfo = vk.InstanceCreateInfo {
            .p_next = null,
            .flags = undefined,
            .p_application_info = &appInfo,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = undefined,
            .enabled_extension_count = @intCast(u32, glfw_extensions_count),
            .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, glfw_extensions_raw),
        };
        var instance = try vkb.createInstance(instanceInfo, null);
        
        const vki = try InstanceDispath.load(instance, c.glfwGetInstanceProcAddress);
        errdefer vki.destroyInstance(instance, null);
        
        const self = Self {
            .vkb = vkb,
            .vki = vki,
            .instance = instance,
            .allocator = allocator,
        };

        if (enable_validation_layers) {
            const validation_layers = [_][:0] const u8{ "VK_LAYER_KHRONOS_validation" };
            const is_valid = try isValidationLayersPresent(self, validation_layers[0..validation_layers.len]);
            if (!is_valid) {
                std.debug.panic("debug build without validation layer support", .{});
            }
        }

        return self;
    }

    /// check if validation layer exist
    pub fn isValidationLayersPresent(self: Self, target_layers: []const [:0]const u8) !bool {
        var layer_count: u32 = 0;
        // TODO: handle vk.INCOMPLETE
        _ = try self.vkb.enumerateInstanceLayerProperties(&layer_count, null);

        var available_layers = try ArrayList(vk.LayerProperties).initCapacity(self.allocator, layer_count);
        _ = try self.vkb.enumerateInstanceLayerProperties(&layer_count, available_layers.items.ptr);
        available_layers.items.len = layer_count;

        for (target_layers) |target_layer| {
            // check if target layer exist in available_layers
            for (available_layers.items) |available_layer| {
                const layer_name = available_layer.layer_name;
                // TODO: not proper way of comparing two c strings
                if (std.mem.eql(u8, target_layer, layer_name[0..layer_name.len])) {
                    break;
                }
            } else return false;
        }

        return true;
    }


    pub fn deinit(self: Self) void {
        self.vki.destroyInstance(self.instance, null);
    }
};

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
    
    // Make the window's context current 
    c.glfwMakeContextCurrent(window);
    // Construct our vulkan instance
    const ctx = try GfxContext.init(&gpa.allocator);
    defer ctx.deinit();

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
