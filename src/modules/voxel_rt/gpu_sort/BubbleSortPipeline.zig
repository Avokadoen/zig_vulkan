const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const glfw = @import("mach-glfw");
const tracy = @import("ztracy");

const shaders = @import("shaders");

const render = @import("../../render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;
const StagingRamp = render.StagingRamp;

const Camera = @import("../Camera.zig");

const ray_types = @import("../ray_pipeline_types.zig");
const Dispatch1D = ray_types.Dispatch1D;

const RayDeviceResources = @import("../RayDeviceResources.zig");
const Resources = RayDeviceResources.Resources;
// TODO: refactor command buffer should only be recorded on init and when rescaling!

/// compute shader that calculate miss color
const BubbleSortPipeline = @This();

const device_resources = [_]Resources{
    .ray_pipeline_limits,
    .ray,
    .ray_hit,
    .ray_active,
    .ray_shading,
    .bricks_set,
};

allocator: Allocator,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

work_group_dim: Dispatch1D,

ray_device_resources: RayDeviceResources,
descriptor_set_view: [device_resources.len]vk.DescriptorSet,
submit_wait_stage: [1]vk.PipelineStageFlags = .{.{ .compute_shader_bit = true }},

// TODO: share descriptors across ray pipelines (use vk descriptor buffers!)
// TODO: descriptor has a lot of duplicate code with init ...
// TODO: correctness if init fail, clean up resources created with errdefer

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(
    allocator: Allocator,
    ctx: Context,
    image_size: vk.Extent2D,
    ray_buffer: *const GpuBufferMemory,
    bubble_descriptor_info: [2]vk.DescriptorBufferInfo,
) !BubbleSortPipeline {
    const zone = tracy.ZoneN(@src(), @typeName(BubbleSortPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    // TODO: change based on NVIDIA vs AMD vs Others?
    const work_group_dim = Dispatch1D.init(ctx);

    const target_descriptor_layout = blk: {
        comptime var layout_bindings: [bubble_descriptor_info.len]vk.DescriptorSetLayoutBinding = undefined;
        inline for (&layout_bindings, 0..) |*binding, index| {
            binding.* = vk.DescriptorSetLayoutBinding{
                .binding = index,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            };
        }
        const layout_info = vk.DescriptorSetLayoutCreateInfo{
            .flags = .{},
            .binding_count = layout_bindings.len,
            .p_bindings = &layout_bindings,
        };
        break :blk try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &layout_info, null);
    };
    errdefer ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, target_descriptor_layout, null);

    const target_descriptor_pool = blk: {
        const pool_sizes = [_]vk.DescriptorPoolSize{.{
            .type = .storage_image,
            .descriptor_count = bubble_descriptor_info.len,
        }};
        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = 1,
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
        };
        break :blk try ctx.vkd.createDescriptorPool(ctx.logical_device, &pool_info, null);
    };
    errdefer ctx.vkd.destroyDescriptorPool(ctx.logical_device, target_descriptor_pool, null);

    var target_descriptor_set: vk.DescriptorSet = undefined;
    {
        const descriptor_set_alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = target_descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @as([*]const vk.DescriptorSetLayout, @ptrCast(&target_descriptor_layout)),
        };
        try ctx.vkd.allocateDescriptorSets(ctx.logical_device, &descriptor_set_alloc_info, @as([*]vk.DescriptorSet, @ptrCast(&target_descriptor_set)));
    }

    {
        var write_descriptor_set: [bubble_descriptor_info.len]vk.WriteDescriptorSet = undefined;
        for (&write_descriptor_set, 0..) |*write_desc, index| {
            write_desc.* = .{
                .dst_set = target_descriptor_set,
                .dst_binding = @as(u32, @intCast(index)),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @as([*]const vk.DescriptorBufferInfo, @ptrCast(&bubble_descriptor_info[index])),
                .p_texel_buffer_view = undefined,
            };
        }

        ctx.vkd.updateDescriptorSets(
            ctx.logical_device,
            write_descriptor_set.len,
            &write_descriptor_set,
            0,
            undefined,
        );
    }

    const pipeline_layout = blk: {
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @as([*]const vk.DescriptorSetLayout, @ptrCast(&target_descriptor_layout)),
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
            .p_code = @as([*]const u32, @ptrCast(&shaders.hit_is_active_bubble_sort)),
            .code_size = shaders.hit_is_active_bubble_sort.len,
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

    return BubbleSortPipeline{
        .allocator = allocator,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .target_descriptor_layout = target_descriptor_layout,
        .target_descriptor_pool = target_descriptor_pool,
        .target_descriptor_set = target_descriptor_set,
        .image_size = image_size,
        .ray_buffer = ray_buffer,
        .work_group_dim = work_group_dim,
    };
}

pub fn deinit(self: BubbleSortPipeline, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(BubbleSortPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.target_descriptor_layout, null);
    ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyPipeline(self.pipeline);
}

// TODO: static command buffer (only record once)
pub fn appendPipelineCommands(self: BubbleSortPipeline, ctx: Context, command_buffer: vk.CommandBuffer) void {
    const zone = tracy.ZoneN(@src(), @typeName(BubbleSortPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (render.consts.enable_validation_layers) {
        const label_info = vk.DebugUtilsLabelEXT{
            .p_label_name = @typeName(BubbleSortPipeline) ++ " " ++ @src().fn_name,
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
        .buffer = self.ray_buffer.buffer,
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

    const x_dispatch = @ceil(@as(f32, @floatFromInt((self.image_size.width * self.image_size.height) / 2)) /
        @as(f32, @floatFromInt(self.work_group_dim.x))) + 1;

    ctx.vkd.cmdDispatch(command_buffer, @intFromFloat(x_dispatch), 1, 1);
}

test "bubble sort produce correct result" {
    return error.Unimplemented;
}
