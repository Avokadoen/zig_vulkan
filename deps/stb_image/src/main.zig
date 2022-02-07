const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;
const c = @import("c.zig");

pub const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

/// Utility wrapper for stb_load functions
pub const Image = struct {
    width: i32,
    height: i32,
    channels: i32,
    data: []Pixel,

    // TODO: remove comptime keyword -> // TODO: acount for any channel type
    /// Caller must call deinit to free created memory
    pub fn from_file(allocator: Allocator, path: []const u8, comptime desired_channels: DesiredChannels) !Image {
        const use_path = try buildPath(allocator, path);
        defer allocator.destroy(use_path.ptr);
        // TODO: acount for any channel type
        if (desired_channels != DesiredChannels.STBI_rgb_alpha) {
            @compileError("unimplemented channel type, expected " ++ @tagName(DesiredChannels.STBI_rgb_alpha) ++ ", found " ++ @tagName(desired_channels));
        }

        var width: i32 = undefined;
        var height: i32 = undefined;
        var channels: i32 = undefined;
        const char_ptr = c.stbi_load(use_path.ptr, &width, &height, &channels, @enumToInt(desired_channels));
        if (char_ptr == null) {
            return error.FailedToLoadImage; // Only error scenario here is failed to open file descriptor
        }
        // TODO: account for any channel type
        if (channels != 3) {
            std.debug.panic("got image with unimplemented channel count: {d}", .{channels});
        }

        const char_slice = std.mem.span(char_ptr);
        const aligned_char_ptr = std.mem.alignPointer(char_slice.ptr, 8);
        if (aligned_char_ptr == null) {
            return error.PtrNotAligned; // failed to align char pointer as a pixel pointer
        }

        const pixel_ptr = @ptrCast([*]Pixel, aligned_char_ptr);

        const pixel_count = @intCast(usize, width * height);
        return Image{
            .width = width,
            .height = height,
            .channels = channels,
            .data = pixel_ptr[0..pixel_count],
        };
    }

    pub fn save_write_png(self: Image, allocator: Allocator, path: []const u8) !void {
        const use_path = try buildPath(allocator, path);
        defer allocator.destroy(use_path.ptr);

        const char_ptr = std.mem.alignPointer(self.data.ptr, 2);

        const error_code = c.stbi_write_png(use_path.ptr, self.width, self.height, self.channels, char_ptr, self.width * self.channels);
        if (error_code == 0) {
            return error.StbiFailedWrite; // error scenarios are not specified :(
        }
    }

    pub fn deinit(self: Image) void {
        c.stbi_image_free(self.data.ptr);
    }
};

/// Enum defined by stb_image
pub const DesiredChannels = enum(c_int) {
    STBI_default = 0, // only used for desired_channels

    STBI_grey = 1,
    STBI_grey_alpha = 2,
    STBI_rgb = 3,
    STBI_rgb_alpha = 4,
};

inline fn buildPath(allocator: Allocator, path: []const u8) ![:0]u8 {
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const exe_path = try std.fs.selfExeDirPath(buf[0..]);
    const path_segments = [_][]const u8{ exe_path, path };

    var zig_use_path = try std.fs.path.join(allocator, path_segments[0..]);
    defer allocator.destroy(zig_use_path.ptr);

    const sep = [_]u8{std.fs.path.sep};
    _ = std.mem.replace(u8, zig_use_path, "\\", sep[0..], zig_use_path);
    _ = std.mem.replace(u8, zig_use_path, "/", sep[0..], zig_use_path);

    return try std.cstr.addNullByte(allocator, zig_use_path);
}

// TODO: TESTING!
// test "basic add functionality" {
//     try testing.expect(add(3, 7) == 10);
// }
