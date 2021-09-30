const std = @import("std");

const Allocator = std.mem.Allocator;

const za = @import("zalgebra");
const vk = @import("vulkan");

const stbi = @import("stbi");

const texture = @import("texture.zig");

const Context = @import("context.zig").Context;
const GpuBufferMemory = @import("gpu_buffer_memory.zig").GpuBufferMemory;
const Texture = texture.Texture; // TODO: remove me

// TODO: rename file

pub const SyncUniformBuffer = struct {
    const Self = @This();

    mutex: std.Thread.Mutex,
    ubo: UniformBuffer,

    pub fn init(allocator: *Allocator, ctx: Context, buffer_count: usize, viewport: vk.Viewport) !Self {
        const ubo = try UniformBuffer.init(allocator, ctx, buffer_count, viewport);

        return Self{
            .mutex = .{},
            .ubo = ubo,
        };
    }

    pub fn deinit(self: Self, ctx: Context) void {
        self.ubo.deinit(ctx);
    }
};

pub const UniformBuffer = struct {
    const Self = @This();
    
    allocator: *Allocator,
    data: TransformBuffer,
    
    descriptor_set_layout: vk.DescriptorSetLayout,
    buffers: []GpuBufferMemory, 
    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: []vk.DescriptorSet,

    // TODO: seperate texture from UniformBuffer
    my_texture: Texture,

    pub fn init(allocator: *Allocator, ctx: Context, buffer_count: usize, viewport: vk.Viewport) !Self {
        const data = TransformBuffer.init(viewport);
        
        const descriptor_set_layout = try createDescriptorSetLayout(ctx);
        errdefer ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, descriptor_set_layout, null);

        const buffers = try createUniformBuffers(allocator, ctx, buffer_count);
        errdefer {
            for (buffers) |buffer| {
                buffer.deinit(ctx);
            }
            allocator.destroy(buffers.ptr);
        }
        const descriptor_pool = try createUniformDescriptorPool(ctx, buffer_count);
        errdefer ctx.vkd.destroyDescriptorPool(ctx.logical_device, descriptor_pool, null);

        // TODO: should not be a member of this struct!
        const stb_image = try stbi.Image.init(allocator, "../assets/images/grasstop.png"[0..], stbi.DesiredChannels.STBI_rgb_alpha);
        defer stb_image.deinit();

        // use graphics and compute index
        // if they are the same, the we use that index
        const indices = [_]u32{ ctx.queue_indices.graphics, ctx.queue_indices.compute };
        const indices_len: usize = if (ctx.queue_indices.graphics == ctx.queue_indices.compute) 1 else 2;
       
        const PixelType = stbi.Pixel;
        const TextureConfig = texture.Config(PixelType);
        const texture_config = TextureConfig{
            .data = stb_image.data, 
            .width = @intCast(u32, stb_image.width),
            .height = @intCast(u32, stb_image.height),
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true, .storage_bit = true  },
            .queue_family_indices = indices[0..indices_len],
            // TODO: this format is a storage format, but causes loaded texture to become lighter,
            // for compute texture we dont care about loading (transfer), so as long as computed output
            // account for unorm we should be good. Remove transfer functionality when we dont need it!
            .format = .r8g8b8a8_unorm, 
        };
        const my_texture = try Texture.init(ctx, ctx.gfx_cmd_pool, .general, PixelType, texture_config);
        errdefer my_texture.deinit(ctx);

        const descriptor_sets = try createDescriptorSet(
            allocator,
            ctx,
            buffer_count,
            descriptor_set_layout,
            descriptor_pool,
            buffers,
            my_texture.sampler,
            my_texture.image_view
        );
        errdefer allocator.destroy(descriptor_sets.ptr);

        return Self{
            .allocator = allocator,
            .data = data,
            .descriptor_set_layout = descriptor_set_layout,
            .buffers = buffers,
            .descriptor_pool = descriptor_pool,
            .descriptor_sets = descriptor_sets,
            .my_texture = my_texture,
        };
    }

    pub fn deinit(self: Self, ctx: Context) void {
        self.my_texture.deinit(ctx);

        for(self.buffers) |buffer| {
            buffer.deinit(ctx);
        }
        self.allocator.destroy(self.buffers.ptr);
        self.allocator.destroy(self.descriptor_sets.ptr);

        ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.descriptor_pool, null);
        ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.descriptor_set_layout, null);
    }
};

