const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const tracy = @import("ztracy");

const shaders = @import("shaders");

const render = @import("../render.zig");
const Context = render.Context;
const GpuBufferMemory = render.GpuBufferMemory;
const SimpleStagingBuffer = render.SimpleStagingBuffer;

const HostBrickState = @import("brick/HostBrickState.zig");
const DataFrameSnapshot = @import("brick/BrickStream.zig").DataFrameSnapshot;

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
    Resource.from(HostAndDeviceResources.brick_load_request_result_s),
    Resource.from(HostAndDeviceResources.brick_index_indices_s),
};

const BrickLoadPipeline = @This();

allocator: Allocator,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

work_group_dim: Dispatch1D,

ray_device_resources: *const RayDeviceResources,

// TODO: move to BrickStream
brick_staging_buffer: SimpleStagingBuffer,

/// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
/// texture should have a lifetime atleast the length of comptute pipeline
pub fn init(ctx: Context, ray_device_resources: *const RayDeviceResources, allocator: Allocator) !BrickLoadPipeline {
    const zone = tracy.ZoneN(@src(), @typeName(BrickLoadPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    // TODO: change based on NVIDIA vs AMD vs Others?
    const work_group_dim = Dispatch1D.init(ctx);

    const target_descriptor_layouts = ray_device_resources.getDescriptorSetLayouts(&resources);
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
    errdefer ctx.destroyPipelineLayout(pipeline_layout);

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
            .p_code = @as([*]const u32, @ptrCast(&shaders.brick_load_handling_spv)),
            .code_size = shaders.brick_load_handling_spv.len,
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

    const brick_staging_buffer = try SimpleStagingBuffer.init(ctx, allocator);
    errdefer brick_staging_buffer.deinit(ctx);

    return BrickLoadPipeline{
        .allocator = allocator,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .ray_device_resources = ray_device_resources,
        .work_group_dim = work_group_dim,
        .brick_staging_buffer = brick_staging_buffer,
    };
}

pub fn deinit(self: BrickLoadPipeline, ctx: Context) void {
    const zone = tracy.ZoneN(@src(), @typeName(BrickLoadPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    ctx.destroyPipelineLayout(self.pipeline_layout);
    ctx.destroyPipeline(self.pipeline);

    self.brick_staging_buffer.deinit(ctx);
}

// TODO: move to BrickStream
// Returns the amound of incoherent bricks
pub fn prepareBrickTransfer(
    self: *BrickLoadPipeline,
    ctx: Context,
    host_brick_state: *HostBrickState,
    ray_device_resources: *RayDeviceResources,
    snapshot: DataFrameSnapshot,
) !usize {
    const zone = tracy.ZoneN(@src(), @typeName(BrickLoadPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    std.debug.assert(snapshot.brick_limits.max_load_request_count > 0);
    std.debug.assert(snapshot.brick_limits.max_unload_request_count > 0);

    // TODO: bug: incoherent brick also being brick requested by gpu will lead to corruption

    const active_bricks: u32 = @intCast(snapshot.brick_limits.active_bricks);
    const max_load_count = snapshot.brick_limits.max_active_bricks - active_bricks;

    // If a brick is incoherent, then we must ask the device to unload the brick to reupload
    const incoherent_brick_count: usize = @intCast(@min(
        host_brick_state.inchoherent_bricks.count(),
        max_load_count,
    ));
    if (incoherent_brick_count > 0) {
        const brick_unload_buffer_index = (RayDeviceResources.Resource{ .host_and_device = .brick_unload_request_s }).toBufferIndex();
        std.debug.assert(@sizeOf(c_uint) == @sizeOf(u32));

        try self.brick_staging_buffer.transferToBuffer(
            &ray_device_resources.request_buffer,
            // We start at unload offset 0 since this will only occur next frame!
            ray_device_resources.buffer_infos[brick_unload_buffer_index].offset,
            u32,
            host_brick_state.inchoherent_bricks.keys()[0..incoherent_brick_count],
        );

        // Transfer brick set
        {
            // TODO: For now we just send the full grid brick set bits since it is relatively small amount of data
            const brick_set_buffer_index = (RayDeviceResources.Resource{ .device = .bricks_set_s }).toBufferIndex();
            try self.brick_staging_buffer.transferToBuffer(
                &ray_device_resources.voxel_scene_buffer,
                ray_device_resources.buffer_infos[brick_set_buffer_index].offset,
                u8,
                host_brick_state.brick_set,
            );
        }
    }
    // TODO: find a way to load in same frame as we unload

    const unload_request_count: usize = @intCast(@min(
        snapshot.brick_limits.unload_request_count,
        snapshot.brick_limits.max_unload_request_count,
    ));
    const load_request_count: usize = @intCast(@min(
        snapshot.brick_limits.load_request_count,
        max_load_count,
    ));

    const total_load_requests: usize = @intCast(@min(
        load_request_count,
        max_load_count,
    ));

    const active_bricks_before_load = @max(
        snapshot.brick_limits.active_bricks,
        0,
    );

    // if we need to deal we new bricks
    if (total_load_requests > 0) {
        // TODO: remove alloc, alloc on init
        const new_bricks = try self.allocator.alloc(ray_pipeline_types.Brick, total_load_requests);
        defer self.allocator.free(new_bricks);
        // TODO: remove alloc, alloc on init
        const new_brick_indices = try self.allocator.alloc(ray_pipeline_types.BrickLoadRequest, total_load_requests);
        defer self.allocator.free(new_brick_indices);
        // TODO: remove alloc, alloc on init
        const new_material_indices = try self.allocator.alloc(HostBrickState.material_index, total_load_requests * 512);
        defer self.allocator.free(new_material_indices);

        std.debug.assert(host_brick_state.brick_limits.max_active_bricks >= snapshot.brick_limits.active_bricks);

        const load_req_slices: [1][]const c_uint = .{
            snapshot.brick_load_requests[0..load_request_count],
            // host_brick_state.inchoherent_bricks.keys()[0..incoherent_brick_count],
        };
        var load_req_initalized_count: usize = 0;

        inline for (load_req_slices) |load_requests| {
            const from = load_req_initalized_count;
            const to = from + load_requests.len;
            for (
                load_requests,
                new_bricks[from..to],
                new_brick_indices[from..to],
                active_bricks_before_load + from..,
                from..,
            ) |
                load_index,
                *new_brick,
                *new_brick_index,
                brick_buffer_index,
                loop_iter,
            | {
                const brick_index = host_brick_state.brick_indices[load_index].index;
                new_brick.* = host_brick_state.bricks[brick_index];

                {
                    const mat_indices_dest = dest_blk: {
                        const start = loop_iter * 512;
                        const end = start + 512;
                        break :dest_blk new_material_indices[start..end];
                    };

                    const mat_indices_src = src_blk: {
                        const start = brick_index * 512;
                        const end = start + 512;
                        break :src_blk host_brick_state.voxel_material_indices[start..end];
                    };

                    @memcpy(mat_indices_dest, mat_indices_src);
                }

                new_brick_index.* = ray_pipeline_types.BrickLoadRequest{
                    .brick_index_index = load_index,
                    .brick_index_32b = @intCast(brick_buffer_index),
                };
            }

            load_req_initalized_count += load_requests.len;
        }

        // Transfer bricks
        {
            const brick_buffer_index = (RayDeviceResources.Resource{ .device = .bricks_b }).toBufferIndex();
            const new_bricks_offset: vk.DeviceSize = @intCast(snapshot.brick_limits.active_bricks * @sizeOf(ray_pipeline_types.Brick));
            try self.brick_staging_buffer.transferToBuffer(
                &ray_device_resources.voxel_scene_buffer,
                ray_device_resources.buffer_infos[brick_buffer_index].offset + new_bricks_offset,
                ray_pipeline_types.Brick,
                new_bricks,
            );
        }

        // Transfer material indices
        {
            const material_indices_index = (RayDeviceResources.Resource{ .device = .material_indices_b }).toBufferIndex();
            const new_material_indices_offset: vk.DeviceSize = @intCast(
                snapshot.brick_limits.active_bricks * 512 * @sizeOf(HostBrickState.material_index),
            );

            try self.brick_staging_buffer.transferToBuffer(
                &ray_device_resources.voxel_scene_buffer,
                ray_device_resources.buffer_infos[material_indices_index].offset + new_material_indices_offset,
                HostBrickState.material_index,
                new_material_indices,
            );
        }

        // Transfer patch work required to set gpu indices
        {
            const brick_load_request_result_index = (RayDeviceResources.Resource{ .host_and_device = .brick_load_request_result_s }).toBufferIndex();

            try self.brick_staging_buffer.transferToBuffer(
                &ray_device_resources.request_buffer,
                ray_device_resources.buffer_infos[brick_load_request_result_index].offset,
                ray_pipeline_types.BrickLoadRequest,
                new_brick_indices,
            );
        }
    }

    host_brick_state.brick_limits = snapshot.brick_limits;
    host_brick_state.brick_limits.active_bricks = active_bricks_before_load + @as(c_int, @intCast(total_load_requests));
    host_brick_state.brick_limits.load_request_count = @intCast(total_load_requests);

    if (unload_request_count + total_load_requests != 0) {
        const brick_req_limits_buffer_index = (RayDeviceResources.Resource{ .host_and_device = .brick_req_limits_s }).toBufferIndex();
        const limits_slice = [1]ray_pipeline_types.BrickLimits{host_brick_state.brick_limits};
        try self.brick_staging_buffer.transferToBuffer(
            &ray_device_resources.request_buffer,
            ray_device_resources.buffer_infos[brick_req_limits_buffer_index].offset,
            ray_pipeline_types.BrickLimits,
            &limits_slice,
        );
    }

    if (self.brick_staging_buffer.buffer_cursor != 0) {
        try self.brick_staging_buffer.sync(ctx);
    }

    host_brick_state.inchoherent_bricks.clearRetainingCapacity();
    return incoherent_brick_count;
}

pub fn appendPipelineCommands(self: *BrickLoadPipeline, ctx: Context, command_buffer: vk.CommandBuffer) void {
    const zone = tracy.ZoneN(@src(), @typeName(BrickLoadPipeline) ++ " " ++ @src().fn_name);
    defer zone.End();

    if (render.consts.enable_validation_layers) {
        const label_info = vk.DebugUtilsLabelEXT{
            .p_label_name = @typeName(BrickLoadPipeline) ++ " " ++ @src().fn_name,
            .color = [_]f32{ 0.4, 0.8, 0.2, 0.5 },
        };
        ctx.vkd.cmdBeginDebugUtilsLabelEXT(command_buffer, &label_info);
    }
    defer {
        if (render.consts.enable_validation_layers) {
            ctx.vkd.cmdEndDebugUtilsLabelEXT(command_buffer);
        }
    }

    // TODO remove barrier when we move this to dedicated queue
    {
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
    }

    if (self.brick_staging_buffer.buffer_cursor != 0) {
        self.brick_staging_buffer.flush(ctx, command_buffer);

        // TODO remove barrier when we move this to dedicated queue
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

    const x_dispatch = self.ray_device_resources.rayDispatch1D(self.work_group_dim);
    ctx.vkd.cmdDispatch(command_buffer, x_dispatch, 1, 1);
}
