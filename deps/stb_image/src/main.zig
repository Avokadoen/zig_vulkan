const std = @import("std");
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
    pub fn init(allocator: *std.mem.Allocator, path: []const u8, comptime desired_channels: DesiredChannels) !Image {
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const exe_path = try std.fs.selfExeDirPath(buf[0..]);
        const path_segments = [_][]const u8{exe_path, path};

        var zig_use_path = try std.fs.path.join(allocator, path_segments[0..]);
        defer allocator.destroy(zig_use_path.ptr);

        const sep = [_]u8{ std.fs.path.sep };
        _ = std.mem.replace(u8, zig_use_path, "\\", sep[0..], zig_use_path);
        _ = std.mem.replace(u8, zig_use_path, "/", sep[0..], zig_use_path);

        const use_path = try std.cstr.addNullByte(allocator, zig_use_path);
        defer allocator.destroy(use_path.ptr);
        // TODO: acount for any channel type
        if(desired_channels != DesiredChannels.STBI_rgb_alpha) {
            const error_msg = std.fmt.comptimePrint("unimplemented channel type, expected {d}, found {d}", .{DesiredChannels.STBI_rgb_alpha, desired_channels});
            @compileError(error_msg);
        }

        var width: i32 = undefined;
        var height: i32 = undefined;
        var channels: i32 = undefined;
        const char_ptr = c.stbi_load(use_path.ptr, &width, &height, &channels, @enumToInt(desired_channels)); 
        if (char_ptr == null) {
            return error.FailedToLoadImage; // Only error scenario here is failed to open file descriptor
        }
        // TODO: acount for any channel type
        if (channels != 3) {
            std.debug.panic("got image with unimplemented channel count: {d}", .{channels});
        }

        const char_slice = std.mem.span(char_ptr);
        const aligned_char_ptr = std.mem.alignPointer(char_slice.ptr, 8);
        const pixel_ptr = @ptrCast([*]Pixel, aligned_char_ptr);

        const pixel_count = @intCast(usize, width * height);
        return Image {
            .width = width,
            .height = height,
            .channels = channels,
            .data = pixel_ptr[0..pixel_count],
        };
    }

    pub fn deinit(self: Image) void {
        c.stbi_image_free(self.data.ptr);
    }
};

/// Enum defined by stb_image
pub const DesiredChannels = enum(c_int) {
    STBI_default = 0, // only used for desired_channels

    STBI_grey       = 1,
    STBI_grey_alpha = 2,
    STBI_rgb        = 3,
    STBI_rgb_alpha  = 4
};

// TODO: TESTING!
// test "basic add functionality" {
//     try testing.expect(add(3, 7) == 10);
// }
