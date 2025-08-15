/// vk_utils contains utility functions for the vulkan API to reduce boiler plate

// TODO: most of these functions are only called once in the codebase, move to where they are
// relevant, and those who are only called in one file should be in that file

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecez = @import("ecez");
const vk = @import("vulkan");

const context = @import("context.zig");
const dispatch = @import("dispatch.zig");

pub const components = struct {
    pub const PipelineLayout = vk.PipelineLayout;
    pub const Pipeline = vk.Pipeline;
};

pub const queries = struct {
    pub const PipelineLayout = ecez.Query(struct {
        l: components.PipelineLayout,
    }, .{}, .{});

    pub const Pipeline = ecez.Query(struct {
        p: components.Pipeline,
    }, .{}, .{});
};

pub const systems = struct {
    pub const deinit = struct {
        pub fn destroyPipelineLayouts(ctx_query: *context.queries.VkdAndDevice, pipeline_layout_query: *queries.PipelineLayout) void {
            const ctx = ctx_query.getAny().?;
            while (pipeline_layout_query.next()) |pipeline_layout| {
                ctx.vkd.destroyPipelineLayout(ctx.logical_device.v, pipeline_layout.l, null);
            }
        }

        pub fn destroyPipeline(ctx_query: *context.queries.VkdAndDevice, pipeline_query: *queries.Pipeline) void {
            const ctx = ctx_query.getAny().?;
            while (pipeline_query.next()) |pipeline| {
                ctx.vkd.destroyPipeline(ctx.logical_device.v, pipeline.p, null);
            }
        }
    };
};

/// Check if extensions are available on host instance
pub fn isInstanceExtensionsPresent(allocator: Allocator, vkb: dispatch.Base, target_extensions: []const [*:0]const u8) !bool {
    // query extensions available
    var supported_extensions_count: u32 = 0;
    // TODO: handle "VkResult.incomplete"
    _ = try vkb.enumerateInstanceExtensionProperties(null, &supported_extensions_count, null);

    var extensions = try std.ArrayList(vk.ExtensionProperties).initCapacity(allocator, supported_extensions_count);
    defer extensions.deinit();

    _ = try vkb.enumerateInstanceExtensionProperties(null, &supported_extensions_count, extensions.items.ptr);
    extensions.items.len = supported_extensions_count;

    var matches: u32 = 0;
    for (target_extensions) |target_extension| {
        const t_str_len = std.mem.indexOfScalar(u8, target_extension[0..vk.MAX_EXTENSION_NAME_SIZE], 0) orelse continue;
        cmp: for (extensions.items) |existing| {
            const existing_name: [*:0]const u8 = @ptrCast(&existing.extension_name);
            const e_str_len = std.mem.indexOfScalar(u8, existing_name[0..vk.MAX_EXTENSION_NAME_SIZE], 0) orelse continue;
            if (std.mem.eql(u8, target_extension[0..t_str_len], existing_name[0..e_str_len])) {
                matches += 1;
                break :cmp;
            }
        }
    }

    return matches == target_extensions.len;
}

pub fn findMemoryTypeIndex(
    vki: context.components.vk_dispatch.Instance,
    physical_device: context.components.PhysicalDevice,
    type_filter: u32,
    memory_flags: vk.MemoryPropertyFlags,
) error{NotFound}!u32 {
    const properties = vki.getPhysicalDeviceMemoryProperties(physical_device.v);
    for (0..properties.memory_type_count) |i| {
        const left_shift: u5 = @intCast(i);
        const correct_type: bool = (type_filter & (@as(u32, 1) << left_shift)) != 0;
        if (correct_type and properties.memory_types[i].property_flags.contains(memory_flags)) {
            return @intCast(i);
        }
    }

    return error.NotFound;
}

pub fn beginOneTimeCommandBuffer(
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.Device,
    command_pool: vk.CommandPool,
) !vk.CommandBuffer {
    const allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    var command_buffer: vk.CommandBuffer = undefined;
    try vkd.allocateCommandBuffers(logical_device.v, &allocate_info, @ptrCast(&command_buffer));

    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{
            .one_time_submit_bit = true,
        },
        .p_inheritance_info = null,
    };
    try vkd.beginCommandBuffer(command_buffer, &begin_info);

    return command_buffer;
}

// TODO: synchronization should be improved in this function (currently very sub optimal)!
pub inline fn endOneTimeCommandBuffer(
    vkd: context.components.vk_dispatch.Device,
    logical_device: context.components.Device,
    graphics_queue: context.components.GraphicsQueue,
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
) !void {
    try vkd.endCommandBuffer(command_buffer);

    {
        @setRuntimeSafety(false);
        const semo_null_ptr: [*c]const vk.Semaphore = null;
        const wait_null_ptr: [*c]const vk.PipelineStageFlags = null;
        // perform the compute ray tracing, draw to target texture
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = semo_null_ptr,
            .p_wait_dst_stage_mask = wait_null_ptr,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = semo_null_ptr,
        };
        try vkd.queueSubmit(graphics_queue.queue, 1, @ptrCast(&submit_info), .null_handle);
    }

    try vkd.queueWaitIdle(graphics_queue.queue);

    vkd.freeCommandBuffers(logical_device.v, command_pool, 1, @ptrCast(&command_buffer));
}
