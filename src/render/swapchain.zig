const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const vk = @import("vulkan");
const glfw = @import("glfw");

const dispatch = @import("dispatch.zig");
const physical_device = @import("physical_device.zig");
const QueueFamilyIndices = physical_device.QueueFamilyIndices;
const Context = @import("Context.zig");

pub const ViewportScissor = struct {
    viewport: [1]vk.Viewport,
    scissor: [1]vk.Rect2D,

    /// utility to create simple view state info
    pub fn init(extent: vk.Extent2D) ViewportScissor {
        // TODO: this can be broken down a bit since the code is pretty cluster fck
        const width = extent.width;
        const height = extent.height;
        return .{
            .viewport = [1]vk.Viewport{
                .{ .x = 0, .y = 0, .width = @intToFloat(f32, width), .height = @intToFloat(f32, height), .min_depth = 0.0, .max_depth = 1.0 },
            },
            .scissor = [1]vk.Rect2D{
                .{ .offset = .{
                    .x = 0,
                    .y = 0,
                }, .extent = extent },
            },
        };
    }
};

// TODO: rename
// TODO: mutex! : the data is shared between rendering implementation and pipeline
//                pipeline will attempt to update the data in the event of rescale which might lead to RC
pub const Data = struct {
    allocator: Allocator,
    swapchain: vk.SwapchainKHR,
    images: []vk.Image,
    image_views: []vk.ImageView,
    format: vk.Format,
    extent: vk.Extent2D,
    support_details: SupportDetails,

    // create a swapchain data struct, caller must make sure to call deinit
    pub fn init(allocator: Allocator, ctx: Context, old_swapchain: ?vk.SwapchainKHR) !Data {
        const support_details = try SupportDetails.init(allocator, ctx.vki, ctx.physical_device, ctx.surface);
        errdefer support_details.deinit(allocator);

        const sc_create_info = blk1: {
            if (support_details.capabilities.max_image_count <= 0) {
                return error.SwapchainNoImageSupport;
            }

            const format = support_details.selectSwapChainFormat();
            const present_mode = support_details.selectSwapchainPresentMode();
            const extent = try support_details.constructSwapChainExtent(ctx.window_ptr.*);

            const image_count = std.math.min(support_details.capabilities.min_image_count + 1, support_details.capabilities.max_image_count);

            const Config = struct {
                sharing_mode: vk.SharingMode,
                index_count: u32,
                p_indices: [*]const u32,
            };
            const sharing_config = blk2: {
                if (ctx.queue_indices.graphics != ctx.queue_indices.present) {
                    const indices_arr = [_]u32{ ctx.queue_indices.graphics, ctx.queue_indices.present };
                    break :blk2 Config{
                        .sharing_mode = vk.SharingMode.concurrent, // TODO: read up on ownership in this context
                        .index_count = indices_arr.len,
                        .p_indices = @ptrCast([*]const u32, &indices_arr[0..indices_arr.len]),
                    };
                } else {
                    const indices_arr = [_]u32{ ctx.queue_indices.graphics, ctx.queue_indices.present };
                    break :blk2 Config{
                        .sharing_mode = vk.SharingMode.exclusive,
                        .index_count = 0,
                        .p_indices = @ptrCast([*]const u32, &indices_arr[0..indices_arr.len]),
                    };
                }
            };

            break :blk1 vk.SwapchainCreateInfoKHR{
                .flags = .{},
                .surface = ctx.surface,
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
                .old_swapchain = old_swapchain orelse vk.SwapchainKHR.null_handle,
            };
        };
        const swapchain_khr = try ctx.vkd.createSwapchainKHR(ctx.logical_device, &sc_create_info, null);
        const swapchain_images = blk: {
            var image_count: u32 = 0;

            // TODO: handle incomplete
            _ = try ctx.vkd.getSwapchainImagesKHR(ctx.logical_device, swapchain_khr, &image_count, null);

            var images = try allocator.alloc(vk.Image, image_count);
            errdefer allocator.free(images);

            // TODO: handle incomplete
            _ = try ctx.vkd.getSwapchainImagesKHR(ctx.logical_device, swapchain_khr, &image_count, images.ptr);
            images.len = image_count;
            break :blk images;
        };
        errdefer allocator.free(swapchain_images);

        const image_views = blk: {
            const image_view_count = swapchain_images.len;
            var views = try allocator.alloc(vk.ImageView, image_view_count);
            errdefer allocator.free(views);

            const components = vk.ComponentMapping{
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
            {
                var i: u32 = 0;
                while (i < image_view_count) : (i += 1) {
                    const create_info = vk.ImageViewCreateInfo{
                        .flags = .{},
                        .image = swapchain_images[i],
                        .view_type = .@"2d",
                        .format = sc_create_info.image_format,
                        .components = components,
                        .subresource_range = subresource_range,
                    };
                    views[i] = try ctx.vkd.createImageView(ctx.logical_device, &create_info, null);
                }
            }

            break :blk views;
        };
        errdefer allocator.free(image_views);

        return Data{
            .allocator = allocator,
            .swapchain = swapchain_khr,
            .images = swapchain_images,
            .image_views = image_views,
            .format = sc_create_info.image_format,
            .extent = sc_create_info.image_extent,
            .support_details = support_details,
        };
    }

    pub fn deinit(self: Data, ctx: Context) void {
        for (self.image_views) |view| {
            ctx.vkd.destroyImageView(ctx.logical_device, view, null);
        }
        self.allocator.free(self.image_views);
        self.allocator.free(self.images);
        self.support_details.deinit(self.allocator);

        ctx.vkd.destroySwapchainKHR(ctx.logical_device, self.swapchain, null);
    }
};

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
            if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
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

    pub fn constructSwapChainExtent(self: Self, window: glfw.Window) glfw.Error!vk.Extent2D {
        if (self.capabilities.current_extent.width != std.math.maxInt(u32)) {
            return self.capabilities.current_extent;
        } else {
            var window_size = blk: {
                const size = try window.getFramebufferSize();
                break :blk vk.Extent2D{ .width = @intCast(u32, size.width), .height = @intCast(u32, size.height) };
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
