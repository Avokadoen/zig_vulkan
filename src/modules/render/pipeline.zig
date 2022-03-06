const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const vk = @import("vulkan");
const glfw = @import("glfw");

const constants = @import("consts.zig");
const swapchain = @import("swapchain.zig");
const vertex = @import("vertex.zig");
const descriptor = @import("descriptor.zig");
const utils = @import("../utils.zig");
const dispatch = @import("dispatch.zig");

const GpuBufferMemory = @import("GpuBufferMemory.zig");
const Texture = @import("Texture.zig");
const Context = @import("Context.zig");

pub fn createFramebuffers(allocator: Allocator, ctx: Context, swapchain_data: *const swapchain.Data, render_pass: vk.RenderPass, prev_framebuffer: ?[]vk.Framebuffer) ![]vk.Framebuffer {
    const image_views = swapchain_data.image_views;
    var framebuffers = prev_framebuffer orelse try allocator.alloc(vk.Framebuffer, image_views.len);
    for (image_views) |view, i| {
        const attachments = [_]vk.ImageView{
            view,
        };
        const framebuffer_info = vk.FramebufferCreateInfo{
            .flags = .{},
            .render_pass = render_pass,
            .attachment_count = attachments.len,
            .p_attachments = @ptrCast([*]const vk.ImageView, &attachments),
            .width = swapchain_data.extent.width,
            .height = swapchain_data.extent.height,
            .layers = 1,
        };
        const framebuffer = try ctx.vkd.createFramebuffer(ctx.logical_device, &framebuffer_info, null);
        framebuffers[i] = framebuffer;
    }
    return framebuffers;
}

/// create a command buffers with sizeof buffer_count, caller must deinit returned list
pub fn createCmdBuffers(allocator: Allocator, ctx: Context, command_pool: vk.CommandPool, buffer_count: usize, prev_buffer: ?[]vk.CommandBuffer) ![]vk.CommandBuffer {
    var command_buffers = prev_buffer orelse try allocator.alloc(vk.CommandBuffer, buffer_count);
    const alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = vk.CommandBufferLevel.primary,
        .command_buffer_count = @intCast(u32, buffer_count),
    };
    try ctx.vkd.allocateCommandBuffers(ctx.logical_device, &alloc_info, command_buffers.ptr);
    command_buffers.len = buffer_count;

    return command_buffers;
}

/// create a command buffers with sizeof buffer_count, caller must destroy returned buffer with allocator
pub fn createCmdBuffer(ctx: Context, command_pool: vk.CommandPool) !vk.CommandBuffer {
    const alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = vk.CommandBufferLevel.primary,
        .command_buffer_count = @intCast(u32, 1),
    };
    var command_buffer: vk.CommandBuffer = undefined;
    try ctx.vkd.allocateCommandBuffers(ctx.logical_device, &alloc_info, @ptrCast([*]vk.CommandBuffer, &command_buffer));

    return command_buffer;
}

