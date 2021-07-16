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

const GLFWError = error{ FailedToInit, WindowCreationFailed };

const Writers = struct {
    stdout: *const std.fs.File.Writer,
    stderr: *const std.fs.File.Writer,
};

// enable validation layer in debug
const application_name = "zig vulkan";
const enable_validation_layers = std.builtin.mode == .Debug;
const engine_name = "nop";

const logicical_device_extensions = [_][*:0]const u8{ vk.extension_info.khr_swapchain.name };

const BaseDispatch = vk.BaseWrapper([_]vk.BaseCommand{
    .EnumerateInstanceLayerProperties,
    .EnumerateInstanceExtensionProperties,
    .CreateInstance,
});

const InstanceDispatch = vk.InstanceWrapper([_]vk.InstanceCommand{
    .CreateDebugUtilsMessengerEXT,
    .CreateDevice,
    .DestroyDebugUtilsMessengerEXT,
    .DestroyInstance,
    .DestroySurfaceKHR,
    .EnumerateDeviceExtensionProperties,
    .EnumeratePhysicalDevices,
    .GetDeviceProcAddr,
    .GetPhysicalDeviceFeatures,
    .GetPhysicalDeviceProperties,
    .GetPhysicalDeviceQueueFamilyProperties,
    .GetPhysicalDeviceSurfaceCapabilitiesKHR
    .GetPhysicalDeviceSurfacePresentModesKHR,
    .GetPhysicalDeviceSurfaceSupportKHR,
});

const DeviceDispatch = vk.DeviceWrapper([_]vk.DeviceCommand{
    .GetDeviceQueue,
    .DestroyDevice,
});

/// used to initialize different aspects of the GfxContext
var queue_indices: ?QueueFamilyIndices = null;

// TODO: Unit testing
const GfxContext = struct {
    const Self = @This();


    allocator: *Allocator,

    vkb: BaseDispatch,
    vki: InstanceDispatch,
    vkd: DeviceDispatch,

    instance: vk.Instance,
    physical_device: vk.PhysicalDevice,
    logical_device: vk.Device,

    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
    surface: vk.SurfaceKHR,

    // TODO: utilize comptime for this (emit from struct if we are in release mode)
    messenger: ?vk.DebugUtilsMessengerEXT,

    // Caller should make sure to call deinit
    pub fn init(allocator: *Allocator, window: *c.GLFWwindow, writers: *Writers) !Self {
        const appInfo = vk.ApplicationInfo{
            .p_next = null,
            .p_application_name = application_name,
            .application_version = vk.makeApiVersion(0, 0, 0, 1),
            .p_engine_name = engine_name,
            .engine_version = vk.makeApiVersion(0, 0, 0, 1),
            .api_version = vk.API_VERSION_1_2,
        };

        // TODO: move to global scope (currently crashes the zig compiler :') )
        const application_extensions = blk: {
            const common_extensions = [_][*:0]const u8{ vk.extension_info.khr_surface.name };
            if (enable_validation_layers) {
                const debug_extensions = [_][*:0]const u8{
                    vk.extension_info.ext_debug_report.name,
                    vk.extension_info.ext_debug_utils.name,
                } ++ common_extensions;
                break :blk debug_extensions[0..debug_extensions.len];
            }
            break :blk common_extensions[0..common_extensions.len];
        };

        const extensions = try getRequiredInstanceExtensions(allocator, application_extensions);
        defer extensions.deinit();

        // load base dispatch wrapper
        const vkb = try BaseDispatch.load(c.glfwGetInstanceProcAddress);
        if (!(try isInstanceExtensionsPresent(allocator, vkb, application_extensions))) {
            return error.InstanceExtensionNotPresent;
        }

        const validation_layer_info = try ValidationLayerInfo.init(allocator, vkb);

        var create_p_next: ?*c_void = null;
        if (enable_validation_layers) {
            var debug_create_info = createDefaultDebugCreateInfo(writers);
            create_p_next = @ptrCast(?*c_void, &debug_create_info);
        }

        const instanceInfo = vk.InstanceCreateInfo{
            .p_next = create_p_next,
            .flags = .{},
            .p_application_info = &appInfo,
            .enabled_layer_count = validation_layer_info.enabled_layer_count,
            .pp_enabled_layer_names = validation_layer_info.enabled_layer_names,
            .enabled_extension_count = @intCast(u32, extensions.items.len),
            .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, extensions.items.ptr),
        };

        const instance = try vkb.createInstance(instanceInfo, null);

        const vki = try InstanceDispatch.load(instance, c.glfwGetInstanceProcAddress);
        errdefer vki.destroyInstance(instance, null);

        const surface = try createSurface(instance, window);
        errdefer vki.destroySurfaceKHR(instance, surface, null);

        const physical_device = try selectPhysicalDevice(allocator, vki, instance, surface);

        queue_indices = try getQueueFamilyIndices(allocator, vki, physical_device, surface);

        const messenger = try setupDebugCallback(vki, instance, writers);
        const logical_device = try createLogicalDevice(allocator, vkb, vki, physical_device);

        const vkd = try DeviceDispatch.load(logical_device, vki.dispatch.vkGetDeviceProcAddr);
        const graphics_queue = vkd.getDeviceQueue(logical_device, queue_indices.?.graphics, 0);
        const present_queue = vkd.getDeviceQueue(logical_device, queue_indices.?.present, 0);

        return Self{
            .allocator = allocator,
            .vkb = vkb,
            .vki = vki,
            .vkd = vkd,
            .instance = instance,
            .physical_device = physical_device,
            .logical_device = logical_device,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .surface = surface,
            .messenger = messenger,
        };
    }

    pub fn deinit(self: Self) void {
        if (enable_validation_layers) {
            self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.messenger.?, null);
        }

        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        self.vkd.destroyDevice(self.logical_device, null);
        self.vki.destroyInstance(self.instance, null);
    }
};

