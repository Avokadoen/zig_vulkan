const std = @import("std");

const vk = @import("vulkan");

const Context = @import("Context.zig");

pub const bytes_in_mb = 1024 * 1024;

pub inline fn nonCoherentAtomSize(ctx: Context, size: vk.DeviceSize) vk.DeviceSize {
    const atom_size = ctx.physical_device_properties.limits.non_coherent_atom_size;
    return atom_size * (std.math.divCeil(vk.DeviceSize, size, atom_size) catch unreachable);
}
