const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const vk = @import("vulkan");
const zglfw = @import("zglfw");
const c = @import("c.zig");

const consts = @import("consts.zig");
pub const dispatch = @import("dispatch.zig");
const QueueFamilyIndices = @import("physical_device.zig").QueueFamilyIndices;
const validation_layer = @import("validation_layer.zig");
const vk_utils = @import("vk_utils.zig");

// TODO: move command pool to context?

/// Utilized to supply vulkan methods and common vulkan state to other
/// renderer functions and structs
const Context = @This();

allocator: Allocator,

vkb: dispatch.Base,
vki: dispatch.Instance,
vkd: dispatch.Device,

instance: vk.Instance,
physical_device: vk.PhysicalDevice,
logical_device: vk.Device,

physical_device_properties: vk.PhysicalDeviceProperties,
host_image_properties: vk.PhysicalDeviceHostImageCopyProperties,

compute_queue: vk.Queue,
graphics_queue: vk.Queue,

surface: vk.SurfaceKHR,
queue_indices: QueueFamilyIndices,

// TODO: utilize comptime for this (emit from struct if we are in release mode)
messenger: ?vk.DebugUtilsMessengerEXT,

/// pointer to the window handle. Caution is adviced when using this pointer ...
window_ptr: *zglfw.Window,