/// compute shader that draws to a target texture
pub const ComputeDrawPipeline = struct {
    // TODO: constant data
    // TODO: explicit binding ..
    pub const StateConfigs = struct {
        uniform_sizes: []const u64,
        storage_sizes: []const u64,
    };

    allocator: Allocator,

    pipeline_layout: vk.PipelineLayout,
    pipeline: *vk.Pipeline,

    in_flight_fence: vk.Fence,
    command_buffer: vk.CommandBuffer,

    // TODO: move this out?
    // compute pipelines *currently* should write to a texture
    target_texture: *Texture,
    target_descriptor_layout: vk.DescriptorSetLayout,
    target_descriptor_pool: vk.DescriptorPool,
    target_descriptor_set: vk.DescriptorSet,

    requested_rescale_pipeline: bool = false,

    uniform_buffers: []GpuBufferMemory,
    storage_buffers: []GpuBufferMemory,

    // TODO: descriptor has a lot of duplicate code with init ...
    // TODO: refactor descriptor stuff to be configurable (loop array of config objects for buffer stuff)
    // TODO: correctness if init fail, clean up resources created with errdefer

    /// initialize a compute pipeline, caller must make sure to call deinit, pipeline does not take ownership of target texture,
    /// texture should have a lifetime atleast the length of comptute pipeline
    pub fn init(allocator: Allocator, ctx: Context, shader_path: []const u8, target_texture: *Texture, state_config: StateConfigs) !ComputeDrawPipeline {
        var self: ComputeDrawPipeline = undefined;
        self.allocator = allocator;
        self.target_texture = target_texture;

        // TODO: descriptor set creation: one single for loop for each config instead of one for loop for each type

        // TODO: camera should be a push constant instead!
        const uniform_buffers = try allocator.alloc(GpuBufferMemory, state_config.uniform_sizes.len);
        errdefer allocator.free(uniform_buffers);
        for (state_config.uniform_sizes) |size, i| {
            // TODO: errdefer deinit
            uniform_buffers[i] = try GpuBufferMemory.init(ctx, size, .{ .uniform_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
        }

        const storage_buffers = try allocator.alloc(GpuBufferMemory, state_config.storage_sizes.len);
        errdefer allocator.free(storage_buffers);
        for (state_config.storage_sizes) |size, i| {
            // TODO: errdefer deinit
            storage_buffers[i] = try GpuBufferMemory.init(ctx, size, .{ .storage_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
        }

        const set_count = 1 + state_config.uniform_sizes.len + state_config.storage_sizes.len;
        const layout_bindings = try allocator.alloc(vk.DescriptorSetLayoutBinding, set_count);
        defer allocator.free(layout_bindings);
        self.target_descriptor_layout = blk: {
            // target image
            layout_bindings[0] = vk.DescriptorSetLayoutBinding{
                .binding = 0,
                .descriptor_type = .storage_image,
                .descriptor_count = 1,
                .stage_flags = .{
                    .compute_bit = true,
                },
                .p_immutable_samplers = null,
            };
            for (state_config.uniform_sizes) |_, i| {
                layout_bindings[1 + i] = vk.DescriptorSetLayoutBinding{
                    .binding = @intCast(u32, 1 + i),
                    .descriptor_type = .uniform_buffer,
                    .descriptor_count = 1,
                    .stage_flags = .{
                        .compute_bit = true,
                    },
                    .p_immutable_samplers = null,
                };
            }
            const index_offset = 1 + state_config.uniform_sizes.len;
            for (state_config.storage_sizes) |_, i| {
                layout_bindings[index_offset + i] = vk.DescriptorSetLayoutBinding{
                    .binding = @intCast(u32, index_offset + i),
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
                .binding_count = @intCast(u32, layout_bindings.len),
                .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, layout_bindings.ptr),
            };
            break :blk try ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &layout_info, null);
        };
        errdefer ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.target_descriptor_layout, null);

        const pool_sizes = try allocator.alloc(vk.DescriptorPoolSize, set_count);
        defer allocator.free(pool_sizes);
        self.target_descriptor_pool = blk: {
            pool_sizes[0] = vk.DescriptorPoolSize{
                .@"type" = .storage_image,
                .descriptor_count = 1,
            };
            for (state_config.uniform_sizes) |_, i| {
                pool_sizes[1 + i] = vk.DescriptorPoolSize{
                    .@"type" = .uniform_buffer,
                    .descriptor_count = 1,
                };
            }
            const index_offset = 1 + state_config.uniform_sizes.len;
            for (state_config.storage_sizes) |_, i| {
                pool_sizes[index_offset + i] = vk.DescriptorPoolSize{
                    .@"type" = .storage_buffer,
                    .descriptor_count = 1,
                };
            }
            const pool_info = vk.DescriptorPoolCreateInfo{
                .flags = .{},
                .max_sets = 1,
                .pool_size_count = @intCast(u32, pool_sizes.len),
                .p_pool_sizes = @ptrCast([*]const vk.DescriptorPoolSize, pool_sizes.ptr),
            };
            break :blk try ctx.vkd.createDescriptorPool(ctx.logical_device, &pool_info, null);
        };
        errdefer ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

        {
            const descriptor_set_alloc_info = vk.DescriptorSetAllocateInfo{
                .descriptor_pool = self.target_descriptor_pool,
                .descriptor_set_count = 1,
                .p_set_layouts = @ptrCast([*]vk.DescriptorSetLayout, &self.target_descriptor_layout),
            };
            try ctx.vkd.allocateDescriptorSets(ctx.logical_device, &descriptor_set_alloc_info, @ptrCast([*]vk.DescriptorSet, &self.target_descriptor_set));
        }

        {
            const buffer_infos = try allocator.alloc(vk.DescriptorBufferInfo, set_count - 1);
            defer allocator.free(buffer_infos);
            const write_descriptor_sets = try allocator.alloc(vk.WriteDescriptorSet, set_count);
            defer allocator.free(write_descriptor_sets);

            const image_info = vk.DescriptorImageInfo{
                .sampler = self.target_texture.sampler,
                .image_view = self.target_texture.image_view,
                .image_layout = .general,
            };
            write_descriptor_sets[0] = vk.WriteDescriptorSet{
                .dst_set = self.target_descriptor_set,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_image,
                .p_image_info = @ptrCast([*]const vk.DescriptorImageInfo, &image_info),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };

            for (state_config.uniform_sizes) |size, i| {
                buffer_infos[i] = vk.DescriptorBufferInfo{
                    .buffer = uniform_buffers[i].buffer,
                    .offset = 0,
                    .range = size,
                };
                write_descriptor_sets[i + 1] = vk.WriteDescriptorSet{
                    .dst_set = self.target_descriptor_set,
                    .dst_binding = @intCast(u32, i + 1),
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .uniform_buffer,
                    .p_image_info = undefined,
                    .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &buffer_infos[i]),
                    .p_texel_buffer_view = undefined,
                };
            }

            // store any user defined shader buffers
            for (state_config.storage_sizes) |size, i| {
                const index = 1 + state_config.uniform_sizes.len + i;
                // descriptor for buffer info
                buffer_infos[index - 1] = vk.DescriptorBufferInfo{
                    .buffer = storage_buffers[i].buffer,
                    .offset = 0,
                    .range = size,
                };
                write_descriptor_sets[index] = vk.WriteDescriptorSet{
                    .dst_set = self.target_descriptor_set,
                    .dst_binding = @intCast(u32, index),
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_buffer,
                    .p_image_info = undefined,
                    .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &buffer_infos[index - 1]),
                    .p_texel_buffer_view = undefined,
                };
            }

            // zig fmt: off
            ctx.vkd.updateDescriptorSets(
                ctx.logical_device, 
                @intCast(u32, write_descriptor_sets.len), 
                @ptrCast([*]const vk.WriteDescriptorSet, write_descriptor_sets.ptr),
                0,
                undefined
            );
            // zig fmt: on
        }

        self.pipeline_layout = blk: {
            const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = 1, // TODO: see GfxPipeline
                .p_set_layouts = @ptrCast([*]vk.DescriptorSetLayout, &self.target_descriptor_layout),
                .push_constant_range_count = 0,
                .p_push_constant_ranges = undefined,
            };
            break :blk try ctx.createPipelineLayout(pipeline_layout_info);
        };
        self.pipeline = blk: {
            const self_path = try std.fs.selfExePathAlloc(allocator);
            defer ctx.allocator.destroy(self_path.ptr);

            const code = blk1: {
                const path = blk2: {
                    const join_path = [_][]const u8{ self_path, shader_path };
                    break :blk2 try std.fs.path.resolve(allocator, join_path[0..]);
                };
                defer allocator.destroy(path.ptr);

                break :blk1 try utils.readFile(allocator, path);
            };
            defer code.deinit();

            const module = try ctx.createShaderModule(code.items[0..]);
            defer ctx.destroyShaderModule(module);

            const stage = vk.PipelineShaderStageCreateInfo{ .flags = .{}, .stage = .{ .compute_bit = true }, .module = module, .p_name = "main", .p_specialization_info = null };

            // TOOD: read on defer_compile_bit_nv
            const pipeline_info = vk.ComputePipelineCreateInfo{
                .flags = .{},
                .stage = stage,
                .layout = self.pipeline_layout,
                .base_pipeline_handle = .null_handle, // TODO: GfxPipeline?
                .base_pipeline_index = -1,
            };
            break :blk try ctx.createComputePipeline(allocator, pipeline_info);
        };

        const fence_info = vk.FenceCreateInfo{
            .flags = .{
                .signaled_bit = true,
            },
        };
        self.in_flight_fence = try ctx.vkd.createFence(ctx.logical_device, &fence_info, null);

        // TODO: we need to rescale pipeline dispatch
        self.command_buffer = try createCmdBuffer(ctx, ctx.comp_cmd_pool);
        errdefer ctx.vkd.freeCommandBuffers(ctx.logical_device, ctx.comp_cmd_pool, 1, @ptrCast([*]vk.CommandBuffer, &self.command_buffer));

        try self.recordCommands(ctx);

        // zig fmt: off
        return ComputeDrawPipeline{ 
            .allocator = self.allocator, 
            .pipeline_layout = self.pipeline_layout, 
            .pipeline = self.pipeline, 
            .in_flight_fence = self.in_flight_fence, 
            .command_buffer = self.command_buffer, 
            .target_texture = self.target_texture, 
            .target_descriptor_layout = self.target_descriptor_layout, 
            .target_descriptor_pool = self.target_descriptor_pool, 
            .target_descriptor_set = self.target_descriptor_set, 
            .uniform_buffers = uniform_buffers,
            .storage_buffers = storage_buffers,
        };
        // zig fmt: on
    }

    // TODO: sync
    pub fn compute(self: ComputeDrawPipeline, ctx: Context) !void {
        self.wait_idle(ctx);

        const wait_stages = vk.PipelineStageFlags{ .compute_shader_bit = true };
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = @ptrCast([*]const vk.PipelineStageFlags, &wait_stages),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        };
        const p_submit_info = @ptrCast([*]const vk.SubmitInfo, &submit_info);
        _ = try ctx.vkd.resetFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.in_flight_fence));
        try ctx.vkd.queueSubmit(
            ctx.compute_queue,
            1,
            p_submit_info,
            self.in_flight_fence,
        );
    }

    /// Used to update the pipeline according to changes in the window spec
    /// This functions should only be called from the main thread (see glfwGetFramebufferSize)
    fn rescalePipeline(self: *ComputeDrawPipeline, ctx: Context) !void {
        var window_size = try ctx.window_ptr.*.getFramebufferSize();
        while (window_size.width == 0 or window_size.height == 0) {
            window_size = try ctx.window_ptr.*.getFramebufferSize();
            try glfw.waitEvents();
        }

        self.requested_rescale_pipeline = false;
        // TODO: swapchain can be recreated without waiting and so waiting in the top of the
        //       functions is wasteful
        // Wait for pipeline to become idle
        self.wait_idle(ctx);

        ctx.vkd.freeCommandBuffers(ctx.logical_device, ctx.comp_cmd_pool, 1, @ptrCast([*]const vk.CommandBuffer, &self.command_buffer));

        self.command_buffer = try createCmdBuffer(ctx, ctx.comp_cmd_pool);

        try self.recordCommands(ctx);
    }

    pub fn deinit(self: ComputeDrawPipeline, ctx: Context) void {
        self.wait_idle(ctx);

        ctx.vkd.destroyFence(ctx.logical_device, self.in_flight_fence, null);

        for (self.uniform_buffers) |buffer| {
            buffer.deinit(ctx);
        }
        self.allocator.free(self.uniform_buffers);
        for (self.storage_buffers) |buffer| {
            buffer.deinit(ctx);
        }
        self.allocator.free(self.storage_buffers);

        ctx.vkd.freeCommandBuffers(ctx.logical_device, ctx.comp_cmd_pool, 1, @ptrCast([*]const vk.CommandBuffer, &self.command_buffer));
        ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.target_descriptor_layout, null);
        ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.target_descriptor_pool, null);

        ctx.destroyPipelineLayout(self.pipeline_layout);
        ctx.destroyPipeline(self.pipeline);

        self.allocator.destroy(self.pipeline);
    }

    /// Wait for fence to signal complete 
    pub inline fn wait_idle(self: ComputeDrawPipeline, ctx: Context) void {
        _ = ctx.vkd.waitForFences(ctx.logical_device, 1, @ptrCast([*]const vk.Fence, &self.in_flight_fence), vk.TRUE, std.math.maxInt(u64)) catch |err| {
            // ctx.writers.stderr.print("waiting for fence failed: {}", .{err}) catch |e| switch (e) {
            //     else => {}, // Discard print errors ...
            // };
            std.io.getStdErr().writer().print("waiting for fence failed: {}", .{err}) catch {};
        };
    }

    inline fn recordCommands(self: ComputeDrawPipeline, ctx: Context) !void {
        const image_use = Texture.getImageTransitionBarrier(self.target_texture.image, .general, .general);
        const command_begin_info = vk.CommandBufferBeginInfo{
            .flags = .{},
            .p_inheritance_info = null,
        };
        try ctx.vkd.beginCommandBuffer(self.command_buffer, &command_begin_info);
        ctx.vkd.cmdBindPipeline(self.command_buffer, vk.PipelineBindPoint.compute, self.pipeline.*);
        // zig fmt: off
        ctx.vkd.cmdPipelineBarrier(
            self.command_buffer, 
            image_use.transition.src_stage, 
            image_use.transition.dst_stage, 
            vk.DependencyFlags{}, 
            0, 
            undefined, 
            0, 
            undefined, 
            1, 
            @ptrCast([*]const vk.ImageMemoryBarrier, &image_use.barrier)
        );
        // bind target texture
        ctx.vkd.cmdBindDescriptorSets(
            self.command_buffer, 
            .compute, 
            self.pipeline_layout, 
            0, 
            1, 
            @ptrCast([*]const vk.DescriptorSet, &self.target_descriptor_set), 
            0, 
            undefined
        );
        // zig fmt: on
        // TODO: allow varying local thread size, error if x_ or y_ dispatch have decimal values
        // compute shader has 16 thread in x and y, we calculate inverse at compile time
        const local_thread_factor_x: f32 = comptime blk: {
            break :blk 1.0 / 32.0;
        };
        const local_thread_factor_y: f32 = comptime blk: {
            break :blk 1.0 / 32.0;
        };
        const img_width = self.target_texture.image_extent.width;
        const img_height = self.target_texture.image_extent.height;
        const x_dispatch = @ceil(@intToFloat(f32, img_width) * local_thread_factor_x);
        const y_dispatch = @ceil(@intToFloat(f32, img_height) * local_thread_factor_y);
        ctx.vkd.cmdDispatch(self.command_buffer, @floatToInt(u32, x_dispatch), @floatToInt(u32, y_dispatch), 1);
        try ctx.vkd.endCommandBuffer(self.command_buffer);
    }
};
