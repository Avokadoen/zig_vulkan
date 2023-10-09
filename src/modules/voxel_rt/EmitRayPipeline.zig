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

const Camera = @import("Camera.zig");

const ray_types = @import("ray_pipeline_types.zig");
const RayHitLimits = ray_types.RayHitLimits;
const Ray = ray_types.Ray;
const Dispatch1D = ray_types.Dispatch1D;

const RayDeviceResources = @import("RayDeviceResources.zig");
const Resources = RayDeviceResources.Resources;

const device_resources = [_]Resources{
    .ray_pipeline_limits,
    .ray,
    .ray_hit,
    .ray_shading,
};

// TODO: refactor command buffer should only be recorded on init and when rescaling!

/// compute shader that draws to a target texture
const EmitRayPipeline = @This();

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

ray_device_resources: *const RayDeviceResources,
descriptor_sets_view: [device_resources.len]vk.DescriptorSet,

work_group_dim: Dispatch1D,

// TODO: descriptor has a lot of duplicate code with init ...
// TODO: correctness if init fail, clean up resources created with errdefer

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(ctx: Context, ray_device_resources: *const RayDeviceResources) !EmitRayPipeline {
    const zone = tracy.ZoneN(@src(), @typeName(EmitRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    const work_group_dim = Dispatch1D.init(ctx);

    const descriptr_set_layouts = ray_device_resources.getDescriptorSetLayouts(&device_resources);
    const pipeline_layout = blk: {
        const push_constant_ranges = [_]vk.PushConstantRange{.{
            .stage_flags = .{ .compute_bit = true },
            .offset = 0,
            // TODO: dont need Camera.Device, only need a subset
            .size = @sizeOf(Camera.Device),
        }};
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = descriptr_set_layouts.len,
            .p_set_layouts = &descriptr_set_layouts,
            .push_constant_range_count = push_constant_ranges.len,
            .p_push_constant_ranges = &push_constant_ranges,
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
            .p_code = @as([*]const u32, @ptrCast(&shaders.emit_primary_rays_spv)),
            .code_size = shaders.emit_primary_rays_spv.len,
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

    return EmitRayPipeline{
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .ray_device_resources = ray_device_resources,
        .descriptor_sets_view = ray_device_resources.getDescriptorSets(&device_resources),
        .work_group_dim = work_group_dim,
    };
}

pub fn deinit(self: EmitRayPipeline, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(EmitRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyPipeline(self.pipeline);
}

// TODO: static command buffer (only record once)
pub fn appendPipelineCommands(
    self: EmitRayPipeline,
    ctx: Context,
    camera: Camera,
    command_buffer: vk.CommandBuffer,
) void {
    const zone = tracy.ZoneN(@src(), @typeName(EmitRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (render.consts.enable_validation_layers) {
        const label_info = vk.DebugUtilsLabelEXT{
            .p_label_name = @typeName(EmitRayPipeline) ++ " " ++ @src().fn_name,
            .color = [_]f32{ 0.3, 0.3, 0.6, 0.5 },
        };
        ctx.vkd.cmdBeginDebugUtilsLabelEXT(command_buffer, &label_info);
    }
    defer {
        if (render.consts.enable_validation_layers) {
            ctx.vkd.cmdEndDebugUtilsLabelEXT(command_buffer);
        }
    }

    ctx.vkd.cmdBindPipeline(command_buffer, vk.PipelineBindPoint.compute, self.pipeline);

    // push camera data as a push constant
    ctx.vkd.cmdPushConstants(
        command_buffer,
        self.pipeline_layout,
        .{ .compute_bit = true },
        0,
        @sizeOf(Camera.Device),
        &camera.d_camera,
    );

    // bind target texture
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

    // zero out limit values
    ctx.vkd.cmdFillBuffer(
        command_buffer,
        self.ray_device_resources.ray_buffer.buffer,
        0, // offset
        @sizeOf(RayHitLimits),
        0, // value
    );
    const buffer_memory_barrier = vk.BufferMemoryBarrier{
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .buffer = self.ray_device_resources.ray_buffer.buffer,
        .offset = 0,
        .size = @sizeOf(RayHitLimits),
    };
    ctx.vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .transfer_bit = true },
        .{ .compute_shader_bit = true },
        .{},
        0,
        undefined,
        1,
        @as([*]const vk.BufferMemoryBarrier, @ptrCast(&buffer_memory_barrier)),
        0,
        undefined,
    );

    const x_dispatch = @ceil(self.ray_device_resources.target_image_info.width * self.ray_device_resources.target_image_info.height /
        @as(f32, @floatFromInt(self.work_group_dim.x))) + 1;

    ctx.vkd.cmdDispatch(command_buffer, @intFromFloat(x_dispatch), 1, 1);
}
