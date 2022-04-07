const std = @import("std");

const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const stbi = @import("stbi");

const za = @import("zalgebra");

const Texture = @import("Texture.zig"); // TODO: remove me

const Context = @import("Context.zig");
const GpuBufferMemory = @import("GpuBufferMemory.zig");

// TODO: rename file
// TODO: check for slices in config, report error
// TODO: allow naming shader types!

pub const ImageConfig = struct {
    image: stbi.Image,
    is_compute_target: bool,
};

/// Configuration for SyncDescriptor and Descriptor
pub const Config = struct {
    allocator: Allocator,
    ctx: Context,
    viewport: vk.Viewport,
    buffer_count: usize, // TODO: rename to swapchain buffer count
    /// the size of each storage buffer element, descriptor makes a copy of data 
    buffer_sizes: []const u64,

    texture_configs: []ImageConfig,
};

pub const SyncDescriptor = struct {
    const Self = @This();

    mutex: std.Thread.Mutex,
    ubo: Descriptor,

    pub fn init(config: Config) !Self {
        const ubo = try Descriptor.init(config);

        return Self{
            .mutex = .{},
            .ubo = ubo,
        };
    }

    pub fn deinit(self: Self, ctx: Context) void {
        self.ubo.deinit(ctx);
    }
};

pub const Descriptor = struct {
    const Self = @This();

    allocator: Allocator,

    uniform_data: Uniform,
    uniform_buffers: []GpuBufferMemory,

    buffer_sizes: []u64,
    storage_buffers: [][]GpuBufferMemory,

    descriptor_set_layout: vk.DescriptorSetLayout,
    // wether a buffer is up to date everywhere according to changes with data
    is_dirty: []bool,
    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: []vk.DescriptorSet,

    // TODO: seperate texture from UniformBuffer
    textures: []Texture,

    // TODO: comptime check that config is const, since var triggers a bug in zig
    pub fn init(config: Config) !Self {
        const owned_buffer_sizes = blk: {
            const sizes = try config.allocator.alloc(u64, config.buffer_sizes.len);
            std.mem.copy(u64, sizes, config.buffer_sizes);
            break :blk sizes;
        };
        errdefer config.allocator.free(owned_buffer_sizes);

        const uniform_data = Uniform.init(config.viewport);

        const descriptor_set_layout = try createDescriptorSetLayout(config.ctx, config.allocator, owned_buffer_sizes.len);
        errdefer config.ctx.vkd.destroyDescriptorSetLayout(config.ctx.logical_device, descriptor_set_layout, null);

        var is_dirty = try config.allocator.alloc(bool, config.buffer_count);
        std.mem.set(bool, is_dirty, true);

        const descriptor_pool = try createDescriptorPool(config.ctx, config.allocator, owned_buffer_sizes.len, config.buffer_count);
        errdefer config.ctx.vkd.destroyDescriptorPool(config.ctx.logical_device, descriptor_pool, null);

        // use graphics and compute index
        // if they are the same, then we use that index
        const indices = [_]u32{ config.ctx.queue_indices.graphics, config.ctx.queue_indices.compute };
        const indices_len: usize = if (config.ctx.queue_indices.graphics == config.ctx.queue_indices.compute) 1 else 2;

        const PixelType = stbi.Pixel;
        const textures = try config.allocator.alloc(Texture, config.texture_configs.len);
        errdefer config.allocator.free(textures);

        var textures_initialized: usize = 0;
        for (config.texture_configs) |tconfig, i| {
            var format: vk.Format = undefined;
            var layout: vk.ImageLayout = undefined;
            if (tconfig.is_compute_target) {
                format = .r8g8b8a8_unorm;
                layout = .general;
            } else {
                format = .r8g8b8a8_srgb;
                layout = .shader_read_only_optimal;
            }

            // TODO: reuse duplicate data (sampler ... etc)?
            const TextureConfig = Texture.Config(PixelType);
            const texture_config = TextureConfig{
                .data = tconfig.image.data,
                .width = @intCast(u32, tconfig.image.width),
                .height = @intCast(u32, tconfig.image.height),
                .usage = .{ .transfer_dst_bit = true, .sampled_bit = true, .storage_bit = tconfig.is_compute_target },
                .queue_family_indices = indices[0..indices_len],
                .format = format,
            };
            textures[i] = try Texture.init(config.ctx, config.ctx.gfx_cmd_pool, layout, PixelType, texture_config);
            textures_initialized = i + 1;
        }
        errdefer {
            var i: usize = 0;
            while (i < textures_initialized) {
                textures[i].deinit(config.ctx);
            }
        }

        const uniform_buffers = try createShaderBuffers(
            config.allocator,
            Uniform,
            .{ .uniform_buffer_bit = true },
            config.ctx,
            config.buffer_count,
        );
        errdefer {
            for (uniform_buffers) |buffer| {
                buffer.deinit(config.ctx);
            }
            config.allocator.free(uniform_buffers);
        }

        // do not allocate if there are no buffers
        const storage_count = config.buffer_count * std.math.max(1, config.buffer_sizes.len);
        var storage_buffers = try config.allocator.alloc([]GpuBufferMemory, storage_count);
        errdefer config.allocator.free(storage_buffers);

        for (storage_buffers) |*buffers| {
            buffers.* = try config.allocator.alloc(GpuBufferMemory, owned_buffer_sizes.len);
            errdefer config.allocator.free(buffers.*);

            for (owned_buffer_sizes) |buffer_size, i| {
                buffers.*[i] = try GpuBufferMemory.init(config.ctx, buffer_size, .{
                    .storage_buffer_bit = true,
                }, .{
                    .host_visible_bit = true,
                    .host_coherent_bit = true,
                });
                // TODO: properly handle error occurance in the loop
                errdefer buffers.*[i].deinit(config.ctx);
            }
        }

        const descriptor_sets = try createDescriptorSet(
            config.allocator,
            config.ctx,
            owned_buffer_sizes,
            config.buffer_count,
            descriptor_set_layout,
            descriptor_pool,
            uniform_buffers,
            storage_buffers,
            textures,
        );
        errdefer config.allocator.free(descriptor_sets);

        return Self{
            .allocator = config.allocator,
            .uniform_data = uniform_data,
            .uniform_buffers = uniform_buffers,
            .buffer_sizes = owned_buffer_sizes,
            .storage_buffers = storage_buffers,
            .descriptor_set_layout = descriptor_set_layout,
            .is_dirty = is_dirty,
            .descriptor_pool = descriptor_pool,
            .descriptor_sets = descriptor_sets,
            .textures = textures,
        };
    }

    pub inline fn translate_horizontal(self: *Self, value: f32) void {
        self.uniform_data.view.fields[0][3] += value;
        self.mark_dirty();
    }

    pub inline fn translate_vertical(self: *Self, value: f32) void {
        self.uniform_data.view.fields[1][3] += value;
        self.mark_dirty();
    }

    pub inline fn scale(self: *Self, factor: f32) void {
        self.uniform_data.view.fields[0][0] += factor;
        self.uniform_data.view.fields[1][1] += factor;
        self.uniform_data.view.fields[2][2] += factor;
        self.mark_dirty();
    }

    pub inline fn mark_dirty(self: *Self) void {
        std.mem.set(bool, self.is_dirty, true);
    }

    pub fn deinit(self: Self, ctx: Context) void {
        self.allocator.free(self.buffer_sizes);
        for (self.textures) |texture| {
            texture.deinit(ctx);
        }
        self.allocator.free(self.textures);

        for (self.uniform_buffers) |buffer| {
            buffer.deinit(ctx);
        }
        self.allocator.free(self.uniform_buffers);

        for (self.storage_buffers) |buffers| {
            for (buffers) |buffer| {
                buffer.deinit(ctx);
            }
            self.allocator.free(buffers);
        }
        self.allocator.free(self.storage_buffers);

        self.allocator.free(self.descriptor_sets);
        self.allocator.free(self.is_dirty);

        ctx.vkd.destroyDescriptorPool(ctx.logical_device, self.descriptor_pool, null);
        ctx.vkd.destroyDescriptorSetLayout(ctx.logical_device, self.descriptor_set_layout, null);
    }
};

