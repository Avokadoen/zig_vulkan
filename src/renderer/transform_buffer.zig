const std = @import("std");

const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const stbi = @import("stbi");

const zlm = @import("zlm");

const texture = @import("texture.zig");
const Texture = texture.Texture; // TODO: remove me

const Context = @import("context.zig").Context;
const GpuBufferMemory = @import("gpu_buffer_memory.zig").GpuBufferMemory;

pub const UV = struct {
    // uv range of mega texutre 
    min: zlm.Vec2,
    max: zlm.Vec2,
};

// TODO: rename file
// TODO: rename struct to reflect 2D?
// TODO: check for slices in config, report error
// TODO: allow naming shader types!

/// used to initialize a UniformBufferDescriptor & SyncUniformBuffer
pub fn UniformBufferDescriptorConfig(comptime type_count: comptime_int, comptime ShaderTypes: [type_count]type) type {
    const StorageType: type = switch (type_count) {
        0 => void,
        else => blk: {
            var new_type_fields: [type_count]std.builtin.TypeInfo.StructField = undefined;
            var utf8_number_buffer: [3]u8 = undefined; // support up to 999 struct field values
            inline for (ShaderTypes[0..type_count]) |field_type, i| {
                const utf8_number = std.fmt.bufPrint(utf8_number_buffer[0..], "{d}", .{i}) catch unreachable;
                new_type_fields[i].name = "member_" ++  utf8_number;
                new_type_fields[i].field_type = field_type;
                new_type_fields[i].default_value = null;
                new_type_fields[i].is_comptime = false;
                new_type_fields[i].alignment = @alignOf(field_type);
            }

            // generate a struct with each data type as a struct member
            const generated_struct_info = std.builtin.TypeInfo{ 
                .Struct = .{
                    .layout = .Extern, 
                    .fields = &new_type_fields,
                    .decls = &[_]std.builtin.TypeInfo.Declaration{},
                    .is_tuple = false,
                },
            };

            break :blk @Type(generated_struct_info);
        }
    };

    // !make sure to update this with verifyUniformBufferDescriptorConfig function!
    return struct {
        const Self = @This();

        shader_data: StorageType,

        // TODO: move runtime variables out of this config
        // runtime configuration
        allocator: *Allocator,
        ctx: Context, 
        image: stbi.Image, 
        uvs: []UV, 
        buffer_count: usize, 
        viewport: vk.Viewport,

        pub fn GetStorageType() type {
            return StorageType;
        }

        pub fn getTypeCount() comptime_int {
            return type_count;
        }
    };
}

// !make sure to update this with UniformBufferDescriptorConfig return struct!
/// use to supply compile time errors to caller when using incorrect config type
fn verifyUniformBufferDescriptorConfig(config: anytype) void {
    comptime {
        const config_type = @TypeOf(config);
        var is_correct = true;
        switch (@typeInfo(config_type)) {
            .Struct => {},
            else => is_correct = false,
        }
        if (!@hasField(config_type, "shader_data")) {
            is_correct = false;
        }
        if (!@hasField(config_type, "allocator")) {
            is_correct = false;
        }
        if (!@hasField(config_type, "ctx")) {
            is_correct = false;
        }
        if (!@hasField(config_type, "image")) {
            is_correct = false;
        }
        if (!@hasField(config_type, "uvs")) {
            is_correct = false;
        }
        if (!@hasField(config_type, "buffer_count")) {
            is_correct = false;
        }
        if (!@hasField(config_type, "viewport")) {
            is_correct = false;
        }
        
        if (!is_correct) {
            @compileError("config is not a UniformBufferDescriptorConfig type");
        }
    }
}

pub fn SyncUniformBuffer(comptime StorageType: type) type {
    const BufferDescriptor = UniformBufferDescriptor(StorageType); 

    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex,
        ubo: BufferDescriptor,

        pub fn init(config: anytype) !Self {
            verifyUniformBufferDescriptorConfig(config);
        
            const ubo = try BufferDescriptor.init(config);

            return Self{
                .mutex = .{},
                .ubo = ubo,
            };
        }

        pub fn deinit(self: Self, ctx: Context) void {
            self.ubo.deinit(ctx);
        }
    };
}