// TODO: multiply projection and view on CPU (model is instanced (TODO) and has to be applied on GPU)
pub const TransformBuffer = struct {
    model: za.Mat4, 
    view: za.Mat4,
    projection: za.Mat4,

    pub fn init(viewport: vk.Viewport) TransformBuffer {
        return .{
            .model = blk: {
                const translate = za.Vec3.new(0.0, 0.0, 0.0);
                const scale = za.Vec3.new(viewport.height, viewport.height, 0.0);
                break :blk za.Mat4.fromTranslate(translate).scale(scale);
            },
            .view = za.Mat4.identity(),
            .projection = blk: {
                const half_width  =  viewport.width  * 0.5;
                const half_height =  viewport.height * 0.5;
                const left:   f32 = -half_width;
                const right:  f32 =  half_width;
                const bottom: f32 =  half_height;
                const top:    f32 = -half_height;
                const z_near: f32 = -1000;
                const z_far:  f32 =  1000;
                break :blk za.Mat4.orthographic(left, right, bottom, top, z_near, z_far);
            },
        };
    }
}; 

pub inline fn createDescriptorSetLayout(ctx: Context) !vk.DescriptorSetLayout {
    const ubo_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .uniform_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true, },
        .p_immutable_samplers = null,
    };
    const sampler_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 1,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true, },
        .p_immutable_samplers = null,
    };
    const layout_bindings = [_]vk.DescriptorSetLayoutBinding{ubo_layout_binding, sampler_layout_binding};
    const layout_info = vk.DescriptorSetLayoutCreateInfo{
        .flags = .{},
        .binding_count = layout_bindings.len,
        .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, &layout_bindings),
    };
    return ctx.vkd.createDescriptorSetLayout(ctx.logical_device, layout_info, null);
}

pub inline fn createUniformDescriptorPool(ctx: Context, swapchain_image_count: usize) !vk.DescriptorPool {
    const ubo_pool_size = vk.DescriptorPoolSize{
        .@"type" = .uniform_buffer,
        .descriptor_count = @intCast(u32, swapchain_image_count),
    };
    const sampler_pool_size = vk.DescriptorPoolSize{
        .@"type" = .combined_image_sampler,
        .descriptor_count = @intCast(u32, swapchain_image_count),
    };
    const pool_sizes = [_]vk.DescriptorPoolSize { ubo_pool_size, sampler_pool_size };
    const pool_info = vk.DescriptorPoolCreateInfo{
        .flags = .{},
        .max_sets = @intCast(u32, swapchain_image_count),
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = @ptrCast([*]const vk.DescriptorPoolSize, &pool_sizes),
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
    sampler: vk.Sampler,
    image_view: vk.ImageView
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
            const ubo_buffer_info = vk.DescriptorBufferInfo{
                .buffer = uniform_buffers[i].buffer,
                .offset = 0,
                .range = @sizeOf(TransformBuffer),
            };
            const ubo_write_descriptor_set = vk.WriteDescriptorSet{
                .dst_set = sets[i],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .uniform_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &ubo_buffer_info),
                .p_texel_buffer_view = undefined,
            };
            const image_info = vk.DescriptorImageInfo{
                .sampler = sampler,
                .image_view = image_view,
                .image_layout = .general, // TODO: support swapping between general and readonly optimal
            };
            const image_write_descriptor_set = vk.WriteDescriptorSet{
                .dst_set = sets[i],
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .p_image_info = @ptrCast([*]const vk.DescriptorImageInfo, &image_info),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };
            const write_descriptor_sets = [_]vk.WriteDescriptorSet{ ubo_write_descriptor_set, image_write_descriptor_set };
            ctx.vkd.updateDescriptorSets(
                ctx.logical_device, 
                write_descriptor_sets.len, 
                @ptrCast([*]const vk.WriteDescriptorSet, &write_descriptor_sets), 
                0, 
                undefined
            );
        }
    }
    return sets;
}

/// Caller must make sure to clean up returned memory
/// Create buffers for each image in the swapchain 
pub inline fn createUniformBuffers(allocator: *Allocator, ctx: Context, swapchain_image_count: usize) ![]GpuBufferMemory {
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
