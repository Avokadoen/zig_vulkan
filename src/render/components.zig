const std = @import("std");
const Allocator = std.mem.Allocator;

const zglfw = @import("zglfw");

const vk = @import("vulkan");

const dispatch = @import("dispatch.zig");

pub const EventArgument = struct {
    allocator: Allocator,
    window_ptr: *zglfw.Window,
};

pub const Messenger = struct {
    messenger: vk.DebugUtilsMessengerEXT,
};

pub const Context = struct {
    vkb: dispatch.Base,
    vki: dispatch.Instance,
    vkd: dispatch.Device,

    instance: vk.Instance,
    physical_device_limits: vk.PhysicalDeviceLimits,
    physical_device: vk.PhysicalDevice,
    logical_device: vk.Device,

    compute_queue: vk.Queue,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,

    surface: vk.SurfaceKHR,
    queue_indices: QueueFamilyIndices,
};

pub const ComputeQueue = struct {
    queue: vk.Queue,
};

pub const GraphicsPresentQueue = struct {
    graphics: vk.Queue,
};