// Caller should make sure to call deinit
pub fn init(allocator: Allocator, application_name: []const u8, window: *zglfw.Window) !Context {
    const app_name: [:0]const u8 = app_name_blk: {
        var c_str = try allocator.allocSentinel(u8, application_name.len, 0);
        @memcpy(c_str[0..application_name.len], application_name);
        c_str[c_str.len - 1] = 0;
        break :app_name_blk @ptrCast(c_str);
    };
    defer allocator.free(app_name);

    const app_info = vk.ApplicationInfo{
        .p_next = null,
        .p_application_name = app_name,
        .application_version = @bitCast(consts.application_version),
        .p_engine_name = consts.engine_name,
        .engine_version = @bitCast(consts.engine_version),
        .api_version = @bitCast(consts.vulkan_version),
    };

    // TODO: move to global scope (currently crashes the zig compiler :') )
    const common_extensions = [_][*:0]const u8{vk.extensions.khr_surface.name};
    const application_extensions = blk: {
        if (consts.enable_validation_layers) {
            const debug_extensions = [_][*:0]const u8{
                vk.extensions.ext_debug_utils.name,
            } ++ common_extensions;
            break :blk debug_extensions[0..];
        }
        break :blk common_extensions[0..];
    };

    const glfw_extensions_slice = try zglfw.getRequiredInstanceExtensions();
    // Due to a zig bug we need arraylist to append instead of preallocate slice
    // in release it fail and length turns out to be 1
    var extensions = try ArrayList([*:0]const u8).initCapacity(allocator, glfw_extensions_slice.len + application_extensions.len);
    defer extensions.deinit();

    for (glfw_extensions_slice) |extension| {
        try extensions.append(extension);
    }
    for (application_extensions) |extension| {
        try extensions.append(extension);
    }

    // load base dispatch wrapper
    const vkb = dispatch.Base.load(c.glfwGetInstanceProcAddress);
    if (!(try vk_utils.isInstanceExtensionsPresent(allocator, vkb, extensions.items))) {
        return error.InstanceExtensionNotPresent;
    }

    const validation_layer_info = try validation_layer.Info.init(allocator, vkb);

    const debug_create_info: ?*const vk.DebugUtilsMessengerCreateInfoEXT = blk: {
        if (consts.enable_validation_layers) {
            break :blk &createDefaultDebugCreateInfo();
        } else {
            break :blk null;
        }
    };

    const debug_features = [_]vk.ValidationFeatureEnableEXT{
        .best_practices_ext, // .synchronization_validation_ext,
    };
    const features: ?*const vk.ValidationFeaturesEXT = blk: {
        if (consts.enable_validation_layers) {
            break :blk &vk.ValidationFeaturesEXT{
                .p_next = @ptrCast(debug_create_info),
                .enabled_validation_feature_count = debug_features.len,
                .p_enabled_validation_features = &debug_features,
                .disabled_validation_feature_count = 0,
                .p_disabled_validation_features = undefined,
            };
        }
        break :blk null;
    };

    const instance = blk: {
        const instance_info = vk.InstanceCreateInfo{
            .p_next = @ptrCast(features),
            .flags = .{},
            .p_application_info = &app_info,
            .enabled_layer_count = validation_layer_info.enabled_layer_count,
            .pp_enabled_layer_names = validation_layer_info.enabled_layer_names,
            .enabled_extension_count = @intCast(extensions.items.len),
            .pp_enabled_extension_names = @ptrCast(extensions.items.ptr),
        };
        break :blk try vkb.createInstance(&instance_info, null);
    };

    const vki = dispatch.Instance.load(instance, vkb.dispatch.vkGetInstanceProcAddr.?);
    errdefer vki.destroyInstance(instance, null);

    var surface: vk.SurfaceKHR = undefined;
    const result: vk.Result = c.glfwCreateWindowSurface(instance, window, null, &surface);
    if (result != .success) {
        return error.FailedToCreateSurface;
    }
    errdefer vki.destroySurfaceKHR(instance, surface, null);

    const physical_device = try @import("physical_device.zig").selectPrimary(allocator, vki, instance, surface);
    const queue_indices = try QueueFamilyIndices.init(allocator, vki, physical_device, surface);

    const messenger = blk: {
        if (!consts.enable_validation_layers) break :blk null;
        break :blk vki.createDebugUtilsMessengerEXT(instance, debug_create_info.?, null) catch {
            std.debug.panic("failed to create debug messenger", .{});
        };
    };
    const logical_device = try @import("physical_device.zig").createLogicalDevice(
        allocator,
        vkb,
        vki,
        queue_indices,
        physical_device,
    );

    const vkd = dispatch.Device.load(logical_device, vki.dispatch.vkGetDeviceProcAddr.?);
    const compute_queue = vkd.getDeviceQueue(logical_device, queue_indices.compute, 0);
    const graphics_queue = vkd.getDeviceQueue(logical_device, queue_indices.graphics, 0);

    var host_image_properties = vk.PhysicalDeviceHostImageCopyProperties{
        .optimal_tiling_layout_uuid = undefined,
        .identical_memory_type_requirements = undefined,
    };
    var properties = vk.PhysicalDeviceProperties2{ .p_next = @ptrCast(&host_image_properties), .properties = undefined };
    vki.getPhysicalDeviceProperties2(physical_device, &properties);

    return Context{
        .allocator = allocator,
        .vkb = vkb,
        .vki = vki,
        .vkd = vkd,
        .instance = instance,
        .physical_device = physical_device,
        .logical_device = logical_device,
        .compute_queue = compute_queue,
        .graphics_queue = graphics_queue,
        .physical_device_properties = properties.properties,
        .host_image_properties = host_image_properties,
        .surface = surface,
        .queue_indices = queue_indices,
        .messenger = messenger,
        .window_ptr = window,
    };
}

pub fn deinit(self: Context) void {
    self.vki.destroySurfaceKHR(self.instance, self.surface, null);
    self.vkd.destroyDevice(self.logical_device, null);

    if (consts.enable_validation_layers) {
        self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.messenger.?, null);
    }
    self.vki.destroyInstance(self.instance, null);
}

pub fn destroyShaderModule(self: Context, module: vk.ShaderModule) void {
    self.vkd.destroyShaderModule(self.logical_device, module, null);
}

/// caller must destroy returned module
pub fn createPipelineLayout(self: Context, create_info: vk.PipelineLayoutCreateInfo) !vk.PipelineLayout {
    return self.vkd.createPipelineLayout(self.logical_device, &create_info, null);
}

pub fn destroyPipelineLayout(self: Context, pipeline_layout: vk.PipelineLayout) void {
    self.vkd.destroyPipelineLayout(self.logical_device, pipeline_layout, null);
}

