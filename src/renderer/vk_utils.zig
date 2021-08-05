/// vk_utils contains utility functions for the vulkan API to reduce boiler plate

// TODO: most of these functions are only called once in the codebase, move to where they are
// relevant, and those who are only called in one file should be in that file

const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const dispatch = @import("dispatch.zig");

// TODO: support mixed types
/// Construct VkPhysicalDeviceFeatures type with VkFalse as default field value 
pub fn GetFalseFeatures(comptime T: type) type {
    const features_type_info = @typeInfo(T).Struct;
    var new_type_fields: [features_type_info.fields.len]std.builtin.TypeInfo.StructField = undefined;

    inline for (features_type_info.fields) |field, i| {
        new_type_fields[i] = field;
        new_type_fields[i].default_value = @intCast(u32, vk.FALSE);
    }

    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = &new_type_fields,
            .decls = &[_]std.builtin.TypeInfo.Declaration{},
            .is_tuple = false,
        },
    });
}

/// Check if extensions are available on host instance
pub fn isInstanceExtensionsPresent(allocator: *Allocator, vkb: dispatch.Base, target_extensions: []const [*:0]const u8) !bool {
    // query extensions available
    var supported_extensions_count: u32 = 0;
    // TODO: handle "VkResult.incomplete"
    _ = try vkb.enumerateInstanceExtensionProperties(null, &supported_extensions_count, null);

    var extensions = try std.ArrayList(vk.ExtensionProperties).initCapacity(allocator, supported_extensions_count);
    defer extensions.deinit();

    _ = try vkb.enumerateInstanceExtensionProperties(null, &supported_extensions_count, extensions.items.ptr);
    extensions.items.len = supported_extensions_count;

    var matches: u32 = 0;
    for (target_extensions) |target_extension| {
        cmp: for (extensions.items) |existing| {
            const existing_name = @ptrCast([*:0]const u8, &existing.extension_name);
            if (std.cstr.cmp(target_extension, existing_name) == 0) {
                matches += 1;
                break :cmp;
            }
        }
    }

    return matches == target_extensions.len;
}
