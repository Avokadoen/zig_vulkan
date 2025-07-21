const std = @import("std");

const vk = @import("vulkan");

const context = @import("context.zig");

pub const bytes_in_mb = 1024 * 1024;

pub inline fn nonCoherentAtomSize(physical_device_properties: context.components.PhysicalDeviceProperties, size: vk.DeviceSize) vk.DeviceSize {
    const atom_size = physical_device_properties.limits.non_coherent_atom_size;
    return atom_size * (std.math.divCeil(vk.DeviceSize, size, atom_size) catch unreachable);
}
