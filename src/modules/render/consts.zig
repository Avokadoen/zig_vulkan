/// This file contains compiletime constants that are relevant for the renderer API.
const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");

// enable validation layer in debug
pub const enable_validation_layers = builtin.mode == .Debug;
pub const engine_name = "nop";
pub const engine_version = vk.makeApiVersion(0, 0, 1, 0);
pub const application_version = vk.makeApiVersion(0, 0, 1, 0);

pub const vulkan_version = vk.API_VERSION_1_4;

const release_logical_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
};

pub const logical_device_extensions = init_device_ext_blk: {
    if (enable_validation_layers) {
        break :init_device_ext_blk release_logical_device_extensions;
    } else {
        break :init_device_ext_blk release_logical_device_extensions;
    }
};

pub const max_frames_in_flight = 2;
