/// conveiance functions for the codebase

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// TODO: don't use arraylist, just allocate slice with allocator
/// caller must deinit returned memory
pub fn readFile(allocator: Allocator, absolute_path: []const u8) !ArrayList(u8) {
    const file = try std.fs.openFileAbsolute(absolute_path, .{ .read = true });
    defer file.close();

    var reader = file.reader();
    const file_size = (try reader.context.stat()).size;
    var buffer = try ArrayList(u8).initCapacity(allocator, file_size);
    // set buffer len so that reader is aware of usable memory
    buffer.items.len = file_size;

    const read = try reader.readAll(buffer.items);
    if (read != file_size) {
        return error.DidNotReadWholeFile;
    }

    return buffer;
}
