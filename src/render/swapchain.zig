const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const zglfw = @import("zglfw");
const ecez = @import("ecez");

const dispatch = @import("dispatch.zig");
const physical_device = @import("physical_device.zig");
const context = @import("context.zig");
const texture = @import("texture.zig");

pub const components = struct {
    pub const SwapchainData = struct {
        pub const max_images = 16;

        swapchain: vk.SwapchainKHR,
        image_len: usize,
        images: [max_images]vk.Image,
        image_views: [max_images]vk.ImageView,
        format: vk.Format,
        extent: vk.Extent2D,
    };
};

pub const queries = struct {
    pub const SwapchainData = ecez.QueryAny(struct {
        data: components.SwapchainData,
    }, .{}, .{});
};

pub const systems = struct {
    pub const deinit = struct {
        // TODO: event argument for ctx?
        pub fn swapchainData(swapchain_data_query: *queries.SwapchainData, ctx_query: *context.queries.VkdAndDevice) void {
            const swapchain_entity = swapchain_data_query.getAny() orelse return;
            const ctx = ctx_query.getAny().?;

            destroySwapchainData(ctx.vkd, ctx.logical_device, swapchain_entity.data);
        }
    };
};

// TODO: mutex! : the data is shared between rendering implementation and pipeline
//                pipeline will attempt to update the data in the event of rescale which might lead to RC

