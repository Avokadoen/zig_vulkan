const std = @import("std");

const vk = @import("vulkan");

const Context = @import("Context.zig");

pub const bytes_in_mb = 1048576;

pub inline fn nonCoherentAtomSize(ctx: Context, size: vk.DeviceSize) vk.DeviceSize {
    return ctx.non_coherent_atom_size * (std.math.divCeil(vk.DeviceSize, size, ctx.non_coherent_atom_size) catch unreachable);
}
