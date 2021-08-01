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

const logicical_device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};

const BaseDispatch = vk.BaseWrapper([_]vk.BaseCommand{
    .CreateInstance,
    .EnumerateInstanceExtensionProperties,
    .EnumerateInstanceLayerProperties,
});

const InstanceDispatch = vk.InstanceWrapper([_]vk.InstanceCommand{ .CreateDebugUtilsMessengerEXT, .CreateDevice, .DestroyDebugUtilsMessengerEXT, .DestroyInstance, .DestroySurfaceKHR, .EnumerateDeviceExtensionProperties, .EnumeratePhysicalDevices, .GetDeviceProcAddr, .GetPhysicalDeviceFeatures, .GetPhysicalDeviceProperties, .GetPhysicalDeviceQueueFamilyProperties, .GetPhysicalDeviceSurfaceCapabilitiesKHR, .GetPhysicalDeviceSurfaceFormatsKHR, .GetPhysicalDeviceSurfacePresentModesKHR, .GetPhysicalDeviceSurfaceSupportKHR });

const DeviceDispatch = vk.DeviceWrapper([_]vk.DeviceCommand{ .CreateFramebuffer, .CreateGraphicsPipelines, .CreateImageView, .CreatePipelineLayout, .CreateRenderPass, .CreateShaderModule, .CreateSwapchainKHR, .DestroyDevice, .DestroyFramebuffer, .DestroyImageView, .DestroyPipeline, .DestroyPipelineLayout, .DestroyRenderPass, .DestroyShaderModule, .DestroySwapchainKHR, .GetDeviceQueue, .GetSwapchainImagesKHR });

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
            const existing_name = @ptrCast([*:0]const u8, &existing.extension_name);
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
            const existing_name = @ptrCast([*:0]const u8, &existing.extension_name);
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
inline fn createDefaultDebugCreateInfo(writers: *Writers) vk.DebugUtilsMessengerCreateInfoEXT {
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
    // TODO: rewrite function to have clearer distinction between required and bonus features
    //       possible solutions:
    //          - return error if missing feature and discard negative return value (use u32 instead)
    //          - 2 bitmaps
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

    const swapchain_score: i32 = blk: {
        if (SwapchainSupportDetails.init(allocator, vki, device, surface)) |ok| {
            defer ok.deinit();
            break :blk 10;
        } else |_| {
            break :blk -1000;
        }
    };

    return -30 + property_score + feature_score + queue_fam_score + extensions_score + swapchain_score;
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

// TODO: support mixed types
/// Construct VkPhysicalDeviceFeatures type with VkFalse as default field value 
fn GetFalseFeatures(comptime T: type) type {
    const features_type_info = @typeInfo(T).Struct;
    var new_type_fields: [features_type_info.fields.len]std.builtin.TypeInfo.StructField = undefined;

    inline for (features_type_info.fields) |field, i| {
        new_type_fields[i] = field;
        new_type_fields[i].default_value = @intCast(u32, vk.FALSE);
    }

    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = &new_type_fields,
            .decls = &[_]std.builtin.TypeInfo.Declaration{},
            .is_tuple = false,
        },
    });
}
const FalsePhysicalDeviceFeatures = GetFalseFeatures(vk.PhysicalDeviceFeatures);

