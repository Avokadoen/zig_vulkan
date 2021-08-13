const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const vk = @import("vulkan");
const glfw = @import("glfw");
// TODO: problematic to have c in outer scope if it is used here ...
const c = @import("../c.zig");

const constants = @import("consts.zig");
const dispatch = @import("dispatch.zig");
const swapchain = @import("swapchain.zig");
const physical_device = @import("physical_device.zig");
const QueueFamilyIndices = physical_device.QueueFamilyIndices;
const validation_layer = @import("validation_layer.zig");
const vk_utils = @import("vk_utils.zig");

pub const IoWriters = struct {
    stdout: *const std.fs.File.Writer,
    stderr: *const std.fs.File.Writer,
};

/// Utilized to supply vulkan methods and common vulkan state to other
/// renderer functions and structs
pub const Context = struct {
    allocator: *Allocator,

    vkb: dispatch.Base,
    vki: dispatch.Instance,
    vkd: dispatch.Device,

    instance: vk.Instance,
    physical_device: vk.PhysicalDevice,
    logical_device: vk.Device,

    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
    surface: vk.SurfaceKHR,
    swapchain_data: swapchain.Data,
    queue_indices: QueueFamilyIndices,

    // TODO: utilize comptime for this (emit from struct if we are in release mode)
    messenger: ?vk.DebugUtilsMessengerEXT,
    writers: *IoWriters,

    /// pointer to the window handle. Caution is adviced when using this pointer ...
    window_ptr: *glfw.Window,

    // Caller should make sure to call deinit, context takes ownership of IoWriters
    pub fn init(allocator: *Allocator, application_name: []const u8, window: *glfw.Window, writers: *IoWriters) !Context {
        const app_name = try std.cstr.addNullByte(allocator, application_name);
        defer allocator.destroy(app_name.ptr);
        
        const app_info = vk.ApplicationInfo{
            .p_next = null,
            .p_application_name = app_name,
            .application_version = vk.makeApiVersion(0, 0, 1, 0),
            .p_engine_name = constants.engine_name,
            .engine_version = vk.makeApiVersion(0, 0, 1, 0),
            .api_version = vk.API_VERSION_1_2,
        };

        // TODO: move to global scope (currently crashes the zig compiler :') )
        const application_extensions = blk: {
            const common_extensions = [_][*:0]const u8{vk.extension_info.khr_surface.name};
            if (constants.enable_validation_layers) {
                const debug_extensions = [_][*:0]const u8{
                    vk.extension_info.ext_debug_report.name,
                    vk.extension_info.ext_debug_utils.name,
                } ++ common_extensions;
                break :blk debug_extensions[0..];
            }
            break :blk common_extensions[0..];
        };

        const extensions = blk: {
            const glfw_extensions_slice = try glfw.vulkan.getRequiredInstanceExtensions();
            var extensions = try ArrayList([*:0]const u8).initCapacity(allocator, glfw_extensions_slice.len + application_extensions.len);
            for (glfw_extensions_slice) |extension| {
                extensions.appendAssumeCapacity(extension);
            }
            for (application_extensions) |extension| {
                extensions.appendAssumeCapacity(extension);
            }
            break :blk extensions;
        };
        defer extensions.deinit();

        // load base dispatch wrapper
        const vkb = try dispatch.Base.load(c.glfwGetInstanceProcAddress);
        if (!(try vk_utils.isInstanceExtensionsPresent(allocator, vkb, application_extensions))) {
            return error.InstanceExtensionNotPresent;
        }

        const validation_layer_info = try validation_layer.Info.init(allocator, vkb);

        var create_p_next: ?*c_void = null;
        if (constants.enable_validation_layers) {
            var debug_create_info = createDefaultDebugCreateInfo(writers);
            create_p_next = @ptrCast(?*c_void, &debug_create_info);
        }

        const instance = blk: {
            const instanceInfo = vk.InstanceCreateInfo{
                .p_next = create_p_next,
                .flags = .{},
                .p_application_info = &app_info,
                .enabled_layer_count = validation_layer_info.enabled_layer_count,
                .pp_enabled_layer_names = validation_layer_info.enabled_layer_names,
                .enabled_extension_count = @intCast(u32, extensions.items.len),
                .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, extensions.items.ptr),
            };
            break :blk try vkb.createInstance(instanceInfo, null);
        };

        const vki = try dispatch.Instance.load(instance, c.glfwGetInstanceProcAddress);
        errdefer vki.destroyInstance(instance, null);

        var surface: vk.SurfaceKHR = undefined;
        if (c.glfwCreateWindowSurface(instance, window.handle, null, &surface) != .success) {
            return error.SurfaceInitFailed;
        }
        errdefer vki.destroySurfaceKHR(instance, surface, null);

        const p_device = try physical_device.selectPrimary(allocator, vki, instance, surface);

        const queue_indices = try QueueFamilyIndices.init(allocator, vki, p_device, surface);

        const messenger = blk: {
            if (!constants.enable_validation_layers) break :blk null;

            const create_info = createDefaultDebugCreateInfo(writers);

            break :blk vki.createDebugUtilsMessengerEXT(instance, create_info, null) catch {
                std.debug.panic("failed to create debug messenger", .{});
            };
        };
        const logical_device = try physical_device.createLogicalDevice(allocator, vkb, vki, queue_indices, p_device);

        const vkd = try dispatch.Device.load(logical_device, vki.dispatch.vkGetDeviceProcAddr);
        const graphics_queue = vkd.getDeviceQueue(logical_device, queue_indices.graphics, 0);
        const present_queue = vkd.getDeviceQueue(logical_device, queue_indices.present, 0);

        const swapchain_data = blk1: {
            const sc_create_info = try swapchain.newCreateInfo(allocator, vki, queue_indices, p_device, surface, window);
            const swapchain_khr = try vkd.createSwapchainKHR(logical_device, sc_create_info, null);
            const swapchain_images = blk2: {
                var image_count: u32 = 0;
                // TODO: handle incomplete
                _ = try vkd.getSwapchainImagesKHR(logical_device, swapchain_khr, &image_count, null);
                var images = try ArrayList(vk.Image).initCapacity(allocator, image_count);
                // TODO: handle incomplete
                _ = try vkd.getSwapchainImagesKHR(logical_device, swapchain_khr, &image_count, images.items.ptr);
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

            break :blk1 swapchain.Data{
                .swapchain = swapchain_khr,
                .images = swapchain_images,
                .views = image_views,
                .format = sc_create_info.image_format,
                .extent = sc_create_info.image_extent,
            };
        };

        return Context{
            .allocator = allocator,
            .vkb = vkb,
            .vki = vki,
            .vkd = vkd,
            .instance = instance,
            .physical_device = p_device,
            .logical_device = logical_device,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .surface = surface,
            .queue_indices = queue_indices,
            .swapchain_data = swapchain_data,
            .messenger = messenger,
            .writers = writers,
            .window_ptr = window,
        };
    }

    // TODO: remove create/destroy that are thin wrappers (make data public instead)
    /// caller must destroy returned module
    pub fn createShaderModule(self: Context, spir_v: []const u8) !vk.ShaderModule {
        const create_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .p_code = @ptrCast([*]const u32, @alignCast(4, spir_v.ptr)),
            .code_size = spir_v.len,
        };

        return self.vkd.createShaderModule(self.logical_device, create_info, null);
    }

    pub fn destroyShaderModule(self: Context, module: vk.ShaderModule) void {
        self.vkd.destroyShaderModule(self.logical_device, module, null);
    }

    /// caller must destroy returned module 
    pub fn createPipelineLayout(self: Context, create_info: vk.PipelineLayoutCreateInfo) !vk.PipelineLayout {
        return self.vkd.createPipelineLayout(self.logical_device, create_info, null);
    }

    pub fn destroyPipelineLayout(self: Context, pipeline_layout: vk.PipelineLayout) void {
        self.vkd.destroyPipelineLayout(self.logical_device, pipeline_layout, null);
    }

    /// caller must both destroy pipeline from the heap and in vulkan
    pub fn createGraphicsPipelines(self: Context, allocator: *Allocator, create_info: vk.GraphicsPipelineCreateInfo) !*vk.Pipeline {
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
    pub fn destroyPipeline(self: Context, pipeline: *vk.Pipeline) void {
        self.vkd.destroyPipeline(self.logical_device, pipeline.*, null);
    }

    /// caller must destroy returned render pass
    pub fn createRenderPass(self: Context) !vk.RenderPass {
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
        const subpass_dependency = vk.SubpassDependency{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = .{ .color_attachment_output_bit = true, },
            .dst_stage_mask = .{ .color_attachment_output_bit = true, },
            .src_access_mask = .{},
            .dst_access_mask = .{ .color_attachment_write_bit = true, },
            .dependency_flags = .{},
        };
        const render_pass_info = vk.RenderPassCreateInfo{
            .flags = .{},
            .attachment_count = color_attachment.len,
            .p_attachments = &color_attachment,
            .subpass_count = subpass.len,
            .p_subpasses = &subpass,
            .dependency_count = 1,
            .p_dependencies = @ptrCast([*]const vk.SubpassDependency, &subpass_dependency),
        };

        return try self.vkd.createRenderPass(self.logical_device, render_pass_info, null);
    }

    pub fn destroyRenderPass(self: Context, render_pass: vk.RenderPass) void {
        self.vkd.destroyRenderPass(self.logical_device, render_pass, null);
    }

    /// utility to create simple view state info
    pub fn createViewportScissors(self: Context) struct { viewport: [1]vk.Viewport, scissor: [1]vk.Rect2D } {
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

    pub fn deinit(self: Context) void {
        for (self.swapchain_data.views.items) |view| {
            self.vkd.destroyImageView(self.logical_device, view, null);
        }
        self.swapchain_data.views.deinit();
        self.swapchain_data.images.deinit();

        self.vkd.destroySwapchainKHR(self.logical_device, self.swapchain_data.swapchain, null);
        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        self.vkd.destroyDevice(self.logical_device, null);

        if (constants.enable_validation_layers) {
            self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.messenger.?, null);
        }
        self.vki.destroyInstance(self.instance, null);
    }
};

// TODO: can probably drop function and inline it in init
fn createDefaultDebugCreateInfo(writers: *IoWriters) vk.DebugUtilsMessengerCreateInfoEXT {
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
        .pfn_user_callback = validation_layer.messageCallback,
        .p_user_data = @ptrCast(?*c_void, writers),
    };
}
