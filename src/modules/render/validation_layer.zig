/// Functions related to validation layers and debug messaging
const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const constants = @import("consts.zig");
const dispatch = @import("dispatch.zig");

fn InfoType() type {
    if (constants.enable_validation_layers) {
        return struct {
            const Self = @This();

            enabled_layer_count: u8,
            enabled_layer_names: [*]const [*:0]const u8,

            pub fn init(allocator: Allocator, vkb: dispatch.Base) !Self {
                const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
                const is_valid = try isLayersPresent(allocator, vkb, validation_layers[0..validation_layers.len]);
                if (!is_valid) {
                    std.debug.panic("debug build without validation layer support", .{});
                }

                return Self{
                    .enabled_layer_count = validation_layers.len,
                    .enabled_layer_names = @ptrCast(&validation_layers),
                };
            }
        };
    } else {
        return struct {
            const Self = @This();

            enabled_layer_count: u8,
            enabled_layer_names: [*]const [*:0]const u8,

            pub fn init(allocator: Allocator, vkb: dispatch.Base) !Self {
                _ = allocator;
                _ = vkb;
                return Self{
                    .enabled_layer_count = 0,
                    .enabled_layer_names = undefined,
                };
            }
        };
    }
}
pub const Info = InfoType();

/// check if validation layer exist
fn isLayersPresent(allocator: Allocator, vkb: dispatch.Base, target_layers: []const [*:0]const u8) !bool {
    var layer_count: u32 = 0;
    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, null);

    var available_layers = try std.ArrayList(vk.LayerProperties).initCapacity(allocator, layer_count);
    defer available_layers.deinit();

    // TODO: handle vk.INCOMPLETE (Array too small)
    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, available_layers.items.ptr);
    available_layers.items.len = layer_count;

    for (target_layers) |target_layer| {
        const t_str_len = std.mem.indexOfScalar(u8, target_layer[0..vk.MAX_EXTENSION_NAME_SIZE], 0) orelse continue;
        // check if target layer exist in available_layers
        inner: for (available_layers.items) |available_layer| {
            const layer_name = available_layer.layer_name;
            const l_str_len = std.mem.indexOfScalar(u8, layer_name[0..vk.MAX_EXTENSION_NAME_SIZE], 0) orelse continue;

            // if target_layer and available_layer is the same
            if (std.mem.eql(u8, target_layer[0..t_str_len], layer_name[0..l_str_len])) {
                break :inner;
            }
        } else return false; // if our loop never break, then a requested layer is missing
    }

    return true;
}

pub fn messageCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = p_user_data;
    _ = message_types;

    const error_mask = comptime blk: {
        break :blk vk.DebugUtilsMessageSeverityFlagsEXT{
            .warning_bit_ext = true,
            .error_bit_ext = true,
        };
    };
    const is_severe = (error_mask.toInt() & message_severity.toInt()) > 0;
    const writer = if (is_severe) std.io.getStdErr().writer() else std.io.getStdOut().writer();
    if (p_callback_data) |data| {
        const msg = data.p_message orelse "";
        writer.print("validation layer: {s}\n", .{msg}) catch {
            std.debug.print("error from stdout print in message callback", .{});
        };
    }

    return vk.FALSE;
}
