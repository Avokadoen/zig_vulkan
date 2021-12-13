/// Abstractions around vulkan physical device

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const vk = @import("vulkan");
const dispatch = @import("dispatch.zig");
const constants = @import("consts.zig");
const swapchain = @import("swapchain.zig");
const vk_utils = @import("vk_utils.zig");
const validation_layer = @import("validation_layer.zig");
const Context = @import("context.zig").Context;

/// Type that share ABI with vkPhysicalDeviceFeatures and that has all values
/// assigned to vkFALSE by default.
pub const FalsePhysicalDeviceFeatures = vk_utils.GetFalseFeatures(vk.PhysicalDeviceFeatures);

pub const QueueFamilyIndices = struct {
    compute: u32,
    graphics: u32,
    present: u32,

    // TODO: use internal allocator that is suitable
    /// Initialize a QueueFamilyIndices instance, internal allocation is handled by QueueFamilyIndices (no manuall cleanup)
    pub fn init(allocator: Allocator, vki: dispatch.Instance, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !QueueFamilyIndices {
        var queue_family_count: u32 = 0;
        vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);

        var queue_families = try allocator.alloc(vk.QueueFamilyProperties, queue_family_count);
        defer allocator.free(queue_families);

        vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, queue_families.ptr);
        queue_families.len = queue_family_count;

        const compute_bit = vk.QueueFlags{
            .compute_bit = true,
        };
        const graphics_bit = vk.QueueFlags{
            .graphics_bit = true,
        };

        var compute_index: ?u32 = null;
        var graphics_index: ?u32 = null;
        var present_index: ?u32 = null;
        for (queue_families) |queue_family, i| {
            const index = @intCast(u32, i);
            if (compute_index == null and queue_family.queue_flags.contains(compute_bit)) {
                compute_index = index;
            }
            if (graphics_index == null and queue_family.queue_flags.contains(graphics_bit)) {
                graphics_index = index;
            }
            if (present_index == null and (try vki.getPhysicalDeviceSurfaceSupportKHR(physical_device, index, surface)) == vk.TRUE) {
                present_index = index;
            }
        }

        if (compute_index == null) {
            return error.ComputeIndexMissing;
        }
        if (graphics_index == null) {
            return error.GraphicsIndexMissing;
        }
        if (present_index == null) {
            return error.PresentIndexMissing;
        }

        return QueueFamilyIndices{
            .compute = compute_index.?,
            .graphics = graphics_index.?,
            .present = present_index.?,
        };
    }
};

/// check if physical device supports given target extensions
// TODO: unify with getRequiredInstanceExtensions?
pub fn isDeviceExtensionsPresent(allocator: Allocator, vki: dispatch.Instance, device: vk.PhysicalDevice, target_extensions: []const [*:0]const u8) !bool {
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

// TODO: use internal allocator that is suitable
/// select primary physical device in init
pub fn selectPrimary(allocator: Allocator, vki: dispatch.Instance, instance: vk.Instance, surface: vk.SurfaceKHR) !vk.PhysicalDevice {
    var device_count: u32 = 0;
    _ = try vki.enumeratePhysicalDevices(instance, &device_count, null); // TODO: handle incomplete
    if (device_count < 0) {
        std.debug.panic("no GPU suitable for vulkan identified");
    }

    var devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(devices);

    _ = try vki.enumeratePhysicalDevices(instance, &device_count, devices.ptr); // TODO: handle incomplete
    devices.len = device_count;

    var device_score: i32 = -1;
    var device_index: ?usize = null;
    for (devices) |device, i| {
        const new_score = try deviceHeuristic(allocator, vki, device, surface);
        if (device_score < new_score) {
            device_score = new_score;
            device_index = i;
        }
    }

    if (device_index == null) {
        return error.NoSuitablePhysicalDevice;
    }

    const val = devices[device_index.?];
    return val;
}

/// Any suiteable GPU should result in a positive value, an unsuitable GPU might return a negative value
fn deviceHeuristic(allocator: Allocator, vki: dispatch.Instance, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !i32 {
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
        const atomics = @intCast(i32, device_features.fragment_stores_and_atomics) * 5;
        const anisotropy = @intCast(i32, device_features.sampler_anisotropy) * 5;
        break :blk atomics + anisotropy;
    };

    const queue_fam_score: i32 = blk: {
        _ = QueueFamilyIndices.init(allocator, vki, device, surface) catch break :blk -1000;
        break :blk 10;
    };

    const extensions_score: i32 = blk: {
        const extension_slice = constants.logicical_device_extensions[0..];
        const extensions_available = try isDeviceExtensionsPresent(allocator, vki, device, extension_slice);
        if (!extensions_available) {
            break :blk -1000;
        }
        break :blk 10;
    };

    const swapchain_score: i32 = blk: {
        if (swapchain.SupportDetails.init(allocator, vki, device, surface)) |ok| {
            defer ok.deinit();
            break :blk 10;
        } else |_| {
            break :blk -1000;
        }
    };

    return -30 + property_score + feature_score + queue_fam_score + extensions_score + swapchain_score;
}

pub fn createLogicalDevice(allocator: Allocator, ctx: Context) !vk.Device {

    // merge indices if they are identical according to vulkan spec
    const family_indices: []const u32 = blk: {
        if (ctx.queue_indices.graphics != ctx.queue_indices.present) {
            break :blk &[_]u32{ ctx.queue_indices.graphics, ctx.queue_indices.present };
        }
        break :blk &[_]u32{ctx.queue_indices.graphics};
    };

    var queue_create_infos = try allocator.alloc(vk.DeviceQueueCreateInfo, family_indices.len);
    defer allocator.free(queue_create_infos);

    const queue_priority = [_]f32{1.0};
    for (family_indices) |family_index, i| {
        queue_create_infos[i] = .{
            .flags = .{},
            .queue_family_index = family_index,
            .queue_count = 1,
            .p_queue_priorities = &queue_priority,
        };
    }

    const device_features = FalsePhysicalDeviceFeatures{};

    const validation_layer_info = try validation_layer.Info.init(allocator, ctx.vkb);

    const create_info = vk.DeviceCreateInfo{
        .flags = .{},
        .queue_create_info_count = @intCast(u32, queue_create_infos.len),
        .p_queue_create_infos = queue_create_infos.ptr,
        .enabled_layer_count = validation_layer_info.enabled_layer_count,
        .pp_enabled_layer_names = validation_layer_info.enabled_layer_names,
        .enabled_extension_count = constants.logicical_device_extensions.len,
        .pp_enabled_extension_names = &constants.logicical_device_extensions,
        .p_enabled_features = @ptrCast(*const vk.PhysicalDeviceFeatures, &device_features),
    };
    return ctx.vki.createDevice(ctx.physical_device, &create_info, null);
}