/// Allocator needed for init only, no memory is needed to be deleted after normal return
pub fn createSwapchainComponent(
    allocator: Allocator,
    ctx_entity: ecez.Entity,
    comptime Storage: type,
    storage: *Storage,
    old_swapchain: ?vk.SwapchainKHR,
) !components.SwapchainData {
    const ctx = try storage.getComponents(ctx_entity, struct {
        vki: context.components.vk_dispatch.Instance,
        vkd: context.components.vk_dispatch.Device,
        physical_device: context.components.PhysicalDevice,
        queue_indices: context.components.QueueFamilyIndices,
        graphics_queue: context.components.GraphicsQueue,
        logical_device: context.components.Device,
        surface: context.components.Surface,
        window: context.components.WindowPtr,
        auxillary_cmd_pool: context.components.AuxillaryCommandPool,
    });

    const sc_create_info = create_swapchain_info_blk: {
        const support_details = try SupportDetails.init(
            allocator,
            ctx.vki,
            ctx.physical_device.v,
            ctx.surface.v,
        );
        defer support_details.deinit(allocator);

        const format = support_details.selectSwapChainFormat();
        const present_mode = support_details.selectSwapchainPresentMode();
        const extent = try support_details.constructSwapChainExtent(ctx.window.ptr);

        const max_images = if (support_details.capabilities.max_image_count == 0) std.math.maxInt(u32) else support_details.capabilities.max_image_count;
        const image_count = @min(support_details.capabilities.min_image_count + 1, max_images);

        const Config = struct {
            sharing_mode: vk.SharingMode,
            index_count: u32,
            p_indices: [*]const u32,
        };
        const sharing_config = Config{
            .sharing_mode = .exclusive,
            .index_count = 1,
            .p_indices = @ptrCast(&ctx.queue_indices.graphics),
        };

        break :create_swapchain_info_blk vk.SwapchainCreateInfoKHR{
            .flags = .{},
            .surface = ctx.surface.v,
            .min_image_count = image_count,
            .image_format = format.format,
            .image_color_space = format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = vk.ImageUsageFlags{ .color_attachment_bit = true },
            .image_sharing_mode = sharing_config.sharing_mode,
            .queue_family_index_count = sharing_config.index_count,
            .p_queue_family_indices = sharing_config.p_indices,
            .pre_transform = support_details.capabilities.current_transform,
            .composite_alpha = vk.CompositeAlphaFlagsKHR{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = old_swapchain orelse .null_handle,
        };
    };

    const swapchain_khr = try ctx.vkd.createSwapchainKHR(ctx.logical_device.v, &sc_create_info, null);
    var image_len: u32 = 0;
    const swapchain_images = blk: {
        _ = try ctx.vkd.getSwapchainImagesKHR(ctx.logical_device.v, swapchain_khr, &image_len, null);

        var images: [components.SwapchainData.max_images]vk.Image = undefined;

        // TODO: handle incomplete
        _ = try ctx.vkd.getSwapchainImagesKHR(ctx.logical_device.v, swapchain_khr, &image_len, &images);
        break :blk images;
    };

    // Assumption: you will never have more than 16 swapchain images..
    std.debug.assert(image_len <= components.SwapchainData.max_images);

    var transition_configs: [components.SwapchainData.max_images]texture.TransitionConfig = undefined;
    for (transition_configs[0..image_len], swapchain_images[0..image_len]) |*transition_config, image| {
        transition_config.* = .{
            .image = image,
            .old_layout = .undefined,
            .new_layout = .present_src_khr,
        };
    }
    try texture.transitionImageLayouts(
        ctx.vkd,
        ctx.logical_device,
        ctx.graphics_queue,
        ctx.auxillary_cmd_pool.pool,
        transition_configs[0..image_len],
    );

    const image_views = blk: {
        var views: [components.SwapchainData.max_images]vk.ImageView = undefined;

        const mappings = vk.ComponentMapping{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        };
        const subresource_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        for (swapchain_images[0..image_len], views[0..image_len]) |image, *view| {
            const create_info = vk.ImageViewCreateInfo{
                .flags = .{},
                .image = image,
                .view_type = .@"2d",
                .format = sc_create_info.image_format,
                .components = mappings,
                .subresource_range = subresource_range,
            };
            view.* = try ctx.vkd.createImageView(ctx.logical_device.v, &create_info, null);
        }

        break :blk views;
    };

    return components.SwapchainData{
        .swapchain = swapchain_khr,
        .image_len = image_len,
        .images = swapchain_images,
        .image_views = image_views,
        .format = sc_create_info.image_format,
        .extent = sc_create_info.image_extent,
    };
}

pub fn destroySwapchainData(
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.Device,
    swapchain_data: components.SwapchainData,
) void {
    for (swapchain_data.image_views[0..swapchain_data.image_len]) |view| {
        vkd.destroyImageView(logical_device.v, view, null);
    }
    vkd.destroySwapchainKHR(logical_device.v, swapchain_data.swapchain, null);
}

pub const SupportDetails = struct {
    const Self = @This();

    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,

    /// caller has to make sure to also call deinit
    pub fn init(allocator: Allocator, vki: dispatch.Instance, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !Self {
        const capabilities = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(device, surface);

        var format_count: u32 = 0;
        // TODO: handle incomplete
        _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null);
        if (format_count <= 0) {
            return error.NoSurfaceFormatsSupported;
        }
        const formats = blk: {
            var formats = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
            _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, formats.ptr);
            formats.len = format_count;
            break :blk formats;
        };
        errdefer allocator.free(formats);

        var present_modes_count: u32 = 0;
        _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_modes_count, null);
        if (present_modes_count <= 0) {
            return error.NoPresentModesSupported;
        }
        const present_modes = blk: {
            var present_modes = try allocator.alloc(vk.PresentModeKHR, present_modes_count);
            _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_modes_count, present_modes.ptr);
            present_modes.len = present_modes_count;
            break :blk present_modes;
        };
        errdefer allocator.free(present_modes);

        return Self{
            .capabilities = capabilities,
            .formats = formats,
            .present_modes = present_modes,
        };
    }

    pub fn selectSwapChainFormat(self: Self) vk.SurfaceFormatKHR {
        // TODO: in some cases this is a valid state?
        //       if so return error here instead ...
        std.debug.assert(self.formats.len > 0);

        for (self.formats) |format| {
            if (format.format == .b8g8r8a8_unorm and format.color_space == .srgb_nonlinear_khr) {
                return format;
            }
        }

        return self.formats[0];
    }

    pub fn selectSwapchainPresentMode(self: Self) vk.PresentModeKHR {
        for (self.present_modes) |present_mode| {
            if (present_mode == .mailbox_khr) {
                return present_mode;
            }
        }

        return .fifo_khr;
    }

    pub fn constructSwapChainExtent(self: Self, window: *zglfw.Window) !vk.Extent2D {
        if (self.capabilities.current_extent.width != std.math.maxInt(u32)) {
            return self.capabilities.current_extent;
        } else {
            const window_size = blk: {
                const size = window.getFramebufferSize();
                break :blk vk.Extent2D{
                    .width = @intCast(size[0]),
                    .height = @intCast(size[1]),
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

    pub fn deinit(self: Self, allocator: Allocator) void {
        allocator.free(self.formats);
        allocator.free(self.present_modes);
    }
};
