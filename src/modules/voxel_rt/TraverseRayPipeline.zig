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

const ray_pipeline_types = @import("ray_pipeline_types.zig");
const Dispatch1D = ray_pipeline_types.Dispatch1D;
const BrickGridState = ray_pipeline_types.BrickGridState;

const RayDeviceResources = @import("RayDeviceResources.zig");
const DeviceOnlyResources = RayDeviceResources.DeviceOnlyResources;
const Resource = RayDeviceResources.Resource;

// TODO: refactor command buffer should only be recorded on init and when rescaling!

// ping pong resources
const device_resources = [2][7]DeviceOnlyResources{
    .{
        .ray_pipeline_limits,
        // incoming data
        .ray_0,
        .ray_shading_0,
        // outgoing data
        .ray_1,
        .ray_hit_1,
        .ray_shading_1,
        // readonly brick data
        .bricks_set,
    },
    .{
        .ray_pipeline_limits,
        // incoming data
        .ray_1,
        .ray_shading_1,
        // outgoing data
        .ray_0,
        .ray_hit_0,
        .ray_shading_0,
        // readonly brick data
        .bricks_set,
    },
};
const resources = [2][7]Resource{
    Resource.fromArray(DeviceOnlyResources, &device_resources[0]),
    Resource.fromArray(DeviceOnlyResources, &device_resources[1]),
};

/// compute shader that draws to a target texture
const TraverseRayPipeline = @This();

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

work_group_dim: Dispatch1D,

ray_device_resources: *const RayDeviceResources,

// TODO: descriptor has a lot of duplicate code with init ...
// TODO: refactor descriptor sets to share logic between ray pipelines
// TODO: correctness if init fail, clean up resources created with errdefer

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(ctx: Context, ray_device_resources: *const RayDeviceResources) !TraverseRayPipeline {
    const zone = tracy.ZoneN(@src(), @typeName(TraverseRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    // TODO: change based on NVIDIA vs AMD vs Others?
    const work_group_dim = Dispatch1D.init(ctx);

    const target_descriptor_layouts = ray_device_resources.getDescriptorSetLayouts(&resources[0]);
    const pipeline_layout = blk: {
        const push_constant_range = [_]vk.PushConstantRange{.{
            .stage_flags = .{ .compute_bit = true },
            .offset = 0,
            .size = @sizeOf(BrickGridState),
        }};
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = target_descriptor_layouts.len,
            .p_set_layouts = &target_descriptor_layouts,
            .push_constant_range_count = push_constant_range.len,
            .p_push_constant_ranges = &push_constant_range,
        };
        break :blk try ctx.createPipelineLayout(pipeline_layout_info);
    };
    const pipeline = blk: {
        const spec_map = [_]vk.SpecializationMapEntry{.{
            .constant_id = 0,
            .offset = @offsetOf(Dispatch1D, "x"),
            .size = @sizeOf(c_uint),
        }};
        const specialization = vk.SpecializationInfo{
            .map_entry_count = spec_map.len,
            .p_map_entries = &spec_map,
            .data_size = @sizeOf(Dispatch1D),
            .p_data = @as(*const anyopaque, @ptrCast(&work_group_dim)),
        };
        const module_create_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .p_code = @as([*]const u32, @ptrCast(&shaders.traverse_rays_spv)),
            .code_size = shaders.traverse_rays_spv.len,
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

    return TraverseRayPipeline{
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .ray_device_resources = ray_device_resources,
        .work_group_dim = work_group_dim,
    };
}

pub fn deinit(self: TraverseRayPipeline, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(TraverseRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyPipeline(self.pipeline);
}

pub fn appendPipelineCommands(self: TraverseRayPipeline, ctx: Context, bounce_index: u32, command_buffer: vk.CommandBuffer) void {
    const zone = tracy.ZoneN(@src(), @typeName(TraverseRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (render.consts.enable_validation_layers) {
        const label_info = vk.DebugUtilsLabelEXT{
            .p_label_name = @typeName(TraverseRayPipeline) ++ " " ++ @src().fn_name,
            .color = [_]f32{ 0.4, 0.2, 0.2, 0.5 },
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
    // TODO: specify read only vs write only buffer elements (maybe actually loop buffer infos ?)
    const brick_buffer_memory_barrier = vk.BufferMemoryBarrier{
        .src_access_mask = .{ .shader_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .buffer = self.ray_device_resources.voxel_scene_buffer.buffer,
        .offset = 0,
        .size = vk.WHOLE_SIZE,
    };
    const frame_mem_barriers = [_]vk.BufferMemoryBarrier{ ray_buffer_memory_barrier, brick_buffer_memory_barrier };
    ctx.vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .compute_shader_bit = true },
        .{ .compute_shader_bit = true },
        .{},
        0,
        undefined,
        frame_mem_barriers.len,
        &frame_mem_barriers,
        0,
        undefined,
    );

    ctx.vkd.cmdPushConstants(
        command_buffer,
        self.pipeline_layout,
        .{ .compute_bit = true },
        0,
        @sizeOf(BrickGridState),
        self.ray_device_resources.brick_grid_state,
    );
    ctx.vkd.cmdBindPipeline(command_buffer, vk.PipelineBindPoint.compute, self.pipeline);

    const resource_index = @rem(bounce_index, 2);
    const descriptor_sets = get_desc_set_blk: {
        if (resource_index == 0) {
            break :get_desc_set_blk self.ray_device_resources.getDescriptorSets(&resources[0]);
        } else {
            break :get_desc_set_blk self.ray_device_resources.getDescriptorSets(&resources[1]);
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
