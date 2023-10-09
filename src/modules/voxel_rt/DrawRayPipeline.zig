const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const glfw = @import("mach-glfw");
const tracy = @import("ztracy");

const shaders = @import("shaders");

const render = @import("../render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;
const StagingRamp = render.StagingRamp;

const ray_types = @import("ray_pipeline_types.zig");
const Dispatch1D = ray_types.Dispatch1D;

const RayDeviceResources = @import("RayDeviceResources.zig");
const Resources = RayDeviceResources.Resources;
// TODO: refactor command buffer should only be recorded on init and when rescaling!

const device_resources = [_]Resources{
    .draw_image,
    .ray_pipeline_limits,
    .ray_shading,
};

/// compute shader that draws to a target texture
const DrawRayPipeline = @This();

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

ray_device_resources: *const RayDeviceResources,
descriptor_sets_view: [device_resources.len]vk.DescriptorSet,

work_group_dim: Dispatch1D,

// TODO: share descriptors across ray pipelines (use vk descriptor buffers!)
// TODO: descriptor has a lot of duplicate code with init ...
// TODO: correctness if init fail, clean up resources created with errdefer

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(ctx: Context, ray_device_resources: *const RayDeviceResources) !DrawRayPipeline {
    const zone = tracy.ZoneN(@src(), @typeName(DrawRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    const work_group_dim = Dispatch1D.init(ctx);

    const descriptor_layout = ray_device_resources.getDescriptorSetLayouts(&device_resources);
    const pipeline_layout = blk: {
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = descriptor_layout.len,
            .p_set_layouts = &descriptor_layout,
            .push_constant_range_count = 0,
            .p_push_constant_ranges = undefined,
        };
        break :blk try ctx.createPipelineLayout(pipeline_layout_info);
    };
    const pipeline = blk: {
        const spec_map = [_]vk.SpecializationMapEntry{
            .{
                .constant_id = 0,
                .offset = @offsetOf(Dispatch1D, "x"),
                .size = @sizeOf(c_uint),
            },
        };
        const specialization = vk.SpecializationInfo{
            .map_entry_count = spec_map.len,
            .p_map_entries = &spec_map,
            .data_size = @sizeOf(Dispatch1D),
            .p_data = @as(*const anyopaque, @ptrCast(&work_group_dim)),
        };
        const module_create_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .p_code = @as([*]const u32, @ptrCast(&shaders.draw_rays_spv)),
            .code_size = shaders.draw_rays_spv.len,
        };
        const module = try ctx.vkd.createShaderModule(ctx.logical_device, &module_create_info, null);

        const stage = vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = .{ .compute_bit = true },
            .module = module,
            .p_name = "main",
            .p_specialization_info = @as(?*const vk.SpecializationInfo, @ptrCast(&specialization)),
        };
        defer ctx.destroyShaderModule(stage.module);

        // TOOD: read on defer_compile_bit_nv
        const pipeline_info = vk.ComputePipelineCreateInfo{
            .flags = .{},
            .stage = stage,
            .layout = pipeline_layout,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };
        break :blk try ctx.createComputePipeline(pipeline_info);
    };
    errdefer ctx.destroyPipeline(pipeline);

    return DrawRayPipeline{
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .ray_device_resources = ray_device_resources,
        .descriptor_sets_view = ray_device_resources.getDescriptorSets(&device_resources),
        .work_group_dim = work_group_dim,
    };
}

pub fn deinit(self: DrawRayPipeline, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(DrawRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyPipeline(self.pipeline);
}

// TODO: static command buffer (only record once)
pub fn appendPipelineCommands(
    self: DrawRayPipeline,
    ctx: Context,
    command_buffer: vk.CommandBuffer,
) void {
    const zone = tracy.ZoneN(@src(), @typeName(DrawRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (render.consts.enable_validation_layers) {
        const label_info = vk.DebugUtilsLabelEXT{
            .p_label_name = @typeName(DrawRayPipeline) ++ " " ++ @src().fn_name,
            .color = [_]f32{ 0.5, 0.3, 0.3, 0.5 },
        };
        ctx.vkd.cmdBeginDebugUtilsLabelEXT(command_buffer, &label_info);
    }
    defer {
        if (render.consts.enable_validation_layers) {
            ctx.vkd.cmdEndDebugUtilsLabelEXT(command_buffer);
        }
    }

    // TODO: specify read only vs write only buffer elements (maybe actually loop buffer infos ?)
    const ray_buffer_memory_barrier = [_]vk.BufferMemoryBarrier{.{
        .src_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .buffer = self.ray_device_resources.ray_buffer.buffer,
        .offset = 0,
        .size = vk.WHOLE_SIZE,
    }};
    ctx.vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .compute_shader_bit = true },
        .{ .compute_shader_bit = true },
        .{},
        0,
        undefined,
        ray_buffer_memory_barrier.len,
        &ray_buffer_memory_barrier,
        0,
        undefined,
    );

    ctx.vkd.cmdBindPipeline(command_buffer, vk.PipelineBindPoint.compute, self.pipeline);

    ctx.vkd.cmdBindDescriptorSets(
        command_buffer,
        .compute,
        self.pipeline_layout,
        0,
        self.descriptor_sets_view.len,
        &self.descriptor_sets_view,
        0,
        undefined,
    );

    const image_barrier = vk.ImageMemoryBarrier{
        .src_access_mask = .{ .shader_read_bit = true },
        .dst_access_mask = .{ .shader_write_bit = true },
        .old_layout = .shader_read_only_optimal,
        .new_layout = .general,
        .src_queue_family_index = ctx.queue_indices.graphics,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .image = self.ray_device_resources.target_image_info.image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    ctx.vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .fragment_shader_bit = true },
        .{ .compute_shader_bit = true },
        .{},
        0,
        undefined,
        0,
        undefined,
        1,
        @as([*]const vk.ImageMemoryBarrier, @ptrCast(&image_barrier)),
    );

    const x_dispatch = @ceil(self.ray_device_resources.target_image_info.width * self.ray_device_resources.target_image_info.width) /
        @as(f32, @floatFromInt(self.work_group_dim.x)) + 1;

    ctx.vkd.cmdDispatch(command_buffer, @as(u32, @intFromFloat(x_dispatch)), 1, 1);
}
