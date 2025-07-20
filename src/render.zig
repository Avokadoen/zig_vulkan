const ecez = @import("ecez");

/// library with utility wrappers around vulkan functions
pub const context = @import("render/context.zig");
/// Wrapper for vk buffer and memory to simplify handling of these in conjunction
pub const gpu_buffer_memory = @import("render/gpu_buffer_memory.zig");
/// Texture utilities
pub const texture = @import("render/texture.zig");

/// helper methods for handling of pipelines
pub const consts = @import("render/consts.zig");
pub const dispatch = @import("render/dispatch.zig");
pub const memory = @import("render/memory.zig");
pub const physical_device = @import("render/physical_device.zig");
pub const pipeline = @import("render/pipeline.zig");
pub const swapchain = @import("render/swapchain.zig");
pub const validation_layer = @import("render/validation_layer.zig");
pub const vk_utils = @import("render/vk_utils.zig");

pub fn CreateEvents(comptime Storage: type) type {
    return struct {
        pub const render_deinit = ecez.Event(
            "render_deinit",
            .{
                gpu_buffer_memory.systems.deinit.gpuBufferMemory,
                swapchain.systems.deinit.swapchainData,
                context.CreateSystems(Storage).deinit.context,
            },
            .{
                // systems might deinit components "independent" of eachother,
                // but from vulkan's perspective they may have a dependency
                .run_on_main_thread = true,
            },
        );
    };
}