/// check if validation layer exist
fn isValidationLayersPresent(allocator: *Allocator, vkb: BaseDispatch, target_layers: []const [*:0]const u8) !bool {
    var layer_count: u32 = 0;
    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, null);

    var available_layers = try ArrayList(vk.LayerProperties).initCapacity(allocator, layer_count);
    defer available_layers.deinit();

    // TODO: handle vk.INCOMPLETE (Array too small)
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

fn isInstanceExtensionsPresent(allocator: *Allocator, vkb: BaseDispatch, target_extensions: []const [*:0]const u8) !bool {
    // query extensions available
    var supported_extensions_count: u32 = 0;
    // TODO: handle "VkResult.incomplete"
    _ = try vkb.enumerateInstanceExtensionProperties(null, &supported_extensions_count, null);

    var extensions = try ArrayList(vk.ExtensionProperties).initCapacity(allocator, supported_extensions_count);
    defer extensions.deinit();

    _ = try vkb.enumerateInstanceExtensionProperties(null, &supported_extensions_count, extensions.items.ptr);
    extensions.items.len = supported_extensions_count;

    var matches: u32 = 0;
    for (target_extensions) |target_extension| {
        cmp: for (extensions.items) |existing| {
            const existing_name = @ptrCast([*:0] const u8, &existing.extension_name);
            if (std.cstr.cmp(target_extension, existing_name) == 0) {
                matches += 1;
                break :cmp;
            }
        }
    }

    return matches == target_extensions.len;
}

/// TODO: unify with instance function?
fn isPhysicalDeviceExtensionsPresent(allocator: *Allocator, vki: InstanceDispatch, device: vk.PhysicalDevice, target_extensions: []const [*:0]const u8) !bool {
    // query extensions available
    var supported_extensions_count: u32 = 0;
    // TODO: handle "VkResult.incomplete"
    _ = try vki.enumerateDeviceExtensionProperties(device, null, &supported_extensions_count, null);

    var extensions = try ArrayList(vk.ExtensionProperties).initCapacity(allocator, supported_extensions_count);
    defer extensions.deinit();

    _ = try vki.enumerateDeviceExtensionProperties(device, null, &supported_extensions_count, extensions.items.ptr);
    extensions.items.len = supported_extensions_count;

    var matches: u32 = 0;
    for (target_extensions) |target_extension| {
        cmp: for (extensions.items) |existing| {
            const existing_name = @ptrCast([*:0] const u8, &existing.extension_name);
            if (std.cstr.cmp(target_extension, existing_name) == 0) {
                matches += 1;
                break :cmp;
            }
        }
    }

    return matches == target_extensions.len;
}