fn createLogicalDevice(allocator: *Allocator, vkb: BaseDispatch, vki: InstanceDispatch, physical_device: vk.PhysicalDevice) !vk.Device {
    std.debug.assert(queue_indices != null);
    const indices = queue_indices.?;

    const queue_priority = [_]f32{1.0};

    // merge indices if they are identical according to vulkan spec
    const family_indices: []const u32 = blk: {
        if (indices.graphics != indices.present) {
            break :blk &[_]u32{ indices.graphics, indices.present };
        }
        break :blk &[_]u32{indices.graphics};
    };

    var queue_create_infos = try ArrayList(vk.DeviceQueueCreateInfo).initCapacity(allocator, family_indices.len);
    defer queue_create_infos.deinit();

    for (family_indices) |family_index| {
        queue_create_infos.appendAssumeCapacity(vk.DeviceQueueCreateInfo{
            .flags = .{},
            .queue_family_index = family_index,
            .queue_count = 1,
            .p_queue_priorities = &queue_priority,
        });
    }

    const device_features = FalsePhysicalDeviceFeatures{};

    const validation_layer_info = try ValidationLayerInfo.init(allocator, vkb);

    const create_info = vk.DeviceCreateInfo{
        .flags = .{},
        .queue_create_info_count = @intCast(u32, queue_create_infos.items.len),
        .p_queue_create_infos = queue_create_infos.items.ptr,
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

const SwapchainSupportDetails = struct {
    const Self = @This();

    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: ArrayList(vk.SurfaceFormatKHR),
    present_modes: ArrayList(vk.PresentModeKHR),

    /// calle has to make sure to also call deinit
    fn init(allocator: *Allocator, vki: InstanceDispatch, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !Self {
        const capabilities = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(device, surface);

        var format_count: u32 = 0;
        // TODO: handle incomplete
        _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null);
        if (format_count <= 0) {
            return error.NoSurfaceFormatsSupported;
        }
        const formats = blk: {
            var formats = try ArrayList(vk.SurfaceFormatKHR).initCapacity(allocator, format_count);
            _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, formats.items.ptr);
            formats.items.len = format_count;
            break :blk formats;
        };
        errdefer formats.deinit();

        var present_modes_count: u32 = 0;
        _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_modes_count, null);
        if (present_modes_count <= 0) {
            return error.NoPresentModesSupported;
        }
        const present_modes = blk: {
            var present_modes = try ArrayList(vk.PresentModeKHR).initCapacity(allocator, present_modes_count);
            _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_modes_count, present_modes.items.ptr);
            present_modes.items.len = present_modes_count;
            break :blk present_modes;
        };
        errdefer present_modes.deinit();

        return Self{
            .capabilities = capabilities,
            .formats = formats,
            .present_modes = present_modes,
        };
    }

    fn selectSwapChainFormat(self: Self) vk.SurfaceFormatKHR {
        // TODO: in some cases this is a valid state?
        //       if so return error here instead ...
        assert(self.formats.items.len > 0);

        for (self.formats.items) |format| {
            if (format.format == vk.Format.b8g8r8_srgb and format.color_space == vk.ColorSpaceKHR.srgb_nonlinear_khr) {
                return format;
            }
        }

        return self.formats.items[0];
    }

    fn selectSwapchainPresentMode(self: Self) vk.PresentModeKHR {
        for (self.present_modes.items) |present_mode| {
            if (present_mode == vk.PresentModeKHR.mailbox_khr) {
                return present_mode;
            }
        }

        return vk.PresentModeKHR.fifo_khr;
    }

    fn constructSwapChainExtent(self: Self) vk.Extent2D {
        if (self.capabilities.current_extent.width != std.math.maxInt(u32)) {
            return self.capabilities.current_extent;
        } else {
            var window_size = blk: {
                var x: u32 = 0;
                var y: u32 = 0;
                // TODO: this makes this function dependent on window being set, add some checks to verify correct use
                //       preferably utilizing comptime
                const window = c.glfwGetCurrentContext();
                c.glfwGetFramebufferSize(window, @ptrCast(*i32, &x), @ptrCast(*i32, &y));
                break :blk vk.Extent2D{ .width = x, .height = y };
            };

            const clamp = std.math.clamp;
            const min = self.capabilities.min_image_extent;
            const max = self.capabilities.max_image_extent;
            return vk.Extent2D{
                .width = clamp(window_size.width, min.width, max.width),
                .height = clamp(window_size.height, min.height, max.height),
            };
        }
    }

    fn deinit(self: Self) void {
        self.formats.deinit();
        self.present_modes.deinit();
    }
};

