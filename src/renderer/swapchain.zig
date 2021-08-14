const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const vk = @import("vulkan");
const glfw = @import("glfw");

const dispatch = @import("dispatch.zig");
const physical_device = @import("physical_device.zig");
const QueueFamilyIndices = physical_device.QueueFamilyIndices;
const Context = @import("context.zig").Context;


pub fn newCreateInfo(
    allocator: *Allocator, 
    vki: dispatch.Instance, 
    queue_indices: physical_device.QueueFamilyIndices, 
    device: vk.PhysicalDevice, 
    surface: vk.SurfaceKHR, 
    window: *glfw.Window
) !vk.SwapchainCreateInfoKHR {
    const sc_support = try SupportDetails.init(allocator, vki, device, surface);
    defer sc_support.deinit();
    if (sc_support.capabilities.max_image_count <= 0) {
        return error.SwapchainNoImageSupport;
    }

    const format = sc_support.selectSwapChainFormat();
    const present_mode = sc_support.selectSwapchainPresentMode();
    const extent = try sc_support.constructSwapChainExtent(window.*);

    const image_count = std.math.min(sc_support.capabilities.min_image_count + 1, sc_support.capabilities.max_image_count);

    const Config = struct {
        sharing_mode: vk.SharingMode,
        index_count: u32,
        p_indices: [*]const u32,
    };
    const sharing_config = blk: {
        if (queue_indices.graphics != queue_indices.present) {
            const indices_arr = [_]u32{ queue_indices.graphics, queue_indices.present };
            break :blk Config{
                .sharing_mode = vk.SharingMode.concurrent, // TODO: read up on ownership in this context
                .index_count = indices_arr.len,
                .p_indices = @ptrCast([*]const u32, &indices_arr[0..indices_arr.len]),
            };
        } else {
            const indices_arr = [_]u32{ queue_indices.graphics, queue_indices.present };
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

pub const SupportDetails = struct {
    const Self = @This();

    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: ArrayList(vk.SurfaceFormatKHR),
    present_modes: ArrayList(vk.PresentModeKHR),

    /// caller has to make sure to also call deinit
    pub fn init(allocator: *Allocator, vki: dispatch.Instance, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !Self {
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

    pub fn selectSwapChainFormat(self: Self) vk.SurfaceFormatKHR {
        // TODO: in some cases this is a valid state?
        //       if so return error here instead ...
        std.debug.assert(self.formats.items.len > 0);

        for (self.formats.items) |format| {
            if (format.format == vk.Format.b8g8r8_srgb and format.color_space == vk.ColorSpaceKHR.srgb_nonlinear_khr) {
                return format;
            }
        }

        return self.formats.items[0];
    }

    pub fn selectSwapchainPresentMode(self: Self) vk.PresentModeKHR {
        for (self.present_modes.items) |present_mode| {
            if (present_mode == vk.PresentModeKHR.mailbox_khr) {
                return present_mode;
            }
        }

        return vk.PresentModeKHR.fifo_khr;
    }

    pub fn constructSwapChainExtent(self: Self, window: glfw.Window) glfw.Error!vk.Extent2D {
        if (self.capabilities.current_extent.width != std.math.maxInt(u32)) {
            return self.capabilities.current_extent;
        } else {
            var window_size = blk: {
                const size = try window.getFramebufferSize();
                break :blk vk.Extent2D{ 
                    .width = @intCast(u32, size.width), 
                    .height = @intCast(u32, size.height) 
                };
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

    pub fn deinit(self: Self) void {
        self.formats.deinit();
        self.present_modes.deinit();
    }
};

pub const Data = struct {
    swapchain: vk.SwapchainKHR,
    images: ArrayList(vk.Image),
    views: ArrayList(vk.ImageView),
    format: vk.Format,
    extent: vk.Extent2D,
};
