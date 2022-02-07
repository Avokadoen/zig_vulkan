/// library with utility wrappers around vulkan functions
const pipelines = @import("render/pipeline.zig");

pub const ComputeDrawPipeline = pipelines.ComputeDrawPipeline;
pub const Context = @import("render/Context.zig");
pub const PipelineTypesFn = pipelines.PipelineTypesFn;
pub const GpuBufferMemory = @import("render/GpuBufferMemory.zig");
// TODO: don't directly export tb data
pub const Vertex = vertex.Vertex;

pub const descriptor = @import("render/descriptor.zig");
pub const consts = @import("render/consts.zig");
pub const dispatch = @import("render/dispatch.zig");
pub const physical_device = @import("render/physical_device.zig");
pub const swapchain = @import("render/swapchain.zig");
pub const Texture = @import("render/Texture.zig");
pub const validation_layer = @import("render/validation_layer.zig");
pub const vertex = @import("render/vertex.zig");
pub const vk_utils = @import("render/vk_utils.zig");
