/// This file contains the vk Wrapper types used to call vulkan functions.
/// Wrapper is a vulkan-zig construct that generates compile time types that
/// links with vulkan functions depending on queried function requirements
/// see vk X_Command types for implementation details
const vk = @import("vulkan");

const consts = @import("consts.zig");

pub const Base = vk.BaseWrapper;

// TODO: manually loading functions we care about, not all
pub const Instance = vk.InstanceWrapper;

pub const Device = vk.DeviceWrapper;

pub const BeginCommandBufferError = Device.BeginCommandBufferError;
