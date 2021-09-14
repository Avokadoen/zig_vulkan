const vk = @import("vulkan");
const za = @import("zalgebra");

const GpuBufferMemory = @import("gpu_buffer_memory.zig").GpuBufferMemory;
const Context = @import("context.zig").Context;

pub const Index = u32;

pub const Vertex = struct {
    pos: za.Vec2,
    uv: za.Vec2,
};

/// caller must make sure to call deinit
/// Create a default vertex buffer for the graphics pipeline 
pub inline fn createDefaultVertexBuffer(ctx: Context, command_pool: vk.CommandPool) !GpuBufferMemory {
    var vertices = [_]Vertex{
        Vertex { 
            .pos = za.Vec2.new(-0.5, -0.5), 
            .uv = za.Vec2.new(1.0, 1.0) 
        }, // bottom left
        Vertex { 
            .pos = za.Vec2.new(0.5, -0.5), 
            .uv = za.Vec2.new(0.0, 1.0) 
        }, // bottom right
        Vertex { 
            .pos = za.Vec2.new(-0.5, 0.5), 
            .uv = za.Vec2.new(1.0, 0.0) 
        }, // top left
        Vertex { 
            .pos = za.Vec2.new(0.5, 0.5), 
            .uv = za.Vec2.new(0.0, 0.0) 
        }, // top right
    };
    const buffer_size = @sizeOf(Vertex) * vertices.len;
    var staging_buffer = try GpuBufferMemory.init(
        ctx, 
        buffer_size, 
        .{ .transfer_src_bit = true, }, 
        .{ .host_visible_bit = true, .host_coherent_bit = true, } 
    );
    defer staging_buffer.deinit(ctx);
    // zig type inference is failing, so cast is needed currently
    try staging_buffer.transferData(ctx, Vertex, @as([]Vertex, vertices[0..])); 

    var vertex_buffer = try GpuBufferMemory.init(
        ctx, 
        buffer_size, 
        .{ .transfer_dst_bit = true, .vertex_buffer_bit = true, }, 
        .{ .device_local_bit = true, }
    );
    try staging_buffer.copyBuffer(ctx, &vertex_buffer, buffer_size, command_pool);
    return vertex_buffer;
}

pub inline fn createDefaultIndicesBuffer(ctx: Context, command_pool: vk.CommandPool) !GpuBufferMemory {
    var indices = [_]Index{  
        0, 1, 2, // triangle 0
        2, 1, 3  // triangle 1
    };
    const buffer_size = @sizeOf(Index) * indices.len;
    var staging_buffer = try GpuBufferMemory.init(
        ctx, 
        buffer_size, 
        .{ .transfer_src_bit = true, }, 
        .{ .host_visible_bit = true, .host_coherent_bit = true, } 
    );
    defer staging_buffer.deinit(ctx);
    // zig type inference is failing, so cast is needed currently
    try staging_buffer.transferData(ctx, Index, @as([]Index, indices[0..])); 

    var index_buffer = try GpuBufferMemory.init(
        ctx, 
        buffer_size, 
        .{ .transfer_dst_bit = true, .index_buffer_bit = true, }, 
        .{ .device_local_bit = true, }
    );
    try staging_buffer.copyBuffer(ctx, &index_buffer, buffer_size, command_pool);
    return index_buffer;
}

/// Get default binding descriptor for pass 
pub inline fn getBindingDescriptors() [1]vk.VertexInputBindingDescription {
    return [_]vk.VertexInputBindingDescription{
        .{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .input_rate = .vertex,
        }
    };
}

pub inline fn getAttribureDescriptions() [2]vk.VertexInputAttributeDescription {
    return [_]vk.VertexInputAttributeDescription{
        .{
            .location = 0,
            .binding = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .location = 1,
            .binding = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "uv"),
        },
    };
}

