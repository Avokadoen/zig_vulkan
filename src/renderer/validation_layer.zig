/// Functions related to validation layers and debug messaging 
const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const constants = @import("constants.zig");
const dispatch = @import("dispatch.zig");
const IoWriters = @import("context.zig").IoWriters;

fn InfoType() type {
    if (constants.enable_validation_layers) {
        return struct {
            const Self = @This();

            enabled_layer_count: u8,
            enabled_layer_names: [*]const [*:0]const u8,

            pub fn init(allocator: *Allocator, vkb: dispatch.Base) !Self {
                const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
                const is_valid = try isLayersPresent(allocator, vkb, validation_layers[0..validation_layers.len]);
                if (!is_valid) {
                    std.debug.panic("debug build without validation layer support", .{});
                }

                return Self{
                    .enabled_layer_count = validation_layers.len,
                    .enabled_layer_names = @ptrCast([*]const [*:0]const u8, &validation_layers),
                };
            }
        };
    } else {
        return struct {
            const Self = @This();

            enabled_layer_count: u8,
            enabled_layer_names: [*]const [*:0]const u8,

            pub fn init(allocator: *Allocator, vkb: dispatch.Base) !Self {
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
fn isLayersPresent(allocator: *Allocator, vkb: dispatch.Base, target_layers: []const [*:0]const u8) !bool {
    var layer_count: u32 = 0;
    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, null);

    var available_layers = try std.ArrayList(vk.LayerProperties).initCapacity(allocator, layer_count);
    defer available_layers.deinit();

    // TODO: handle vk.INCOMPLETE (Array too small)
    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, available_layers.items.ptr);
    available_layers.items.len = layer_count;

    for (target_layers) |target_layer| {
        // check if target layer exist in available_layers
        inner: for (available_layers.items) |available_layer| {
            const layer_name = available_layer.layer_name;
            // if target_layer and available_layer is the same
            if (std.cstr.cmp(target_layer, @ptrCast([*:0]const u8, &layer_name)) == 0) {
                break :inner;
            }
        } else return false; // if our loop never break, then a requested layer is missing
    }

    return true;
}

pub fn messageCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT.IntType,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT.IntType,
    p_callback_data: *const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: *c_void,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = message_types;

    const writers = @ptrCast(*IoWriters, @alignCast(@alignOf(*IoWriters), p_user_data));
    const error_mask = comptime blk: {
        break :blk vk.DebugUtilsMessageSeverityFlagsEXT{
            .warning_bit_ext = true,
            .error_bit_ext = true,
        };
    };
    const is_severe = error_mask.toInt() & message_severity > 0;
    const writer = if (is_severe) writers.stderr.* else writers.stdout.*;

    writer.print("validation layer: {s}\n", .{p_callback_data.p_message}) catch {
        std.debug.print("error from stdout print in message callback", .{});
    };

    return vk.FALSE;
}
