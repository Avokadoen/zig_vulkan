const std = @import("std");

const Allocator = std.mem.Allocator;

const za = @import("zalgebra");
const vk = @import("vulkan");

const Context = @import("context.zig").Context;
const GpuBufferMemory = @import("gpu_buffer_memory.zig").GpuBufferMemory;

pub const TransformBuffer = struct {
    model: za.Mat4,
    view: za.Mat4,
    projection: za.Mat4,

    pub fn init() TransformBuffer {
        const left: f32 = -1.0;
        const right: f32 = 1.0;
        const bottom: f32 = -1.0;
        const top: f32 = 1.0;
        const z_near: f32 = 0.01;
        const z_far: f32 = 1000;
        return .{
            .model = za.Mat4.identity(),
            .view = za.Mat4.identity(),
            .projection = za.Mat4.orthographic(left, right, bottom, top, z_near, z_far)
        };
    }
}; 

pub inline fn createUniformDescriptorSetLayout(ctx: Context) !vk.DescriptorSetLayout {
    const ubo_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .uniform_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true, },
        .p_immutable_samplers = null,
    };
    const ubo_layout_info = vk.DescriptorSetLayoutCreateInfo{
        .flags = .{},
        .binding_count = 1,
        .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, &ubo_layout_binding),
    };
    return ctx.vkd.createDescriptorSetLayout(ctx.logical_device, ubo_layout_info, null);
}

pub inline fn createUniformDescriptorPool(ctx: Context, swapchain_image_count: usize) !vk.DescriptorPool {
    const pool_size = vk.DescriptorPoolSize{
        .@"type" = .uniform_buffer,
        .descriptor_count = @intCast(u32, swapchain_image_count),
    };
    const pool_info = vk.DescriptorPoolCreateInfo{
        .flags = .{},
        .max_sets = @intCast(u32, swapchain_image_count),
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast([*]const vk.DescriptorPoolSize, &pool_size),
    };
    return ctx.vkd.createDescriptorPool(ctx.logical_device, pool_info, null);
}

/// caller must make sure to destroy returned memory
pub inline fn createDescriptorSet(
    allocator: *Allocator, 
    ctx: Context, 
    swapchain_image_count: usize, 
    set_layout: vk.DescriptorSetLayout, 
    pool: vk.DescriptorPool,
    uniform_buffers: []GpuBufferMemory,
) ![]vk.DescriptorSet {
    if (uniform_buffers.len < swapchain_image_count) {
        return error.InsufficentUniformBuffer; // uniform buffer is of insufficent lenght
    }
    var set_layouts = try allocator.alloc(vk.DescriptorSetLayout, swapchain_image_count);
    defer allocator.destroy(set_layouts.ptr);
    {
        var i: usize = 0;
        while(i < swapchain_image_count) : (i += 1) {
            set_layouts[i] = set_layout;
        }
    }
    const alloc_info = vk.DescriptorSetAllocateInfo{
        .descriptor_pool = pool,
        .descriptor_set_count = @intCast(u32, swapchain_image_count),
        .p_set_layouts = set_layouts.ptr,
    };
    var sets = try allocator.alloc(vk.DescriptorSet, swapchain_image_count);
    errdefer allocator.destroy(sets.ptr);

    try ctx.vkd.allocateDescriptorSets(ctx.logical_device, alloc_info, sets.ptr);
    {
        var i: usize = 0;
        while(i < swapchain_image_count) : (i += 1) {
            const buffer_info = vk.DescriptorBufferInfo{
                .buffer = uniform_buffers[i].buffer,
                .offset = 0,
                .range = @sizeOf(TransformBuffer),
            };
            const write_descriptor_set = vk.WriteDescriptorSet{
                .dst_set = sets[i],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .uniform_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &buffer_info),
                .p_texel_buffer_view = undefined,
            };
            ctx.vkd.updateDescriptorSets(ctx.logical_device, 1, @ptrCast([*]const vk.WriteDescriptorSet, &write_descriptor_set), 0, undefined);
        }
    }
    return sets;
}

/// Caller must make sure to clean up returned memory
/// Create buffers for each image in the swapchain 
pub fn createUniformBuffers(allocator: *Allocator, ctx: Context, swapchain_image_count: usize) ![]GpuBufferMemory {
    const buffers = try allocator.alloc(GpuBufferMemory, swapchain_image_count);
    errdefer allocator.destroy(buffers.ptr);
    {
        const buffer_size = @sizeOf(TransformBuffer);
        var i: usize = 0;
        while (i < swapchain_image_count) : (i += 1) {
            buffers[i] = try GpuBufferMemory.init(ctx, buffer_size, .{ .uniform_buffer_bit = true, }, .{ .host_visible_bit = true, .host_coherent_bit = true, });
            errdefer buffers[i].deinit(); // Completely useless
        }
    }
    return buffers;
}