/// caller must destroy pipeline from vulkan
pub inline fn createGraphicsPipeline(self: Context, create_info: vk.GraphicsPipelineCreateInfo) !vk.Pipeline {
    var pipeline: vk.Pipeline = undefined;
    const result = try self.vkd.createGraphicsPipelines(
        self.logical_device,
        .null_handle,
        1,
        @ptrCast(&create_info),
        null,
        @ptrCast(&pipeline),
    );
    if (result != vk.Result.success) {
        // TODO: not panic?
        std.debug.panic("failed to initialize pipeline!", .{});
    }
    return pipeline;
}

/// caller must both destroy pipeline from the heap and in vulkan
pub fn createComputePipeline(self: Context, create_info: vk.ComputePipelineCreateInfo) !vk.Pipeline {
    var pipeline: vk.Pipeline = undefined;
    const result = try self.vkd.createComputePipelines(
        self.logical_device,
        .null_handle,
        1,
        @ptrCast(&create_info),
        null,
        @ptrCast(&pipeline),
    );
    if (result != vk.Result.success) {
        // TODO: not panic?
        std.debug.panic("failed to initialize pipeline!", .{});
    }

    return pipeline;
}

/// destroy pipeline from vulkan *not* from the application memory
pub fn destroyPipeline(self: Context, pipeline: *vk.Pipeline) void {
    self.vkd.destroyPipeline(self.logical_device, pipeline.*, null);
}

/// caller must destroy returned render pass
pub fn createRenderPass(self: Context, format: vk.Format) !vk.RenderPass {
    const color_attachment = [_]vk.AttachmentDescription{
        .{
            .flags = .{},
            .format = format,
            .samples = .{
                .@"1_bit" = true,
            },
            .load_op = .dont_care,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .present_src_khr,
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
        .src_stage_mask = .{
            .color_attachment_output_bit = true,
        },
        .dst_stage_mask = .{
            .color_attachment_output_bit = true,
        },
        .src_access_mask = .{},
        .dst_access_mask = .{
            .color_attachment_write_bit = true,
        },
        .dependency_flags = .{},
    };
    const render_pass_info = vk.RenderPassCreateInfo{
        .flags = .{},
        .attachment_count = color_attachment.len,
        .p_attachments = &color_attachment,
        .subpass_count = subpass.len,
        .p_subpasses = &subpass,
        .dependency_count = 1,
        .p_dependencies = @ptrCast(&subpass_dependency),
    };
    return try self.vkd.createRenderPass(self.logical_device, &render_pass_info, null);
}

pub fn destroyRenderPass(self: Context, render_pass: vk.RenderPass) void {
    self.vkd.destroyRenderPass(self.logical_device, render_pass, null);
}

// TODO: should not be in context ...
pub fn hasCopySrcLayout(self: Context, src_layout: vk.ImageLayout) bool {
    if (self.host_image_properties.p_copy_src_layouts) |copy_src_layouts| {
        const copy_src_layout_count = self.host_image_properties.copy_src_layout_count;
        for (copy_src_layouts[0..copy_src_layout_count]) |device_src_layout| {
            if (src_layout == device_src_layout) {
                return true;
            }
        }
    }

    return false;
}

// TODO: can probably drop function and inline it in init
fn createDefaultDebugCreateInfo() vk.DebugUtilsMessengerCreateInfoEXT {
    const message_severity = vk.DebugUtilsMessageSeverityFlagsEXT{
        .verbose_bit_ext = false,
        .info_bit_ext = false,
        .warning_bit_ext = true,
        .error_bit_ext = true,
    };

    const message_type = vk.DebugUtilsMessageTypeFlagsEXT{
        .general_bit_ext = true,
        .validation_bit_ext = true,
        .performance_bit_ext = true,
    };

    return vk.DebugUtilsMessengerCreateInfoEXT{
        .p_next = null,
        .flags = .{},
        .message_severity = message_severity,
        .message_type = message_type,
        .pfn_user_callback = &validation_layer.messageCallback,
        .p_user_data = null,
    };
}
