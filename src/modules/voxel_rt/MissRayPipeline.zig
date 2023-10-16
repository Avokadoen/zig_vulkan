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

// ping pong resources
const device_resources = [2][3]Resources{
    .{
        .ray_pipeline_limits,
        .ray_1,
        .ray_shading_1,
    },
    .{
        .ray_pipeline_limits,
        .ray_0,
        .ray_shading_0,
    },
};

/// compute shader that calculate miss color
const MissRayPipeline = @This();

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

work_group_dim: Dispatch1D,

ray_device_resources: *const RayDeviceResources,
submit_wait_stage: [1]vk.PipelineStageFlags = .{.{ .compute_shader_bit = true }},

// TODO: share descriptors across ray pipelines (use vk descriptor buffers!)
// TODO: descriptor has a lot of duplicate code with init ...
// TODO: correctness if init fail, clean up resources created with errdefer

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(ctx: Context, ray_device_resources: *const RayDeviceResources) !MissRayPipeline {
    const zone = tracy.ZoneN(@src(), @typeName(MissRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    // TODO: change based on NVIDIA vs AMD vs Others?
    const work_group_dim = Dispatch1D.init(ctx);

    const target_descriptor_layouts = ray_device_resources.getDescriptorSetLayouts(&device_resources[0]);
    const pipeline_layout = blk: {
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = target_descriptor_layouts.len,
            .p_set_layouts = &target_descriptor_layouts,
            .push_constant_range_count = 0,
            .p_push_constant_ranges = undefined,
        };
        break :blk try ctx.createPipelineLayout(pipeline_layout_info);
    };
    const pipeline = blk: {
        const spec_map = [_]vk.SpecializationMapEntry{.{
            .constant_id = 0,
            .offset = @offsetOf(Dispatch1D, "x"),
            .size = @sizeOf(u32),
        }};
        const specialization = vk.SpecializationInfo{
            .map_entry_count = spec_map.len,
            .p_map_entries = &spec_map,
            .data_size = @sizeOf(Dispatch1D),
            .p_data = @as(*const anyopaque, @ptrCast(&work_group_dim)),
        };
        const module_create_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .p_code = @as([*]const u32, @ptrCast(&shaders.miss_rays_spv)),
            .code_size = shaders.miss_rays_spv.len,
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

    return MissRayPipeline{
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .work_group_dim = work_group_dim,
        .ray_device_resources = ray_device_resources,
    };
}

pub fn deinit(self: MissRayPipeline, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(MissRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyPipeline(self.pipeline);
}

// TODO: static command buffer (only record once)
pub fn appendPipelineCommands(
    self: MissRayPipeline,
    ctx: Context,
    bounce_index: u32,
    command_buffer: vk.CommandBuffer,
) void {
    const zone = tracy.ZoneN(@src(), @typeName(MissRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (render.consts.enable_validation_layers) {
        const label_info = vk.DebugUtilsLabelEXT{
            .p_label_name = @typeName(MissRayPipeline) ++ " " ++ @src().fn_name,
            .color = [_]f32{ 0.2, 0.2, 0.4, 0.5 },
        };
        ctx.vkd.cmdBeginDebugUtilsLabelEXT(command_buffer, &label_info);
    }
    defer {
        if (render.consts.enable_validation_layers) {
            ctx.vkd.cmdEndDebugUtilsLabelEXT(command_buffer);
        }
    }

    // TODO: specify read only vs write only buffer elements (maybe actually loop buffer infos ?)
    const ray_buffer_memory_barrier = vk.BufferMemoryBarrier{
        .src_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .buffer = self.ray_device_resources.ray_buffer.buffer,
        .offset = 0,
        .size = vk.WHOLE_SIZE,
    };
    const mem_barriers = [_]vk.BufferMemoryBarrier{ray_buffer_memory_barrier};
    ctx.vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .compute_shader_bit = true },
        .{ .compute_shader_bit = true },
        .{},
        0,
        undefined,
        mem_barriers.len,
        &mem_barriers,
        0,
        undefined,
    );

    ctx.vkd.cmdBindPipeline(command_buffer, vk.PipelineBindPoint.compute, self.pipeline);

    const resource_index = @rem(bounce_index, 2);
    const descriptor_sets = get_desc_set_blk: {
        if (resource_index == 0) {
            break :get_desc_set_blk self.ray_device_resources.getDescriptorSets(&device_resources[0]);
        } else {
            break :get_desc_set_blk self.ray_device_resources.getDescriptorSets(&device_resources[1]);
        }
    };
    ctx.vkd.cmdBindDescriptorSets(
        command_buffer,
        .compute,
        self.pipeline_layout,
        0,
        descriptor_sets.len,
        &descriptor_sets,
        0,
        undefined,
    );

    const x_dispatch = @ceil(self.ray_device_resources.target_image_info.width * self.ray_device_resources.target_image_info.height) /
        @as(f32, @floatFromInt(self.work_group_dim.x)) + 1;

    ctx.vkd.cmdDispatch(command_buffer, @intFromFloat(x_dispatch), 1, 1);
}
