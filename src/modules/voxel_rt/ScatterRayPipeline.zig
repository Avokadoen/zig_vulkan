const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const glfw = @import("glfw");
const tracy = @import("ztracy");

const shaders = @import("shaders");

const render = @import("../render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;
const StagingRamp = render.StagingRamp;

const Camera = @import("Camera.zig");

const ray_types = @import("ray_pipeline_types.zig");
const RayBufferCursor = ray_types.RayBufferCursor;
const Ray = ray_types.Ray;
const Dispatch2 = ray_types.Dispatch2;
const ImageInfo = ray_types.ImageInfo;

// TODO: refactor command buffer should only be recorded on init and when rescaling!

pub const NextStage = enum {
    traverse,
    draw,
};
const next_stages = @as(comptime_int, @enumToInt(NextStage.draw)) + 1;

/// compute shader spawning scattered rays based on hit records
const ScatterRayPipeline = @This();

allocator: Allocator,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

target_descriptor_layout: [next_stages]vk.DescriptorSetLayout,
target_descriptor_pool: vk.DescriptorPool,
target_descriptor_set: [next_stages]vk.DescriptorSet,

image_size: vk.Extent2D,

buffer_infos: [next_stages][4]vk.DescriptorBufferInfo,

ray_buffer: *const GpuBufferMemory,

work_group_dim: Dispatch2,

submit_wait_stage: [1]vk.PipelineStageFlags = .{.{ .compute_shader_bit = true }},

// TODO: share descriptors across ray pipelines (use vk descriptor buffers!)
// TODO: descriptor has a lot of duplicate code with init ...
// TODO: correctness if init fail, clean up resources created with errdefer

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(
    allocator: Allocator,
    ctx: Context,
    ray_buffer: *const GpuBufferMemory,
    image_size: vk.Extent2D,
    scatter_ray_descriptor_info: [next_stages][4]vk.DescriptorBufferInfo,
) !ScatterRayPipeline {
    const zone = tracy.ZoneN(@src(), @typeName(ScatterRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    // TODO: change based on NVIDIA vs AMD vs Others?
    const work_group_dim = Dispatch2.init(ctx);

    const target_descriptor_layout = blk: {
        var descriptor_layout: [next_stages]vk.DescriptorSetLayout = undefined;
        comptime std.debug.assert(next_stages == 2);

        comptime var layout_bindings: [4]vk.DescriptorSetLayoutBinding = undefined;
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
        descriptor_layout[0] = try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &layout_info, null);
        errdefer ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, descriptor_layout[0], null);

        descriptor_layout[1] = try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &layout_info, null);
        errdefer ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, descriptor_layout[1], null);

        break :blk descriptor_layout;
    };
    errdefer {
        for (target_descriptor_layout) |layout| {
            ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, layout, null);
        }
    }

    const target_descriptor_pool = blk: {
        const pool_sizes = [_]vk.DescriptorPoolSize{.{
            .type = .storage_buffer,
            .descriptor_count = 8,
        }};
        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = next_stages,
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
        };
        break :blk try ctx.vkd.createDescriptorPool(ctx.logical_device, &pool_info, null);
    };
    errdefer ctx.vkd.destroyDescriptorPool(ctx.logical_device, target_descriptor_pool, null);

    var target_descriptor_set: [next_stages]vk.DescriptorSet = undefined;
    {
        const descriptor_set_alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = target_descriptor_pool,
            .descriptor_set_count = target_descriptor_set.len,
            .p_set_layouts = &target_descriptor_layout,
        };
        try ctx.vkd.allocateDescriptorSets(ctx.logical_device, &descriptor_set_alloc_info, &target_descriptor_set);
    }

    {
        var write_descriptor_set: [8]vk.WriteDescriptorSet = undefined;
        for (&scatter_ray_descriptor_info[@enumToInt(NextStage.traverse)], 0.., 0..) |*traverse_desc_info, index, binding| {
            write_descriptor_set[index] = .{
                .dst_set = target_descriptor_set[@enumToInt(NextStage.traverse)],
                .dst_binding = @intCast(u32, binding),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, traverse_desc_info),
                .p_texel_buffer_view = undefined,
            };
        }

        for (&scatter_ray_descriptor_info[@enumToInt(NextStage.draw)], 4.., 0..) |*draw_desc_info, index, binding| {
            write_descriptor_set[index] = .{
                .dst_set = target_descriptor_set[@enumToInt(NextStage.draw)],
                .dst_binding = @intCast(u32, binding),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, draw_desc_info),
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
            .set_layout_count = target_descriptor_layout.len,
            .p_set_layouts = &target_descriptor_layout,
            .push_constant_range_count = 0,
            .p_push_constant_ranges = undefined,
        };
        break :blk try ctx.createPipelineLayout(pipeline_layout_info);
    };
    const pipeline = blk: {
        const spec_map = [_]vk.SpecializationMapEntry{ .{
            .constant_id = 0,
            .offset = @offsetOf(Dispatch2, "x"),
            .size = @sizeOf(u32),
        }, .{
            .constant_id = 1,
            .offset = @offsetOf(Dispatch2, "y"),
            .size = @sizeOf(u32),
        } };
        const specialization = vk.SpecializationInfo{
            .map_entry_count = spec_map.len,
            .p_map_entries = &spec_map,
            .data_size = @sizeOf(Dispatch2),
            .p_data = @ptrCast(*const anyopaque, &work_group_dim),
        };
        const module_create_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .p_code = @ptrCast([*]const u32, &shaders.scatter_rays_spv),
            .code_size = shaders.scatter_rays_spv.len,
        };
        const module = try ctx.vkd.createShaderModule(ctx.logical_device, &module_create_info, null);

        const stage = vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = .{ .compute_bit = true },
            .module = module,
            .p_name = "main",
            .p_specialization_info = @ptrCast(?*const vk.SpecializationInfo, &specialization),
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

    return ScatterRayPipeline{
        .allocator = allocator,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .target_descriptor_layout = target_descriptor_layout,
        .target_descriptor_pool = target_descriptor_pool,
        .target_descriptor_set = target_descriptor_set,
        .image_size = image_size,
        .buffer_infos = scatter_ray_descriptor_info,
        .ray_buffer = ray_buffer,
        .work_group_dim = work_group_dim,
    };
}