fn createSwapchainCreateInfo(allocator: *Allocator, vki: InstanceDispatch, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !vk.SwapchainCreateInfoKHR {
    std.debug.assert(queue_indices != null);

    const sc_support = try SwapchainSupportDetails.init(allocator, vki, device, surface);
    defer sc_support.deinit();
    if (sc_support.capabilities.max_image_count <= 0) {
        return error.SwapchainNoImageSupport;
    }

    const format = sc_support.selectSwapChainFormat();
    const present_mode = sc_support.selectSwapchainPresentMode();
    const extent = sc_support.constructSwapChainExtent();

    const image_count = std.math.min(sc_support.capabilities.min_image_count + 1, sc_support.capabilities.max_image_count);

    const Config = struct {
        sharing_mode: vk.SharingMode,
        index_count: u32,
        p_indices: [*]const u32,
    };
    const sharing_config = blk: {
        const indices = queue_indices.?;
        if (indices.graphics != indices.present) {
            const indices_arr = [_]u32{ indices.graphics, indices.present };
            break :blk Config{
                .sharing_mode = vk.SharingMode.concurrent, // TODO: read up on ownership in this context
                .index_count = 2,
                .p_indices = @ptrCast([*]const u32, &indices_arr[0..indices_arr.len]),
            };
        } else {
            const indices_arr = [_]u32{ indices.graphics, indices.present };
            break :blk Config{
                .sharing_mode = vk.SharingMode.exclusive,
                .index_count = 0,
                .p_indices = @ptrCast([*]const u32, &indices_arr[0..indices_arr.len]),
            };
        }
    };

    return vk.SwapchainCreateInfoKHR{
        .flags = .{},
        .surface = surface,
        .min_image_count = image_count,
        .image_format = format.format,
        .image_color_space = format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = vk.ImageUsageFlags{ .color_attachment_bit = true },
        .image_sharing_mode = sharing_config.sharing_mode,
        .queue_family_index_count = sharing_config.index_count,
        .p_queue_family_indices = sharing_config.p_indices,
        .pre_transform = sc_support.capabilities.current_transform,
        .composite_alpha = vk.CompositeAlphaFlagsKHR{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = vk.SwapchainKHR.null_handle,
    };
}

/// used to initialize different aspects of the GfxContext
var queue_indices: ?QueueFamilyIndices = null;

const SwapchainData = struct {
    swapchain: vk.SwapchainKHR,
    images: ArrayList(vk.Image),
    views: ArrayList(vk.ImageView),
    format: vk.Format,
    extent: vk.Extent2D,
};

// TODO: Unit testing
const GraphicsContext = struct {
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
    swapchain_data: SwapchainData,

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
            const common_extensions = [_][*:0]const u8{vk.extension_info.khr_surface.name};
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

        const instance = blk: {
            const instanceInfo = vk.InstanceCreateInfo{
                .p_next = create_p_next,
                .flags = .{},
                .p_application_info = &appInfo,
                .enabled_layer_count = validation_layer_info.enabled_layer_count,
                .pp_enabled_layer_names = validation_layer_info.enabled_layer_names,
                .enabled_extension_count = @intCast(u32, extensions.items.len),
                .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, extensions.items.ptr),
            };
            break :blk try vkb.createInstance(instanceInfo, null);
        };

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

        const swapchain_data = blk1: {
            const sc_create_info = try createSwapchainCreateInfo(allocator, vki, physical_device, surface);
            const swapchain = try vkd.createSwapchainKHR(logical_device, sc_create_info, null);
            const swapchain_images = blk2: {
                var image_count: u32 = 0;
                // TODO: handle incomplete
                _ = try vkd.getSwapchainImagesKHR(logical_device, swapchain, &image_count, null);
                var images = try ArrayList(vk.Image).initCapacity(allocator, image_count);
                _ = try vkd.getSwapchainImagesKHR(logical_device, swapchain, &image_count, images.items.ptr);
                images.items.len = image_count;
                break :blk2 images;
            };

            const image_views = blk2: {
                const image_count = swapchain_images.items.len;
                var views = try ArrayList(vk.ImageView).initCapacity(allocator, image_count);
                const components = vk.ComponentMapping{
                    .r = vk.ComponentSwizzle.identity,
                    .g = vk.ComponentSwizzle.identity,
                    .b = vk.ComponentSwizzle.identity,
                    .a = vk.ComponentSwizzle.identity,
                };
                const subresource_range = vk.ImageSubresourceRange{
                    .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                };
                {
                    var i: u32 = 0;
                    while (i < image_count) : (i += 1) {
                        const create_info = vk.ImageViewCreateInfo{
                            .flags = vk.ImageViewCreateFlags{},
                            .image = swapchain_images.items[i],
                            .view_type = vk.ImageViewType.@"2d",
                            .format = sc_create_info.image_format,
                            .components = components,
                            .subresource_range = subresource_range,
                        };
                        const view = try vkd.createImageView(logical_device, create_info, null);
                        views.appendAssumeCapacity(view);
                    }
                }

                break :blk2 views;
            };

            break :blk1 SwapchainData{
                .swapchain = swapchain,
                .images = swapchain_images,
                .views = image_views,
                .format = sc_create_info.image_format,
                .extent = sc_create_info.image_extent,
            };
        };

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
            .swapchain_data = swapchain_data,
            .messenger = messenger,
        };
    }

    // TODO: remove create/destroy that are thin wrappers (make data public instead)
    /// caller must destroy returned module
    pub fn createShaderModule(self: Self, spir_v: []const u8) !vk.ShaderModule {
        const create_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .p_code = @ptrCast([*]const u32, @alignCast(4, spir_v.ptr)),
            .code_size = spir_v.len,
        };

        return self.vkd.createShaderModule(self.logical_device, create_info, null);
    }

    pub fn destroyShaderModule(self: Self, module: vk.ShaderModule) void {
        self.vkd.destroyShaderModule(self.logical_device, module, null);
    }

    /// caller must destroy returned module 
    pub fn createPipelineLayout(self: Self, create_info: vk.PipelineLayoutCreateInfo) !vk.PipelineLayout {
        return self.vkd.createPipelineLayout(self.logical_device, create_info, null);
    }

    pub fn destroyPipelineLayout(self: Self, pipeline_layout: vk.PipelineLayout) void {
        self.vkd.destroyPipelineLayout(self.logical_device, pipeline_layout, null);
    }

    /// caller must both destroy pipeline from the heap and in vulkan
    pub fn createGraphicsPipelines(self: Self, allocator: *Allocator, create_info: vk.GraphicsPipelineCreateInfo) !*vk.Pipeline {
        var pipeLine = try allocator.create(vk.Pipeline);
        errdefer allocator.destroy(pipeLine);

        const create_infos = [_]vk.GraphicsPipelineCreateInfo{
            create_info,
        };
        const result = try self.vkd.createGraphicsPipelines(self.logical_device, .null_handle, create_infos.len, @ptrCast([*]const vk.GraphicsPipelineCreateInfo, &create_infos), null, @ptrCast([*]vk.Pipeline, pipeLine));
        if (result != vk.Result.success) {
            // TODO: not panic?
            std.debug.panic("failed to initialize pipeline!", .{});
        }

        return pipeLine;
    }

    /// destroy pipeline from vulkan *not* from the application memory
    pub fn destroyPipeline(self: Self, pipeline: *vk.Pipeline) void {
        self.vkd.destroyPipeline(self.logical_device, pipeline.*, null);
    }

    /// caller must destroy returned render pass
    pub fn createRenderPass(self: Self) !vk.RenderPass {
        const color_attachment = [_]vk.AttachmentDescription{
            .{
                .flags = .{},
                .format = self.swapchain_data.format,
                .samples = .{
                    .@"1_bit" = true,
                },
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .@"undefined",
                .final_layout = .present_src_khr,
            },
        };
        const color_attachment_refs = [_]vk.AttachmentReference{
            .{
                .attachment = 0,
                .layout = .color_attachment_optimal,
            },
        };
        const subpass = [_]vk.SubpassDescription{
            .{
                .flags = .{},
                .pipeline_bind_point = .graphics,
                .input_attachment_count = 0,
                .p_input_attachments = undefined,
                .color_attachment_count = color_attachment_refs.len,
                .p_color_attachments = &color_attachment_refs,
                .p_resolve_attachments = null,
                .p_depth_stencil_attachment = null,
                .preserve_attachment_count = 0,
                .p_preserve_attachments = undefined,
            },
        };
        const render_pass_info = vk.RenderPassCreateInfo{
            .flags = .{},
            .attachment_count = color_attachment.len,
            .p_attachments = &color_attachment,
            .subpass_count = subpass.len,
            .p_subpasses = &subpass,
            .dependency_count = 0,
            .p_dependencies = undefined,
        };

        return try self.vkd.createRenderPass(self.logical_device, render_pass_info, null);
    }

    pub fn destroyRenderPass(self: Self, render_pass: vk.RenderPass) void {
        self.vkd.destroyRenderPass(self.logical_device, render_pass, null);
    }

    /// utility to create simple view state info
    pub fn createViewportScissors(self: Self) struct { viewport: [1]vk.Viewport, scissor: [1]vk.Rect2D } {
        // TODO: this can be broken down a bit since the code is pretty cluster fck
        const width = self.swapchain_data.extent.width;
        const height = self.swapchain_data.extent.width;
        return .{
            .viewport = [1]vk.Viewport{
                .{ .x = 0, .y = 0, .width = @intToFloat(f32, width), .height = @intToFloat(f32, height), .min_depth = 0.0, .max_depth = 1.0 },
            },
            .scissor = [1]vk.Rect2D{
                .{
                    .offset = .{
                        .x = 0,
                        .y = 0,
                    },
                    .extent = .{
                        .width = width,
                        .height = height,
                    },
                },
            },
        };
    }

    pub fn deinit(self: Self) void {
        for (self.swapchain_data.views.items) |view| {
            self.vkd.destroyImageView(self.logical_device, view, null);
        }
        self.swapchain_data.views.deinit();
        self.swapchain_data.images.deinit();

        self.vkd.destroySwapchainKHR(self.logical_device, self.swapchain_data.swapchain, null);
        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        self.vkd.destroyDevice(self.logical_device, null);

        if (enable_validation_layers) {
            self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.messenger.?, null);
        }
        self.vki.destroyInstance(self.instance, null);
    }
};