/// Caller must deinit returned ArrayList
fn getRequiredInstanceExtensions(allocator: *Allocator, target_extensions: []const [*:0]const u8) !ArrayList([*:0]const u8) {
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
    // TODO: figure out if the if is needed
    // keep parameters for API, "if (false)"" ensures no runtime cost
    if (false) {
        _ = message_types;
    }
    const writers = @ptrCast(*Writers, @alignCast(@alignOf(*Writers), p_user_data));
    const error_mask = comptime blk: {
        break :blk vk.DebugUtilsMessageSeverityFlagsEXT{
            .warning_bit_ext = true,
            .error_bit_ext = true,
        };
    };
    const is_severe = error_mask.toInt() & message_severity > 0;
    const writer = if (is_severe) writers.stderr.* else writers.stdout.*;

    writer.print("validation layer: {s}\n", .{p_callback_data.p_message}) catch {
        std.debug.print("error from stdout print in message callback", .{});
    };

    return vk.FALSE;
}

// TODO: we don't need this, we can pass a createinfo from the init function
fn createDefaultDebugCreateInfo(writers: *Writers) vk.DebugUtilsMessengerCreateInfoEXT {
    const message_severity = vk.DebugUtilsMessageSeverityFlagsEXT{
        .verbose_bit_ext = true,
        .warning_bit_ext = true,
        .error_bit_ext = true,
    };

    const message_type = vk.DebugUtilsMessageTypeFlagsEXT{
        .general_bit_ext = true,
        .validation_bit_ext = true,
        .performance_bit_ext = true,
    };

    return vk.DebugUtilsMessengerCreateInfoEXT{
        .flags = .{},
        .message_severity = message_severity,
        .message_type = message_type,
        .pfn_user_callback = messageCallback,
        .p_user_data = @ptrCast(?*c_void, writers),
    };
}

inline fn setupDebugCallback(vki: InstanceDispatch, instance: vk.Instance, writers: *Writers) !?vk.DebugUtilsMessengerEXT {
    if (!enable_validation_layers) return null;

    const create_info = createDefaultDebugCreateInfo(writers);

    return vki.createDebugUtilsMessengerEXT(instance, create_info, null) catch {
        std.debug.panic("failed to create debug messenger", .{});
    };
}

/// Any suiteable GPU should result in a positive value, an unsuitable GPU might return a negative value
inline fn deviceHeuristic(allocator: *Allocator, vki: InstanceDispatch, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !i32 {
    // TODO: rewrite function to have clearer distinction between required and bonus features (2 bitmaps?)
    const property_score = blk: {
        const device_properties = vki.getPhysicalDeviceProperties(device);
        const discrete = @as(i32, @boolToInt(device_properties.device_type == vk.PhysicalDeviceType.discrete_gpu)) + 5;
        break :blk discrete;
    };

    const feature_score = blk: {
        const device_features = vki.getPhysicalDeviceFeatures(device);
        const atomics = @intCast(i32, device_features.fragment_stores_and_atomics);
        break :blk atomics;
    };

    const queue_fam_score: i32 = blk: {
        _ = getQueueFamilyIndices(allocator, vki, device, surface) catch break :blk -1000;
        break :blk 10;
    };

    const extensions_score: i32 = blk: {
        const extension_slice = logicical_device_extensions[0..logicical_device_extensions.len];
        const extensions_available = try isPhysicalDeviceExtensionsPresent(allocator, vki, device, extension_slice);
        if (!extensions_available) {
            break :blk -1000;
        }
        break :blk 10;
    };

    return -20 + property_score + feature_score + queue_fam_score + extensions_score;
}

// select primary physical device in init
inline fn selectPhysicalDevice(allocator: *Allocator, vki: InstanceDispatch, instance: vk.Instance, surface: vk.SurfaceKHR) !vk.PhysicalDevice {
    var device_count: u32 = 0;
    _ = try vki.enumeratePhysicalDevices(instance, &device_count, null); // TODO: handle incomplete
    if (device_count < 0) {
        std.debug.panic("no GPU suitable for vulkan identified");
    }

    var devices = try ArrayList(vk.PhysicalDevice).initCapacity(allocator, device_count);
    defer devices.deinit();

    _ = try vki.enumeratePhysicalDevices(instance, &device_count, devices.items.ptr); // TODO: handle incomplete
    devices.items.len = device_count;

    var device_score: i32 = -1;
    var device_index: ?usize = null;
    for (devices.items) |device, i| {
        const new_score = try deviceHeuristic(allocator, vki, device, surface);
        if (device_score < new_score) {
            device_score = new_score;
            device_index = i;
        }
    }

    if (device_index == null) {
        return error.NoSuitablePhysicalDevice;
    }

    return devices.items[device_index.?];
}

const QueueFamilyIndices = struct {
    graphics: u32,
    present: u32,
};

inline fn getQueueFamilyIndices(allocator: *Allocator, vki: InstanceDispatch, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !QueueFamilyIndices {
    var queue_family_count: u32 = 0;
    vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);

    var queue_families = try ArrayList(vk.QueueFamilyProperties).initCapacity(allocator, queue_family_count);
    defer queue_families.deinit();

    vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, queue_families.items.ptr);
    queue_families.items.len = queue_family_count;

    const graphics_bit = vk.QueueFlags{
        .graphics_bit = true,
    };

    var graphics_index: ?u32 = null;
    var present_index: ?u32 = null;
    for (queue_families.items) |queue_family, i| {
        const index = @intCast(u32, i);
        if (graphics_index == null and queue_family.queue_flags.intersect(graphics_bit).toInt() > 0) {
            graphics_index = index;
        }
        if (present_index == null and (try vki.getPhysicalDeviceSurfaceSupportKHR(physical_device, index, surface)) == vk.TRUE) {
            present_index = index;
        }
    }

    if (graphics_index == null or present_index == null) {
        return error.MissingQueueFamilyIndex;
    }

    return QueueFamilyIndices{
        .graphics = graphics_index.?,
        .present = present_index.?,
    };
}