// TODO: multiply projection and view on CPU (model is instanced (TODO) and has to be applied on GPU)
// TODO: push constant instead?
pub const Uniform = extern struct {
    const Mat4 = [4][4]f32;

    view: Mat4,
    projection: Mat4,

    pub fn init(viewport: vk.Viewport) Uniform {
        return .{
            .view = za.Mat4.identity().data,
            .projection = blk: {
                const half_width = viewport.width * 0.5;
                const half_height = viewport.height * 0.5;
                const left: f32 = -half_width;
                const right: f32 = half_width;
                const bottom: f32 = half_height;
                const top: f32 = -half_height;
                const z_near: f32 = -1000;
                const z_far: f32 = 1000;
                break :blk za.Mat4.orthographic(left, right, bottom, top, z_near, z_far).data;
            },
        };
    }
};

/// No external memory management needed
fn createDescriptorSetLayout(ctx: Context, allocator: Allocator, buffer_sizes_len: usize) !vk.DescriptorSetLayout {
    const ubo_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .uniform_buffer,
        .descriptor_count = 1,
        .stage_flags = .{
            .vertex_bit = true,
        },
        .p_immutable_samplers = null,
    };
    const sampler_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 1,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{
            .fragment_bit = true,
        },
        .p_immutable_samplers = null,
    };

    var layout_bindings = try allocator.alloc(vk.DescriptorSetLayoutBinding, buffer_sizes_len + 2);
    defer allocator.free(layout_bindings);

    layout_bindings[0] = ubo_layout_binding;
    layout_bindings[1] = sampler_layout_binding;
    for (layout_bindings[2..]) |*layout_binding, i| {
        layout_binding.* = .{
            .binding = @intCast(u32, i + 2),
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{
                .vertex_bit = true,
            },
            .p_immutable_samplers = null,
        };
    }
    const layout_info = vk.DescriptorSetLayoutCreateInfo{
        .flags = .{},
        .binding_count = @intCast(u32, layout_bindings.len),
        .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, layout_bindings.ptr),
    };
    return ctx.vkd.createDescriptorSetLayout(ctx.logical_device, &layout_info, null);
}

