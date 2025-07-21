const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const vk = @import("vulkan");
const zglfw = @import("zglfw");
const c = @import("c.zig");
const ecez = @import("ecez");

const consts = @import("consts.zig");
const dispatch = @import("dispatch.zig");
const validation_layer = @import("validation_layer.zig");
const vk_utils = @import("vk_utils.zig");

pub const components = struct {
    pub const vk_dispatch = struct {
        pub const Base = dispatch.Base;
        pub const Instance = dispatch.Instance;
        pub const Device = dispatch.Device;
    };

    pub const Instance = struct { v: vk.Instance };
    pub const PhysicalDeviceProperties = vk.PhysicalDeviceProperties;
    pub const PhysicalDeviceHostImageCopyProperties = vk.PhysicalDeviceHostImageCopyProperties;
    pub const PhysicalDevice = struct { v: vk.PhysicalDevice };
    pub const Device = struct { v: vk.Device };
    pub const Surface = struct { v: vk.SurfaceKHR };

    pub const DebugUtilsMessenger = struct { v: vk.DebugUtilsMessengerEXT };

    pub const ComputeQueue = struct {
        queue: vk.Queue,
    };
    pub const GraphicsQueue = struct {
        queue: vk.Queue,
    };
    pub const QueueFamilyIndices = struct {
        pub const max_family_count = 32;

        compute: u32,
        compute_queue_count: u32,
        graphics: u32,
    };

    pub const WindowPtr = struct {
        ptr: *zglfw.Window,
    };

    pub const AuxillaryCommandPool = struct {
        pool: vk.CommandPool,
    };

    // TODO: should swapchain be part of the Context entity + auxillary command pools?
};

pub fn createQueueFamilyIndices(vki: dispatch.Instance, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !components.QueueFamilyIndices {
    var queue_family_count: u32 = 0;
    vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);
    queue_family_count = @min(queue_family_count, components.QueueFamilyIndices.max_family_count);

    var queue_families: [components.QueueFamilyIndices.max_family_count]vk.QueueFamilyProperties = undefined;
    vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, &queue_families);

    const compute_bit = vk.QueueFlags{
        .compute_bit = true,
    };
    const graphics_bit = vk.QueueFlags{
        .graphics_bit = true,
    };

    var compute_index: ?u32 = null;
    var compute_queue_count: u32 = 0;
    var graphics_index: ?u32 = null;
    var present_index: ?u32 = null;
    for (queue_families[0..queue_family_count], 0..) |queue_family, i| {
        const index: u32 = @intCast(i);

        const is_graphics = graphics_index == null and queue_family.queue_flags.contains(graphics_bit);
        const is_present = present_index == null and (try vki.getPhysicalDeviceSurfaceSupportKHR(physical_device, index, surface)) == vk.TRUE;
        if (is_graphics and is_present) {
            graphics_index = index;
            present_index = index;
        }

        const is_compute = queue_family.queue_flags.contains(compute_bit);
        const id_first_compute = is_compute and compute_index == null;
        const is_discrete_compute = is_compute and !is_graphics and !is_present;
        if (id_first_compute or is_discrete_compute) {
            compute_index = index;
            compute_queue_count = queue_family.queue_count;
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

    return components.QueueFamilyIndices{
        .compute = compute_index.?,
        .compute_queue_count = compute_queue_count,
        .graphics = graphics_index.?,
    };
}

pub const queries = struct {
    pub const VkdAndDevice = ecez.QueryAny(struct {
        vkd: components.vk_dispatch.Device,
        logical_device: components.Device,
    }, .{}, .{});

    pub const PhysicalDeviceProperties = ecez.QueryAny(struct {
        properties: components.PhysicalDeviceProperties,
    }, .{}, .{});

    pub const DeinitComponents = ecez.QueryAny(struct {
        entity: ecez.Entity,
        vki: components.vk_dispatch.Instance,
        vkd: components.vk_dispatch.Device,
        surface: components.Surface,
        logical_device: components.Device,
        instance: components.Instance,
        auxillary_cmd_pool: components.AuxillaryCommandPool,
    }, .{}, .{});
};

pub fn CreateSystems(comptime Storage: type) type {
    return struct {
        const MessageStorage = Storage.Subset(.{components.DebugUtilsMessenger});

        pub const deinit = struct {
            pub fn context(ctx_query: *queries.DeinitComponents, message_storage: *MessageStorage) void {
                const ctx = ctx_query.getAny().?;
                ctx.vkd.destroyCommandPool(ctx.logical_device.v, ctx.auxillary_cmd_pool.pool, null);
                ctx.vki.destroySurfaceKHR(ctx.instance.v, ctx.surface.v, null);
                ctx.vkd.destroyDevice(ctx.logical_device.v, null);

                if (consts.enable_validation_layers) {
                    // TODO: only use runtime when getComponent return optional
                    const messenger = message_storage.getComponent(ctx.entity, components.DebugUtilsMessenger) catch unreachable;
                    ctx.vki.destroyDebugUtilsMessengerEXT(ctx.instance.v, messenger.v, null);
                }
                ctx.vki.destroyInstance(ctx.instance.v, null);
            }
        };
    };
}

/// Create the context entity.
pub fn createContextEntity(
    comptime Storage: type,
    storage: *Storage,
    allocator: Allocator,
    application_name: []const u8,
    window: *zglfw.Window,
) !ecez.Entity {
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
    const queue_indices = try createQueueFamilyIndices(vki, physical_device, surface);

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

    const auxillary_cmd_pool = init_cmd_pool: {
        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{ .transient_bit = true },
            .queue_family_index = queue_indices.graphics,
        };
        const cmd_pool = try vkd.createCommandPool(logical_device, &pool_info, null);
        break :init_cmd_pool components.AuxillaryCommandPool{
            .pool = cmd_pool,
        };
    };
    errdefer vkd.destroyCommandPool(logical_device, auxillary_cmd_pool.pool, null);

    return storage.createEntity(.{
        vkb,
        vki,
        vkd,
        components.Instance{ .v = instance },
        components.PhysicalDevice{ .v = physical_device },
        components.Device{ .v = logical_device },
        components.ComputeQueue{ .queue = compute_queue },
        components.GraphicsQueue{ .queue = graphics_queue },
        properties.properties,
        host_image_properties,
        components.Surface{ .v = surface },
        queue_indices,
        components.DebugUtilsMessenger{ .v = messenger },
        auxillary_cmd_pool,
        components.WindowPtr{ .ptr = window },
    });
}

