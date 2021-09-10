const vk = @import("vulkan");

pub const Vertex = struct {
    pos: [2]f32, 
};

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