/// No external memory management needed
inline fn createDescriptorPool(ctx: Context, allocator: Allocator, buffer_sizes_len: usize, swapchain_image_count: usize) !vk.DescriptorPool {
    const image_count = @intCast(u32, swapchain_image_count);
    const ubo_pool_size = vk.DescriptorPoolSize{
        .@"type" = .uniform_buffer,
        .descriptor_count = image_count,
    };
    const sampler_pool_size = vk.DescriptorPoolSize{
        .@"type" = .combined_image_sampler,
        .descriptor_count = image_count,
    };

    var pool_sizes = try allocator.alloc(vk.DescriptorPoolSize, 2 + buffer_sizes_len);
    defer allocator.free(pool_sizes);

    pool_sizes[0] = ubo_pool_size;
    pool_sizes[1] = sampler_pool_size;

    for (pool_sizes[2..]) |*pool_size| {
        pool_size.* = .{
            .@"type" = .storage_buffer,
            .descriptor_count = image_count,
        };
    }
    const pool_info = vk.DescriptorPoolCreateInfo{
        .flags = .{},
        .max_sets = image_count,
        .pool_size_count = @intCast(u32, pool_sizes.len),
        .p_pool_sizes = @ptrCast([*]const vk.DescriptorPoolSize, pool_sizes.ptr),
    };
    return ctx.vkd.createDescriptorPool(ctx.logical_device, &pool_info, null);
}