pub fn deinit(self: ScatterRayPipeline, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(ScatterRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    for (self.target_descriptor_layout) |layout| {
        ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, layout, null);
    }
    ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyPipeline(self.pipeline);
}

pub fn appendPipelineCommands(self: ScatterRayPipeline, ctx: Context, command_buffer: vk.CommandBuffer, comptime next_stage: NextStage) void {
    const zone = tracy.ZoneN(@src(), @typeName(ScatterRayPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (render.consts.enable_validation_layers) {
        const label_info = vk.DebugUtilsLabelEXT{
            .p_label_name = @typeName(ScatterRayPipeline) ++ " " ++ @src().fn_name,
            .color = [_]f32{ 0.2, 0.8, 0.2, 0.5 },
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
        .src_access_mask = .{ .shader_write_bit = true },
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
        1,
        @ptrCast([*]const vk.DescriptorSet, &self.target_descriptor_set[@enumToInt(next_stage)]),
        0,
        undefined,
    );

    // reset the cursor to 0
    ctx.vkd.cmdFillBuffer(
        command_buffer,
        self.ray_buffer.buffer,
        self.buffer_infos[@enumToInt(next_stage)][0].offset + @offsetOf(RayBufferCursor, "cursor"),
        @sizeOf(c_int),
        0,
    );
    const buffer_memory_barrier = vk.BufferMemoryBarrier{
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
        .src_queue_family_index = ctx.queue_indices.compute,
        .dst_queue_family_index = ctx.queue_indices.compute,
        .buffer = self.ray_buffer.buffer,
        .offset = self.buffer_infos[@enumToInt(next_stage)][0].offset,
        .size = self.buffer_infos[@enumToInt(next_stage)][0].range,
    };
    ctx.vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .transfer_bit = true },
        .{ .compute_shader_bit = true },
        .{},
        0,
        undefined,
        1,
        @ptrCast([*]const vk.BufferMemoryBarrier, &buffer_memory_barrier),
        0,
        undefined,
    );

    const x_dispatch = @ceil(@intToFloat(f32, self.image_size.width) / @intToFloat(f32, self.work_group_dim.x));
    const y_dispatch = @ceil(@intToFloat(f32, self.image_size.height) / @intToFloat(f32, self.work_group_dim.y));

    ctx.vkd.cmdDispatch(command_buffer, @floatToInt(u32, x_dispatch), @floatToInt(u32, y_dispatch), 1);
}