pub fn UniformBufferDescriptor(comptime StorageType: type) type {
    return struct {
        const Self = @This();
        
        allocator: *Allocator,

        uniform_data: UniformBuffer,
        uniform_buffers: []GpuBufferMemory,
        
        storage_data: StorageType,
        storage_buffers: [][]GpuBufferMemory,

        descriptor_set_layout: vk.DescriptorSetLayout,
        // wether a buffer is up to date everywhere according to changes with data
        is_dirty: []bool,
        descriptor_pool: vk.DescriptorPool,
        descriptor_sets: []vk.DescriptorSet,

        // TODO: seperate texture from UniformBuffer
        my_texture: Texture,

        // TODO: make the code more readable when it comes to init of storage buffer
        pub fn init(config: anytype) !Self {
            verifyUniformBufferDescriptorConfig(config);

            const uniform_data = UniformBuffer.init(config.viewport);
            
            const descriptor_set_layout = try createDescriptorSetLayout(config.ctx, StorageType);
            errdefer config.ctx.vkd.destroyDescriptorSetLayout(config.ctx.logical_device, descriptor_set_layout, null);

            var is_dirty = try config.allocator.alloc(bool, config.buffer_count);
            std.mem.set(bool, is_dirty, true);

            const descriptor_pool = try createUniformDescriptorPool(config.ctx, @TypeOf(config.shader_data), config.buffer_count);
            errdefer config.ctx.vkd.destroyDescriptorPool(config.ctx.logical_device, descriptor_pool, null);

            // use graphics and compute index
            // if they are the same, the we use that index
            const indices = [_]u32{ config.ctx.queue_indices.graphics, config.ctx.queue_indices.compute };
            const indices_len: usize = if (config.ctx.queue_indices.graphics == config.ctx.queue_indices.compute) 1 else 2;
        
            const PixelType = stbi.Pixel;
            const TextureConfig = texture.Config(PixelType);
            const texture_config = TextureConfig{
                .data = config.image.data, 
                .width = @intCast(u32, config.image.width),
                .height = @intCast(u32, config.image.height),
                .usage = .{ .transfer_dst_bit = true, .sampled_bit = true, .storage_bit = true  },
                .queue_family_indices = indices[0..indices_len],
                // TODO: this format is a storage format, but causes loaded texture to become lighter,
                // for compute texture we dont care about loading (transfer), so as long as computed output
                // account for unorm we should be good. Remove transfer functionality when we dont need it!
                .format = .r8g8b8a8_unorm, 
            };
            const my_texture = try Texture.init(config.ctx, config.ctx.gfx_cmd_pool, .general, PixelType, texture_config);
            errdefer my_texture.deinit(config.ctx);

            const uniform_buffers = try createShaderBuffers(
                config.allocator, 
                UniformBuffer,
                .{ .uniform_buffer_bit = true, }, 
                config.ctx, 
                config.buffer_count
            );
            errdefer {
                for (uniform_buffers) |buffer| {
                    buffer.deinit(config.ctx);
                }
                config.allocator.free(uniform_buffers);
            }

            var storage_buffers = try config.allocator.alloc([]GpuBufferMemory, config.buffer_count);
            errdefer config.allocator.free(storage_buffers);

            const shader_data_type = @TypeOf(config.shader_data);
            const shader_data_info: std.builtin.TypeInfo = @typeInfo(shader_data_type);
            for (storage_buffers) |*buffers| {
                buffers.* = try config.allocator.alloc(GpuBufferMemory, shader_data_info.Struct.fields.len);
                errdefer config.allocator.free(buffers.*);

                inline for (shader_data_info.Struct.fields) |field, i| {
                    const buffer_size = @sizeOf(field.field_type);
                    buffers.*[i] = try GpuBufferMemory.init(
                        config.ctx, 
                        buffer_size, 
                        .{ .storage_buffer_bit = true, }, 
                        .{ .host_visible_bit = true, .host_coherent_bit = true, }
                    );
                    errdefer buffers.*[i].deinit(config.ctx);
                }
            }

            const descriptor_sets = try createDescriptorSet(
                config.allocator,
                config.ctx,
                @TypeOf(config.shader_data),
                config.buffer_count,
                descriptor_set_layout,
                descriptor_pool,
                uniform_buffers,
                storage_buffers,
                my_texture.sampler,
                my_texture.image_view
            );
            errdefer config.allocator.free(descriptor_sets);

            return Self{
                .allocator = config.allocator,
                .uniform_data = uniform_data,
                .uniform_buffers = uniform_buffers,
                .storage_data = config.shader_data,
                .storage_buffers = storage_buffers,
                .descriptor_set_layout = descriptor_set_layout,
                .is_dirty = is_dirty,
                .descriptor_pool = descriptor_pool,
                .descriptor_sets = descriptor_sets,
                .my_texture = my_texture,
            };
        }

        pub inline fn translate_horizontal(self: *Self, value: f32) void {
            _ = value;
            // TODO: translate a distinct model instance instead?
            self.uniform_data.view.fields[0][3] += value;
            self.mark_dirty();
        }

        pub inline fn translate_vertical(self: *Self, value: f32) void {
            _ = value;
            self.uniform_data.view.fields[1][3] += value;
            self.mark_dirty();
        }

        pub inline fn mark_dirty(self: *Self) void {
            std.mem.set(bool, self.is_dirty, true);
        }

        pub fn deinit(self: Self, ctx: Context) void {
            self.my_texture.deinit(ctx);

            for(self.uniform_buffers) |buffer| {
                buffer.deinit(ctx);
            }
            self.allocator.free(self.uniform_buffers);

            for(self.storage_buffers) |buffers| {
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
}
    
// TODO: multiply projection and view on CPU (model is instanced (TODO) and has to be applied on GPU)
pub const UniformBuffer = extern struct {
    model: zlm.Mat4,
    view: zlm.Mat4,
    projection: zlm.Mat4,

    pub fn init(viewport: vk.Viewport) UniformBuffer {
        return .{
            .model = zlm.Mat4.createScale(viewport.height, viewport.height, 0.0),
            .view = zlm.Mat4.identity,
            .projection = blk: {
                const half_width  =  viewport.width  * 0.5;
                const half_height =  viewport.height * 0.5;
                const left:   f32 = -half_width;
                const right:  f32 =  half_width;
                const bottom: f32 =  half_height;
                const top:    f32 = -half_height;
                const z_near: f32 = -1000;
                const z_far:  f32 =  1000;
                break :blk zlm.Mat4.createOrthogonal(left, right, bottom, top, z_near, z_far);
            },
        };
    }
}; 

pub fn createDescriptorSetLayout(ctx: Context, comptime StorageType: type) !vk.DescriptorSetLayout {
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

    // TODO: this should be its own set!
    // if we have a buffer type included (ShaderTypes) we include it in layout binding as well
    const layout_bindings = comptime blk: {
        const types_info = @typeInfo(StorageType);
        const default_bindings = [_]vk.DescriptorSetLayoutBinding{ubo_layout_binding, sampler_layout_binding};
        switch (types_info) {
            .Void => break :blk default_bindings,
            .Struct => |struct_info| {
                var extra_layout_bindings: [struct_info.fields.len]vk.DescriptorSetLayoutBinding = undefined;
                inline for (struct_info.fields) |_, i| {
                    extra_layout_bindings[i] = .{
                        .binding = i + 2,
                        .descriptor_type = .storage_buffer,
                        .descriptor_count = 1,
                        .stage_flags = .{ .vertex_bit = true, },
                        .p_immutable_samplers = null,
                    };
                }
                break :blk default_bindings ++ extra_layout_bindings;
            },
            else => |@"type"| @compileError("expected void or struct, got" ++ @tagName(@"type")),
        }
    };
    const layout_info = vk.DescriptorSetLayoutCreateInfo{
        .flags = .{},
        .binding_count = layout_bindings.len,
        .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, &layout_bindings),
    };
    return ctx.vkd.createDescriptorSetLayout(ctx.logical_device, layout_info, null);
}

pub inline fn createUniformDescriptorPool(ctx: Context, comptime StorageType: type, swapchain_image_count: usize) !vk.DescriptorPool {
    const image_count = @intCast(u32, swapchain_image_count);
    const ubo_pool_size = vk.DescriptorPoolSize{
        .@"type" = .uniform_buffer,
        .descriptor_count = image_count,
    };
    const sampler_pool_size = vk.DescriptorPoolSize{
        .@"type" = .combined_image_sampler,
        .descriptor_count = image_count,
    };
    // TODO: refactor horrible complex code

    // if we have a buffer type included (ShaderTypes) we include it in layout binding as well
    var pool_sizes = comptime blk: {
        const types_info = @typeInfo(StorageType);
        switch (types_info) {
            .Void => break :blk [2]vk.DescriptorPoolSize{ },
            .Struct => |struct_info| {
                var all_storage_pool_sizes: [struct_info.fields.len + 2]vk.DescriptorPoolSize = undefined;
                inline for (struct_info.fields) |_, i| {
                    all_storage_pool_sizes[i + 2] = vk.DescriptorPoolSize{
                        .@"type" = .storage_buffer,
                        .descriptor_count = 0,
                    };
                }
                break :blk all_storage_pool_sizes;
            },
            else => |@"type"| @compileError("expected struct, got" ++ @tagName(@"type")),
        }
    };
    for (pool_sizes[2..]) |*size| {
        size.descriptor_count = image_count;
    }
    pool_sizes[0] = ubo_pool_size;
    pool_sizes[1] = sampler_pool_size;

    const pool_info = vk.DescriptorPoolCreateInfo{
        .flags = .{},
        .max_sets = image_count,
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = @ptrCast([*]const vk.DescriptorPoolSize, &pool_sizes),
    };
    return ctx.vkd.createDescriptorPool(ctx.logical_device, pool_info, null);
}

// TODO: update to reflect on config!
/// caller must make sure to destroy returned memory
pub fn createDescriptorSet(
    allocator: *Allocator, 
    ctx: Context,
    comptime StorageType: type, // type of storage buffer, may be void
    swapchain_image_count: usize, 
    set_layout: vk.DescriptorSetLayout, 
    pool: vk.DescriptorPool,
    uniform_buffers: []GpuBufferMemory,
    storage_buffers: [][]GpuBufferMemory,
    sampler: vk.Sampler,
    image_view: vk.ImageView
) ![]vk.DescriptorSet {
    if (uniform_buffers.len < swapchain_image_count) {
        return error.InsufficentUniformBuffer; // uniform buffer is of insufficent lenght
    }
    var set_layouts = try allocator.alloc(vk.DescriptorSetLayout, swapchain_image_count);
    defer allocator.free(set_layouts);
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
    errdefer allocator.free(sets);

    const storage_field_sizes = comptime blk: {
        const types_info: std.builtin.TypeInfo = @typeInfo(StorageType);
        switch (types_info) {
            .Void => break :blk [0]vk.DeviceSize{ },
            .Struct => |struct_info| {
                var field_sizes: [struct_info.fields.len]vk.DeviceSize = undefined;
                inline for (struct_info.fields) |field, i| {
                    field_sizes[i] = @sizeOf(field.field_type);
                }
                break :blk field_sizes;
            },
            else => |@"type"| @compileError("expected struct, got" ++ @tagName(@"type")),
        }
    };

    try ctx.vkd.allocateDescriptorSets(ctx.logical_device, alloc_info, sets.ptr);
    {
        var i: usize = 0;
        while(i < swapchain_image_count) : (i += 1) {
            // descriptor for uniform data
            const ubo_buffer_info = vk.DescriptorBufferInfo{
                .buffer = uniform_buffers[i].buffer,
                .offset = 0,
                .range = @sizeOf(UniformBuffer),
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

            // descriptor for image data
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

            var write_descriptor_sets: [storage_field_sizes.len + 2]vk.WriteDescriptorSet = undefined;
            write_descriptor_sets[0] = ubo_write_descriptor_set;
            write_descriptor_sets[1] = image_write_descriptor_set;
            inline for (storage_field_sizes) |sizeOf, j| {
                // descriptor for buffer info
                const storage_buffer_info = vk.DescriptorBufferInfo{
                    .buffer = storage_buffers[i][j].buffer,
                    .offset = 0,
                    .range = sizeOf,
                };
                const storage_write_descriptor_set = vk.WriteDescriptorSet{
                    .dst_set = sets[i],
                    .dst_binding = @intCast(u32, j + 2),
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_buffer,
                    .p_image_info = undefined,
                    .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &storage_buffer_info),
                    .p_texel_buffer_view = undefined,
                };
                write_descriptor_sets[j + 2] = storage_write_descriptor_set;
            }

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
pub inline fn createShaderBuffers(allocator: *Allocator, comptime StorageType: type, buf_usage_flags: vk.BufferUsageFlags, ctx: Context, count: usize) ![]GpuBufferMemory {
    const buffers = try allocator.alloc(GpuBufferMemory, count);
    errdefer allocator.free(buffers);

    const buffer_size = @sizeOf(StorageType);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        buffers[i] = try GpuBufferMemory.init(ctx, buffer_size, buf_usage_flags, .{ .host_visible_bit = true, .host_coherent_bit = true, });
    }
    errdefer {
        while (i >= 0) : (i -= 1) {
            buffers[i].deinit();
        }
    } 
    return buffers;
}
