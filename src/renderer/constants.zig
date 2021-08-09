/// This file contains compiletime constants that are relevant for the renderer API.

const std = @import("std");
const vk = @import("vulkan");

// enable validation layer in debug
pub const enable_validation_layers = (std.builtin.mode == .Debug);
pub const engine_name = "nop";
pub const logicical_device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};
pub const max_frames_in_flight = 2;