// TODO: update to reflect on config!
/// caller must make sure to destroy returned memory needed
fn createDescriptorSet(
    allocator: Allocator,
    ctx: Context,
    buffer_sizes: []const u64, // type of storage buffer, may be empty
    swapchain_image_count: usize,
    set_layout: vk.DescriptorSetLayout,
    pool: vk.DescriptorPool,
    uniform_buffers: []GpuBufferMemory,
    storage_buffers: [][]GpuBufferMemory,
    textures: []Texture,
) ![]vk.DescriptorSet {
    if (uniform_buffers.len < swapchain_image_count) {
        return error.InsufficentUniformBuffer; // uniform buffer is of insufficent lenght
    }
    if (storage_buffers.len < swapchain_image_count) {
        return error.InsufficentStorageBuffer; // storage buffer is of insufficent lenght
    }

    var set_layouts = try allocator.alloc(vk.DescriptorSetLayout, swapchain_image_count);
    defer allocator.free(set_layouts);
    {
        var i: usize = 0;
        while (i < swapchain_image_count) : (i += 1) {
            set_layouts[i] = set_layout;
        }
    }

    const alloc_info = vk.DescriptorSetAllocateInfo{
        .descriptor_pool = pool,
        .descriptor_set_count = @intCast(u32, swapchain_image_count),
        .p_set_layouts = set_layouts.ptr,
    };
    var sets = try allocator.alloc(vk.DescriptorSet, swapchain_image_count);
    errdefer allocator.free(sets);

    try ctx.vkd.allocateDescriptorSets(ctx.logical_device, &alloc_info, sets.ptr);
    {
        var i: usize = 0;
        while (i < swapchain_image_count) : (i += 1) {
            // descriptor for uniform data
            const ubo_buffer_info = vk.DescriptorBufferInfo{
                .buffer = uniform_buffers[i].buffer,
                .offset = 0,
                .range = @sizeOf(Uniform),
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

            const image_infos = try allocator.alloc(vk.DescriptorImageInfo, textures.len);
            defer allocator.free(image_infos);
            // descriptor for image data
            for (textures) |texture, j| {
                image_infos[j] = vk.DescriptorImageInfo{
                    .sampler = texture.sampler,
                    .image_view = texture.image_view,
                    .image_layout = texture.layout,
                };
            }
            const image_write_descriptor_set = vk.WriteDescriptorSet{
                .dst_set = sets[i],
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = @intCast(u32, image_infos.len),
                .descriptor_type = .combined_image_sampler,
                .p_image_info = image_infos.ptr,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };

            var write_descriptor_sets = try allocator.alloc(vk.WriteDescriptorSet, 2 + buffer_sizes.len);
            defer allocator.free(write_descriptor_sets);

            // Always store ubo and image descriptor
            write_descriptor_sets[0] = ubo_write_descriptor_set;
            write_descriptor_sets[1] = image_write_descriptor_set;

            // store buffer info on the heap until we have updated set
            var storage_buffer_infos = try allocator.alloc(vk.DescriptorBufferInfo, buffer_sizes.len);
            defer allocator.free(storage_buffer_infos);

            // store any user defined shader buffers
            for (buffer_sizes) |buffer_size, j| {
                // descriptor for buffer info
                storage_buffer_infos[j] = vk.DescriptorBufferInfo{
                    .buffer = storage_buffers[i][j].buffer,
                    .offset = 0,
                    .range = buffer_size,
                };
                write_descriptor_sets[j + 2] = vk.WriteDescriptorSet{
                    .dst_set = sets[i],
                    .dst_binding = @intCast(u32, j + 2),
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_buffer,
                    .p_image_info = undefined,
                    .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &storage_buffer_infos[j]),
                    .p_texel_buffer_view = undefined,
                };
            }

            ctx.vkd.updateDescriptorSets(
                ctx.logical_device,
                @intCast(u32, write_descriptor_sets.len),
                @ptrCast([*]const vk.WriteDescriptorSet, write_descriptor_sets.ptr),
                0,
                undefined,
            );
        }
    }
    return sets;
}

/// Caller must make sure to clean up returned memory
/// Create buffers for each image in the swapchain 
inline fn createShaderBuffers(allocator: Allocator, comptime StorageType: type, buf_usage_flags: vk.BufferUsageFlags, ctx: Context, count: usize) ![]GpuBufferMemory {
    const buffers = try allocator.alloc(GpuBufferMemory, count);
    errdefer allocator.free(buffers);

    const buffer_size = @sizeOf(StorageType);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        buffers[i] = try GpuBufferMemory.init(ctx, buffer_size, buf_usage_flags, .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        });
    }
    errdefer {
        while (i >= 0) : (i -= 1) {
            buffers[i].deinit();
        }
    }
    return buffers;
}
