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
const BrickGridMetadata = ray_pipeline_types.BrickGridMetadata;

const RayDeviceResources = @import("RayDeviceResources.zig");
const DeviceOnlyResources = RayDeviceResources.DeviceOnlyResources;
const HostAndDeviceResources = RayDeviceResources.HostAndDeviceResources;
const Resource = RayDeviceResources.Resource;

const resources = [_]Resource{
    Resource.from(DeviceOnlyResources.bricks_set_s),
    Resource.from(HostAndDeviceResources.brick_req_limits_s),
    Resource.from(HostAndDeviceResources.brick_load_request_s),
    Resource.from(HostAndDeviceResources.brick_unload_request_s),
};

const BrickHeartbeatPipeline = @This();

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

work_group_dim: Dispatch1D,

ray_device_resources: *const RayDeviceResources,

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(ctx: Context, ray_device_resources: *const RayDeviceResources) !BrickHeartbeatPipeline {
    const zone = tracy.ZoneN(@src(), @typeName(BrickHeartbeatPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    // TODO: change based on NVIDIA vs AMD vs Others?
    const work_group_dim = Dispatch1D.init(ctx);

    const target_descriptor_layouts = ray_device_resources.getDescriptorSetLayouts(&resources);
    const pipeline_layout = blk: {
        const push_constant_range = [_]vk.PushConstantRange{.{
            .stage_flags = .{ .compute_bit = true },
            .offset = 0,
            .size = @sizeOf(BrickGridMetadata),
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
            .p_code = @as([*]const u32, @ptrCast(&shaders.brick_heartbeat_spv)),
            .code_size = shaders.brick_heartbeat_spv.len,
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

    return BrickHeartbeatPipeline{
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .ray_device_resources = ray_device_resources,
        .work_group_dim = work_group_dim,
    };
}

pub fn deinit(self: BrickHeartbeatPipeline, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(BrickHeartbeatPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyPipeline(self.pipeline);
}

pub fn appendPipelineCommands(self: BrickHeartbeatPipeline, ctx: Context, command_buffer: vk.CommandBuffer) void {
    const zone = tracy.ZoneN(@src(), @typeName(BrickHeartbeatPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (render.consts.enable_validation_layers) {
        const label_info = vk.DebugUtilsLabelEXT{
            .p_label_name = @typeName(BrickHeartbeatPipeline) ++ " " ++ @src().fn_name,
            .color = [_]f32{ 0.4, 0.2, 0.2, 0.5 },
        };
        ctx.vkd.cmdBeginDebugUtilsLabelEXT(command_buffer, &label_info);
    }
    defer {
        if (render.consts.enable_validation_layers) {
            ctx.vkd.cmdEndDebugUtilsLabelEXT(command_buffer);
        }
    }

    self.ray_device_resources.resetBrickReqLimits(ctx, command_buffer);

    const brick_buffer_memory_barrier = [_]vk.BufferMemoryBarrier{.{
        .src_access_mask = .{ .shader_read_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .buffer = self.ray_device_resources.voxel_scene_buffer.buffer,
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
        brick_buffer_memory_barrier.len,
        &brick_buffer_memory_barrier,
        0,
        undefined,
    );

    {
        // reduce brick dimensions to brick count
        const grid_brick_dim = self.ray_device_resources.host_brick_state.grid_metadata.dim;
        const total_brick_count: c_uint = @intFromFloat(grid_brick_dim[0] * grid_brick_dim[1] * grid_brick_dim[2]);
        ctx.vkd.cmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            .{ .compute_bit = true },
            0,
            @sizeOf(c_int),
            &total_brick_count,
        );
    }
    ctx.vkd.cmdBindPipeline(command_buffer, vk.PipelineBindPoint.compute, self.pipeline);

    const descriptor_sets = self.ray_device_resources.getDescriptorSets(&resources);
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

    self.ray_device_resources.resetBrickReqLimitsBarrier(ctx, command_buffer);

    const x_dispatch = self.ray_device_resources.rayDispatch1D(self.work_group_dim);
    ctx.vkd.cmdDispatch(command_buffer, x_dispatch, 1, 1);
}
