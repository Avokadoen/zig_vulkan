/// This file contains compiletime constants that are relevant for the renderer API.
const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");

// enable validation layer in debug
pub const enable_validation_layers = builtin.mode == .Debug;
pub const engine_name = "nop";
pub const engine_version = vk.makeApiVersion(0, 0, 1, 0);
pub const application_version = vk.makeApiVersion(0, 0, 1, 0);

const release_logical_device_extensions = [_][*:0]const u8{
    vk.extension_info.khr_swapchain.name,
    vk.extension_info.ext_shader_atomic_float.name,
};
const debug_logical_device_extensions = [_][*:0]const u8{vk.extension_info.khr_shader_non_semantic_info.name};
pub const logical_device_extensions = if (enable_validation_layers) release_logical_device_extensions ++ debug_logical_device_extensions else release_logical_device_extensions;

pub const required_float_atomics = vk.PhysicalDeviceShaderAtomicFloatFeaturesEXT{};

pub const max_frames_in_flight = 2;