/// caller must deinit returned memory
fn readFile(allocator: *Allocator, absolute_path: []const u8) !ArrayList(u8) {
    const file = try std.fs.openFileAbsolute(absolute_path, .{ .read = true });
    defer file.close();

    var reader = file.reader();
    const file_size = (try reader.context.stat()).size;
    var buffer = try ArrayList(u8).initCapacity(allocator, file_size);
    // set buffer len so that reader is aware of usable memory
    buffer.items.len = file_size;

    const read = try reader.readAll(buffer.items);
    if (read != file_size) {
        return error.DidNotReadWholeFile;
    }

    return buffer;
}

const ApplicationPipeline = struct {
    // TODO: https://www.khronos.org/registry/vulkan/specs/1.2-extensions/man/html/VkRayTracingPipelineCreateInfoKHR.html
    const Self = @This();

    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    pipeline: *vk.Pipeline,
    framebuffers: ArrayList(vk.Framebuffer),

    allocator: *Allocator,

    /// initialize a graphics pipe line 
    pub fn init(allocator: *Allocator, ctx: GraphicsContext) !Self {
        const pipeline_layout = blk: {
            const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = 0,
                .p_set_layouts = undefined,
                .push_constant_range_count = 0,
                .p_push_constant_ranges = undefined,
            };
            break :blk try ctx.createPipelineLayout(pipeline_layout_info);
        };
        const render_pass = try ctx.createRenderPass();

        const pipeline = blk: {
            const self_path = try std.fs.selfExePathAlloc(allocator);
            defer ctx.allocator.destroy(self_path.ptr);

            // TODO: function in context for shader stage creation?
            const vert_code = blk1: {
                const path = blk2: {
                    const join_path = [_][]const u8{ self_path, "../../triangle.vert.spv" };
                    break :blk2 try std.fs.path.resolve(allocator, join_path[0..]);
                };
                defer allocator.destroy(path.ptr);

                break :blk1 try readFile(allocator, path);
            };
            const vert_module = try ctx.createShaderModule(vert_code.items[0..]);
            defer {
                ctx.destroyShaderModule(vert_module);
                vert_code.deinit();
            }

            const vert_stage = vk.PipelineShaderStageCreateInfo{ .flags = .{}, .stage = .{ .vertex_bit = true }, .module = vert_module, .p_name = "main", .p_specialization_info = null };

            const frag_code = blk1: {
                const path = blk2: {
                    const join_path = [_][]const u8{ self_path, "../../triangle.frag.spv" };
                    break :blk2 try std.fs.path.resolve(allocator, join_path[0..]);
                };
                defer allocator.destroy(path.ptr);

                break :blk1 try readFile(allocator, path);
            };
            const frag_module = try ctx.createShaderModule(frag_code.items[0..]);
            defer {
                ctx.destroyShaderModule(frag_module);
                frag_code.deinit();
            }

            const frag_stage = vk.PipelineShaderStageCreateInfo{ .flags = .{}, .stage = .{ .fragment_bit = true }, .module = frag_module, .p_name = "main", .p_specialization_info = null };
            const shader_stages_info = [_]vk.PipelineShaderStageCreateInfo{ vert_stage, frag_stage };

            const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
                .flags = .{},
                .vertex_binding_description_count = 0,
                .p_vertex_binding_descriptions = undefined,
                .vertex_attribute_description_count = 0,
                .p_vertex_attribute_descriptions = undefined,
            };
            const input_assembley_info = vk.PipelineInputAssemblyStateCreateInfo{
                .flags = .{},
                .topology = vk.PrimitiveTopology.triangle_list,
                .primitive_restart_enable = vk.FALSE,
            };
            const view = ctx.createViewportScissors();
            const viewport_info = vk.PipelineViewportStateCreateInfo{
                .flags = .{},
                .viewport_count = view.viewport.len,
                .p_viewports = @ptrCast(?[*]const vk.Viewport, &view.viewport),
                .scissor_count = view.scissor.len,
                .p_scissors = @ptrCast(?[*]const vk.Rect2D, &view.scissor),
            };
            const rasterizer_info = vk.PipelineRasterizationStateCreateInfo{
                .flags = .{},
                .depth_clamp_enable = vk.FALSE,
                .rasterizer_discard_enable = vk.FALSE,
                .polygon_mode = .fill,
                .cull_mode = .{ .back_bit = true },
                .front_face = .clockwise,
                .depth_bias_enable = vk.FALSE,
                .depth_bias_constant_factor = 0.0,
                .depth_bias_clamp = 0.0,
                .depth_bias_slope_factor = 0.0,
                .line_width = 1.0,
            };
            const multisample_info = vk.PipelineMultisampleStateCreateInfo{
                .flags = .{},
                .rasterization_samples = .{ .@"1_bit" = true },
                .sample_shading_enable = vk.FALSE,
                .min_sample_shading = 1.0,
                .p_sample_mask = null,
                .alpha_to_coverage_enable = vk.FALSE,
                .alpha_to_one_enable = vk.FALSE,
            };
            const color_blend_attachments = [_]vk.PipelineColorBlendAttachmentState{
                .{
                    .blend_enable = vk.FALSE,
                    .src_color_blend_factor = .one,
                    .dst_color_blend_factor = .zero,
                    .color_blend_op = .add,
                    .src_alpha_blend_factor = .one,
                    .dst_alpha_blend_factor = .zero,
                    .alpha_blend_op = .add,
                    .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
                },
            };
            const color_blend_state = vk.PipelineColorBlendStateCreateInfo{
                .flags = .{},
                .logic_op_enable = vk.FALSE,
                .logic_op = .copy,
                .attachment_count = color_blend_attachments.len,
                .p_attachments = @ptrCast([*]const vk.PipelineColorBlendAttachmentState, &color_blend_attachments),
                .blend_constants = [_]f32{0.0} ** 4,
            };
            const dynamic_states = [_]vk.DynamicState{
                .viewport,
                .scissor,
            };
            const dynamic_state_info = vk.PipelineDynamicStateCreateInfo{
                .flags = .{},
                .dynamic_state_count = dynamic_states.len,
                .p_dynamic_states = @ptrCast([*]const vk.DynamicState, &dynamic_states),
            };
            const pipeline_info = vk.GraphicsPipelineCreateInfo{
                .flags = .{},
                .stage_count = shader_stages_info.len,
                .p_stages = @ptrCast([*]const vk.PipelineShaderStageCreateInfo, &shader_stages_info),
                .p_vertex_input_state = &vertex_input_info,
                .p_input_assembly_state = &input_assembley_info,
                .p_tessellation_state = null,
                .p_viewport_state = &viewport_info,
                .p_rasterization_state = &rasterizer_info,
                .p_multisample_state = &multisample_info,
                .p_depth_stencil_state = null,
                .p_color_blend_state = &color_blend_state,
                .p_dynamic_state = &dynamic_state_info,
                .layout = pipeline_layout,
                .render_pass = render_pass,
                .subpass = 0,
                .base_pipeline_handle = .null_handle,
                .base_pipeline_index = -1,
            };
            break :blk try ctx.createGraphicsPipelines(allocator, pipeline_info);
        };

        var framebuffers = try ArrayList(vk.Framebuffer).initCapacity(allocator, ctx.swapchain_data.views.items.len);
        for (ctx.swapchain_data.views.items) |view| {
            const attachments = [_]vk.ImageView{
                view,
            };
            const framebuffer_info = vk.FramebufferCreateInfo{
                .flags = .{},
                .render_pass = render_pass,
                .attachment_count = attachments.len,
                .p_attachments = @ptrCast([*]const vk.ImageView, &attachments),
                .width = ctx.swapchain_data.extent.width,
                .height = ctx.swapchain_data.extent.height,
                .layers = 1,
            };
            const framebuffer = try ctx.vkd.createFramebuffer(ctx.logical_device, framebuffer_info, null);
            framebuffers.appendAssumeCapacity(framebuffer);
        }

        return Self{
            .render_pass = render_pass,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .framebuffers = framebuffers,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Self, ctx: GraphicsContext) void {
        for (self.framebuffers.items) |framebuffer| {
            ctx.vkd.destroyFramebuffer(ctx.logical_device, framebuffer, null);
        }
        self.framebuffers.deinit();

        ctx.destroyPipelineLayout(self.pipeline_layout);
        ctx.destroyRenderPass(self.render_pass);
        ctx.destroyPipeline(self.pipeline);
        self.allocator.destroy(self.pipeline);
    }
};

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
    const ctx = try GraphicsContext.init(&gpa.allocator, window, &writers);
    defer ctx.deinit();

    // const gfx_pipe
    const pipeline = try ApplicationPipeline.init(&gpa.allocator, ctx);
    defer pipeline.deinit(ctx);

    // Loop until the user closes the window
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        // Render here

        // Swap front and back buffers
        c.glfwSwapBuffers(window);

        // Poll for and process events
        c.glfwPollEvents();
    }
}
