const vk = @import("vulkan");
const GpuBufferMemory = @import("gpu_buffer_memory.zig").GpuBufferMemory;
const Context = @import("context.zig").Context;

pub const Vertex = struct {
    pos: [2]f32, 
};

pub const Index = u32;

/// caller must make sure to call deinit
/// Create a default vertex buffer for the graphics pipeline 
pub inline fn createDefaultVertexBuffer(ctx: Context, command_pool: vk.CommandPool) !GpuBufferMemory {
    var vertices = [_]Vertex{ 
        .{ .pos = .{-1.0, -1.0 } },
        .{ .pos = .{ 1.0, -1.0 } },
        .{ .pos = .{ 1.0,  1.0 } },
        .{ .pos = .{-1.0,  1.0 } },
    };
    const buffer_size = @sizeOf(Vertex) * vertices.len;
    var staging_buffer = try GpuBufferMemory.init(
        ctx, 
        buffer_size, 
        .{ .transfer_src_bit = true, }, 
        .{ .host_visible_bit = true, .host_coherent_bit = true, } 
    );
    defer staging_buffer.deinit();
    try staging_buffer.bind();
    // zig type inference is failing, so cast is needed currently
    try staging_buffer.transferData(Vertex, @as([]Vertex, vertices[0..])); 

    var vertex_buffer = try GpuBufferMemory.init(
        ctx, 
        buffer_size, 
        .{ .transfer_dst_bit = true, .vertex_buffer_bit = true, }, 
        .{ .device_local_bit = true, }
    );
    try vertex_buffer.bind();
    try staging_buffer.copyBuffer(&vertex_buffer, buffer_size, command_pool);
    return vertex_buffer;
}

pub inline fn createDefaultIndicesBuffer(ctx: Context, command_pool: vk.CommandPool) !GpuBufferMemory {
    var indices = [_]Index{  
        0, 1, 2, // triangle 0
        2, 3, 0  // triangle 1
    };
    const buffer_size = @sizeOf(Index) * indices.len;
    var staging_buffer = try GpuBufferMemory.init(
        ctx, 
        buffer_size, 
        .{ .transfer_src_bit = true, }, 
        .{ .host_visible_bit = true, .host_coherent_bit = true, } 
    );
    defer staging_buffer.deinit();
    try staging_buffer.bind();
    // zig type inference is failing, so cast is needed currently
    try staging_buffer.transferData(Index, @as([]Index, indices[0..])); 

    var index_buffer = try GpuBufferMemory.init(
        ctx, 
        buffer_size, 
        .{ .transfer_dst_bit = true, .index_buffer_bit = true, }, 
        .{ .device_local_bit = true, }
    );
    try index_buffer.bind();
    try staging_buffer.copyBuffer(&index_buffer, buffer_size, command_pool);
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

pub inline fn getAttribureDescriptions() [1]vk.VertexInputAttributeDescription {
    return [_]vk.VertexInputAttributeDescription{
        .{
            .location = 0,
            .binding = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
    };
}

