/// library with utility wrappers around vulkan functions
const context = @import("context.zig");
const pipelines = @import("pipeline.zig");
const tb = @import("transform_buffer.zig");

pub const ComputePipeline = pipelines.ComputePipeline;
pub const Context = context.Context;
pub const Pipeline2D = pipelines.Pipeline2D;
pub const GpuBufferMemory = @import("gpu_buffer_memory.zig").GpuBufferMemory;
// TODO: don't directly export tb data
pub const UniformBufferDescriptorConfig = tb.UniformBufferDescriptorConfig;
pub const SyncUniformBuffer = tb.SyncUniformBuffer;
pub const TransformBuffer = tb.UniformBuffer;
pub const UniformBufferDescriptor = tb.UniformBufferDescriptor;
pub const UV = tb.UV; 
pub const Vertex = vertex.Vertex;
pub const Writers = context.IoWriters;

pub const consts = @import("consts.zig");
pub const dispatch = @import("dispatch.zig");
pub const physical_device = @import("physical_device.zig");
pub const swapchain = @import("swapchain.zig");
pub const texture = @import("texture.zig");
pub const validation_layer = @import("validation_layer.zig");
pub const vertex = @import("vertex.zig");
pub const vk_utils = @import("vk_utils.zig");