/// caller must destroy pipeline from vulkan
pub inline fn createGraphicsPipeline(vkd: components.vk_dispatch.Device, logical_device: components.Device, create_info: vk.GraphicsPipelineCreateInfo) !vk.Pipeline {
    var pipeline: vk.Pipeline = undefined;
    const result = try vkd.createGraphicsPipelines(
        logical_device,
        .null_handle,
        1,
        @ptrCast(&create_info),
        null,
        @ptrCast(&pipeline),
    );
    if (result != vk.Result.success) {
        return error{FailedToCreatePipeline};
    }
    return pipeline;
}

/// caller must both destroy pipeline from the heap and in vulkan
pub fn createComputePipeline(vkd: components.vk_dispatch.Device, logical_device: components.Device, create_info: vk.ComputePipelineCreateInfo) !vk.Pipeline {
    var pipeline: vk.Pipeline = undefined;
    const result = try vkd.createComputePipelines(
        logical_device.v,
        .null_handle,
        1,
        @ptrCast(&create_info),
        null,
        @ptrCast(&pipeline),
    );
    if (result != vk.Result.success) {
        return error.FailedToCreatePipeline;
    }

    return pipeline;
}

/// caller must destroy returned render pass
pub fn createRenderPass(vkd: components.vk_dispatch.Device, logical_device: components.Device, format: vk.Format) !vk.RenderPass {
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
    return try vkd.createRenderPass(logical_device.v, &render_pass_info, null);
}

// TODO: should not be in context ...
pub fn hasCopySrcLayout(host_image_properties: components.PhysicalDeviceHostImageCopyProperties, src_layout: vk.ImageLayout) bool {
    if (host_image_properties.p_copy_src_layouts) |copy_src_layouts| {
        const copy_src_layout_count = host_image_properties.copy_src_layout_count;
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
