const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// Source: https://vulkan-tutorial.com

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
    .CreateInstance,
    .EnumerateInstanceExtensionProperties,
    .EnumerateInstanceLayerProperties,
});

const InstanceDispatch = vk.InstanceWrapper([_]vk.InstanceCommand{
    .DestroyInstance,
    .CreateDebugUtilsMessengerEXT,
    .DestroyDebugUtilsMessengerEXT,
});

// TODO: Unit testing
const GfxContext = struct {
    const Self = @This();

    allocator: *Allocator,

    vkb: BaseDispatch,
    vki: InstanceDispatch,

    instance: vk.Instance,
    // TODO: utilize comptime for this
    messenger: ?vk.DebugUtilsMessengerEXT,

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

        const application_extensions = blk: {
            if (enable_validation_layers) {
                break :blk [_][*:0] const u8 { 
                    vk.extension_info.ext_debug_report.name, 
                    vk.extension_info.ext_debug_utils.name 
                };
            }
            break :blk [_][*:0] const u8 { };
        };
        const extensions = try getRequiredInstanceExtensions(allocator, application_extensions[0..application_extensions.len]);
        defer extensions.deinit();

        // load base dispatch wrapper
        const vkb = try BaseDispatch.load(c.glfwGetInstanceProcAddress);

        var enabled_layer_count: u8 = 0;
        var enabled_layer_names: [*]const [*:0]const u8 = undefined;
        if (enable_validation_layers) {
            const validation_layers = [_][*:0] const u8{ "VK_LAYER_KHRONOS_validation" };
            const is_valid = try isValidationLayersPresent(allocator, vkb, validation_layers[0..validation_layers.len]);
            if (!is_valid) {
                std.debug.panic("debug build without validation layer support", .{});
            }
            enabled_layer_count = validation_layers.len;
            enabled_layer_names = @ptrCast([*]const [*:0]const u8, &validation_layers);
        }

        const instanceInfo = vk.InstanceCreateInfo {
            .p_next = null,
            .flags = undefined,
            .p_application_info = &appInfo,
            .enabled_layer_count = enabled_layer_count,
            .pp_enabled_layer_names = enabled_layer_names,
            .enabled_extension_count = @intCast(u32, extensions.items.len),
            .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, extensions.items.ptr),
        };
        var instance = try vkb.createInstance(instanceInfo, null);
        
        const vki = try InstanceDispatch.load(instance, c.glfwGetInstanceProcAddress);
        errdefer vki.destroyInstance(instance, null);

        const messenger = try setupDebugCallback(vki, instance);
        
        return Self {
            .vkb = vkb,
            .vki = vki,
            .instance = instance,
            .allocator = allocator,
            .messenger = messenger,
        };
    }

    pub fn deinit(self: Self) void {
        if (enable_validation_layers) {
            // broken, see: https://github.com/Snektron/vulkan-zig/issues/13
            self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.messenger.?, null);
        }

        self.vki.destroyInstance(self.instance, null);
    }
};

/// check if validation layer exist
fn isValidationLayersPresent(allocator: *Allocator, vkb: BaseDispatch, target_layers: []const [*:0]const u8) !bool {
    var layer_count: u32 = 0;
    // TODO: handle vk.INCOMPLETE
    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, null);

    var available_layers = try ArrayList(vk.LayerProperties).initCapacity(allocator, layer_count);
    defer available_layers.deinit();

    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, available_layers.items.ptr);
    available_layers.items.len = layer_count;

    for (target_layers) |target_layer| {
        // check if target layer exist in available_layers
        inner: for (available_layers.items) |available_layer| {
            const layer_name = available_layer.layer_name;
            // if target_layer and available_layer is the same
            if (std.cstr.cmp(target_layer, @ptrCast([*:0]const u8, &layer_name)) == 0) {
                break :inner;
            }
        } else return false; // if our loop never break, then a requested layer is missing
    }

    return true;
}

// TODO (see isValidationLayersPresent())
// fn isExtensionsPresent(allocator: *Allocator, vkb, target_extensions: []const [*:0]const u8) !bool {
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
// }

/// Caller must deinit returned ArrayList
fn getRequiredInstanceExtensions(allocator: *Allocator, target_extensions: []const [*:0] const u8) !ArrayList([*:0]const u8) {
    var glfw_extensions_count: u32 = 0;
    const glfw_extensions_raw = c.glfwGetRequiredInstanceExtensions(&glfw_extensions_count);
    const glfw_extensions_slice = glfw_extensions_raw[0..glfw_extensions_count];

    var extensions = try ArrayList([*:0]const u8).initCapacity(allocator, glfw_extensions_count + 1);

    for (glfw_extensions_slice) |extension| {
        try extensions.append(extension);
    }

    for (target_extensions) |extension| {
        try extensions.append(extension);
    }

    return extensions;
}

fn messageCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT.IntType,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT.IntType,
    p_callback_data: *const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: *c_void,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    // TODO: pass stdout in p_user_data or otherwise avoid global stdout
    stdout.print("validation layer: {s}\n", .{p_callback_data.p_message}) catch { 
        std.debug.print("error from stdout print in message callback", .{});
    };
    return vk.FALSE;
}

fn setupDebugCallback(vki: InstanceDispatch, instance: vk.Instance) !?vk.DebugUtilsMessengerEXT {
    if (!enable_validation_layers) return null;

    const message_severity = vk.DebugUtilsMessageSeverityFlagsEXT {
        .verbose_bit_ext = true,
        .warning_bit_ext = true,
        .error_bit_ext = true,
    };

    const message_type = vk.DebugUtilsMessageTypeFlagsEXT {
        .general_bit_ext = true,
        .validation_bit_ext = true,
        .performance_bit_ext = true,
    };

    const create_info = vk.DebugUtilsMessengerCreateInfoEXT {
        .flags = vk.DebugUtilsMessengerCreateFlagsEXT { },
        .message_severity = message_severity,
        .message_type = message_type,
        .pfn_user_callback = messageCallback,
        .p_user_data = null,
    };

    return vki.createDebugUtilsMessengerEXT(instance, create_info, null) catch {
        std.debug.panic("failed to create debug messenger", .{});
    };
}


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

var stdout: std.fs.File.Writer = undefined;

pub fn main() anyerror!void {
    const stderr = std.io.getStdErr().writer();
    stdout = std.io.getStdOut().writer();

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