fn createLogicalDevice(allocator: *Allocator, vkb: BaseDispatch, vki: InstanceDispatch, physical_device: vk.PhysicalDevice) !vk.Device {
    std.debug.assert(queue_indices != null);
    const indices = queue_indices.?;

    const queue_priority = [_]f32{1.0};
    const family_indices = [_]u32{ indices.graphics, indices.present };
    var queue_create_infos: [family_indices.len]vk.DeviceQueueCreateInfo = undefined;
    for (family_indices) |family_index, i| {
        queue_create_infos[i] = vk.DeviceQueueCreateInfo{
            .flags = .{},
            .queue_family_index = family_index,
            .queue_count = 1,
            .p_queue_priorities = &queue_priority,
        };
    }

    const device_features = vk.PhysicalDeviceVulkan12Features{};

    const validation_layer_info = try ValidationLayerInfo.init(allocator, vkb);

    const create_info = vk.DeviceCreateInfo{
        .flags = .{},
        .queue_create_info_count = queue_create_infos.len,
        .p_queue_create_infos = &queue_create_infos,
        .enabled_layer_count = validation_layer_info.enabled_layer_count,
        .pp_enabled_layer_names = validation_layer_info.enabled_layer_names,
        .enabled_extension_count = logicical_device_extensions.len,
        .pp_enabled_extension_names = &logicical_device_extensions,
        .p_enabled_features = @ptrCast(*const vk.PhysicalDeviceFeatures, &device_features),
    };

    return vki.createDevice(physical_device, create_info, null);
}

fn CreateValidationLayerInfoType() type {
    if (enable_validation_layers) {
        return struct {
            const Self = @This();

            enabled_layer_count: u8,
            enabled_layer_names: [*]const [*:0]const u8,

            pub fn init(allocator: *Allocator, vkb: BaseDispatch) !Self {
                const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
                const is_valid = try isValidationLayersPresent(allocator, vkb, validation_layers[0..validation_layers.len]);
                if (!is_valid) {
                    std.debug.panic("debug build without validation layer support", .{});
                }

                return Self{
                    .enabled_layer_count = validation_layers.len,
                    .enabled_layer_names = @ptrCast([*]const [*:0]const u8, &validation_layers),
                };
            }
        };
    } else {
        return struct {
            const Self = @This();

            enabled_layer_count: u8,
            enabled_layer_names: [*]const [*:0]const u8,

            pub fn init(_: *Allocator, _: BaseDispatch) !Self {
                return Self{
                    .enabled_layer_count = 0,
                    .enabled_layer_names = undefined,
                };
            }
        };
    }
}
const ValidationLayerInfo = CreateValidationLayerInfoType();

fn createSurface(instance: vk.Instance, window: *c.GLFWwindow) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    if (c.glfwCreateWindowSurface(instance, window, null, &surface) != .success) {
        return error.SurfaceInitFailed;
    }

    return surface;
}

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
    var writers = Writers{ .stdout = &stdout, .stderr = &stderr };
    // Construct our vulkan instance
    const ctx = try GfxContext.init(&gpa.allocator, window, &writers);
    defer ctx.deinit();

    // Loop until the user closes the window
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        // Render here

        // Swap front and back buffers
        c.glfwSwapBuffers(window);

        // Poll for and process events
        c.glfwPollEvents();
    }
}
