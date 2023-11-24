const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const Vox = types.Vox;
const Chunk = types.Chunk;

/// VOX loader implemented according to VOX specification: https://github.com/ephtracy/voxel-model/blob/master/MagicaVoxel-file-format-vox.txt
pub fn load(comptime strict: bool, allocator: Allocator, path: []const u8) !Vox {
    const file = blk: {
        const use_path = try buildPath(allocator, path);
        defer allocator.free(use_path);
        break :blk try std.fs.openFileAbsolute(use_path, .{});
    };
    defer file.close();

    const file_buffer = blk: {
        const size = (try file.stat()).size;
        // + 1 to check if read is successfull
        break :blk try allocator.alloc(u8, size + 1);
    };
    defer allocator.free(file_buffer);

    const bytes_read = try file.readAll(file_buffer);
    if (file_buffer.len <= bytes_read) {
        return error.InsufficientBuffer;
    }

    return parseBuffer(strict, allocator, file_buffer);
}

pub const ParseError = error{
    InvalidId,
    ExpectedSizeHeader,
    ExpectedXyziHeader,
    ExpectedRgbaHeader,
    UnexpectedVersion,
    InvalidFileContent,
    MultiplePackChunks,
};
pub fn parseBuffer(comptime strict: bool, allocator: Allocator, buffer: []const u8) !Vox {
    if (strict == true) {
        try validateHeader(buffer);
    }

    var vox = Vox.init(allocator);
    errdefer vox.deinit();

    // insert main node
    try vox.generic_chunks.append(try chunkFrom(buffer[8..]));
    try vox.nodes.append(.{
        .type_id = .main,
        .generic_index = 0,
        .index = 0,
    });

    // id (4) + chunk size (4) + child size (4)
    const chunk_stride = 4 * 3;
    // skip main chunk
    var pos: usize = 8 + chunk_stride;

    // Parse pack_chunk if any
    if (buffer[pos] == 'P') {
        // parse generic chunk
        try vox.generic_chunks.append(try chunkFrom(buffer[pos..]));
        pos += chunk_stride;

        // Parse pack
        vox.pack_chunk = Chunk.Pack{
            .num_models = parseI32(buffer[pos..]),
        };
        pos += 4;
    } else {
        vox.pack_chunk = Chunk.Pack{
            .num_models = 1,
        };
    }
    try vox.nodes.append(.{
        .type_id = .pack,
        .generic_index = 0,
        .index = 0,
    });

    const num_models = @as(usize, @intCast(vox.pack_chunk.num_models));
    // allocate voxel data according to pack information
    vox.size_chunks = try allocator.alloc(Chunk.Size, num_models);
    vox.xyzi_chunks = try allocator.alloc([]Chunk.XyziElement, num_models);

    // TODO: pos will cause out of bounds easily, make code more robust!
    for (0..num_models) |model_index| {
        // parse SIZE chunk
        {
            if (strict) {
                if (!std.mem.eql(u8, buffer[pos .. pos + 4], "SIZE")) {
                    return ParseError.ExpectedSizeHeader;
                }
            }

            // parse generic chunk
            try vox.generic_chunks.append(try chunkFrom(buffer[pos..]));
            pos += chunk_stride;

            const size = Chunk.Size{
                .size_x = parseI32(buffer[pos..]),
                .size_y = parseI32(buffer[pos + 4 ..]),
                .size_z = parseI32(buffer[pos + 8 ..]),
            };
            pos += 12;
            vox.size_chunks[model_index] = size;
            try vox.nodes.append(.{
                .type_id = .size,
                .generic_index = vox.generic_chunks.items.len,
                .index = model_index,
            });
        }

        // parse XYZI chunk
        {
            if (strict) {
                if (!std.mem.eql(u8, buffer[pos .. pos + 4], "XYZI")) {
                    return ParseError.ExpectedXyziHeader;
                }
            }

            // parse generic chunk
            try vox.generic_chunks.append(try chunkFrom(buffer[pos..]));
            pos += chunk_stride;

            const voxel_count: usize = @intCast(parseI32(buffer[pos..]));
            pos += 4;

            const xyzis = try allocator.alloc(Chunk.XyziElement, voxel_count);
            {
                for (0..voxel_count) |voxel_index| {
                    xyzis[voxel_index].x = buffer[pos];
                    xyzis[voxel_index].y = buffer[pos + 1];
                    xyzis[voxel_index].z = buffer[pos + 2];
                    xyzis[voxel_index].color_index = buffer[pos + 3];
                    pos += 4;
                }
            }
            vox.xyzi_chunks[model_index] = xyzis;
            try vox.nodes.append(.{
                .type_id = .xyzi,
                .generic_index = vox.generic_chunks.items.len,
                .index = model_index,
            });
        }
    }

    var rgba_set: bool = false;
    while (pos < buffer.len) {
        // Parse potential extensions and RGBA
        switch (buffer[pos]) {
            'R' => {
                // check if it is probable that there is a RGBA chunk remaining
                if (strict) {
                    if (!std.mem.eql(u8, buffer[pos .. pos + 4], "RGBA")) {
                        return ParseError.ExpectedRgbaHeader;
                    }
                }
                // parse generic chunk
                try vox.generic_chunks.append(try chunkFrom(buffer[pos..]));
                pos += chunk_stride;

                vox.rgba_chunk[0] = Chunk.RgbaElement{
                    .r = 0,
                    .g = 0,
                    .b = 0,
                    .a = 1,
                };
                for (1..255) |chunk_index| {
                    vox.rgba_chunk[chunk_index] = Chunk.RgbaElement{
                        .r = buffer[pos],
                        .g = buffer[pos + 1],
                        .b = buffer[pos + 2],
                        .a = buffer[pos + 3],
                    };
                    pos += 4;
                }
                rgba_set = true;
            },
            else => {
                // skip bytes
                pos += 4;
            },
        }
    }

    if (rgba_set == false) {
        const default = @as(*const [256]Chunk.RgbaElement, @ptrCast(&default_rgba));
        std.mem.copy(Chunk.RgbaElement, vox.rgba_chunk[0..], default[0..]);
    }

    return vox;
}

inline fn parseI32(buffer: []const u8) i32 {
    return @as(*const i32, @ptrCast(@alignCast(&buffer[0]))).*;
}

/// Parse a buffer into a chunk, buffer *has* to start with the first character in the id
inline fn chunkFrom(buffer: []const u8) std.fmt.ParseIntError!Chunk {
    const size = parseI32(buffer[4..]);
    const child_size = parseI32(buffer[8..]);

    return Chunk{
        .size = size,
        .child_size = child_size,
    };
}

inline fn validateHeader(buffer: []const u8) ParseError!void {
    if (std.mem.eql(u8, buffer[0..4], "VOX ") == false) {
        return error.InvalidId; // Vox format should start with "VOX "
    }

    const version = buffer[4];
    if (version != 150) {
        return error.UnexpectedVersion; // Expect version 150
    }

    if (std.mem.eql(u8, buffer[8..12], "MAIN") == false) {
        return error.InvalidFileContent; // Missing main chunk in file
    }
}

inline fn buildPath(allocator: Allocator, path: []const u8) ![]const u8 {
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const exe_path = try std.fs.selfExeDirPath(buf[0..]);
    const path_segments = [_][]const u8{ exe_path, path };

    var zig_use_path = try std.fs.path.join(allocator, path_segments[0..]);
    errdefer allocator.destroy(zig_use_path.ptr);

    const sep = [_]u8{std.fs.path.sep};
    _ = std.mem.replace(u8, zig_use_path, "\\", sep[0..], zig_use_path);
    _ = std.mem.replace(u8, zig_use_path, "/", sep[0..], zig_use_path);

    return zig_use_path;
}

const default_rgba = [256]u32{
    0x00000000, 0xffffffff, 0xffccffff, 0xff99ffff, 0xff66ffff, 0xff33ffff, 0xff00ffff, 0xffffccff, 0xffccccff, 0xff99ccff, 0xff66ccff, 0xff33ccff, 0xff00ccff, 0xffff99ff, 0xffcc99ff, 0xff9999ff,
    0xff6699ff, 0xff3399ff, 0xff0099ff, 0xffff66ff, 0xffcc66ff, 0xff9966ff, 0xff6666ff, 0xff3366ff, 0xff0066ff, 0xffff33ff, 0xffcc33ff, 0xff9933ff, 0xff6633ff, 0xff3333ff, 0xff0033ff, 0xffff00ff,
    0xffcc00ff, 0xff9900ff, 0xff6600ff, 0xff3300ff, 0xff0000ff, 0xffffffcc, 0xffccffcc, 0xff99ffcc, 0xff66ffcc, 0xff33ffcc, 0xff00ffcc, 0xffffcccc, 0xffcccccc, 0xff99cccc, 0xff66cccc, 0xff33cccc,
    0xff00cccc, 0xffff99cc, 0xffcc99cc, 0xff9999cc, 0xff6699cc, 0xff3399cc, 0xff0099cc, 0xffff66cc, 0xffcc66cc, 0xff9966cc, 0xff6666cc, 0xff3366cc, 0xff0066cc, 0xffff33cc, 0xffcc33cc, 0xff9933cc,
    0xff6633cc, 0xff3333cc, 0xff0033cc, 0xffff00cc, 0xffcc00cc, 0xff9900cc, 0xff6600cc, 0xff3300cc, 0xff0000cc, 0xffffff99, 0xffccff99, 0xff99ff99, 0xff66ff99, 0xff33ff99, 0xff00ff99, 0xffffcc99,
    0xffcccc99, 0xff99cc99, 0xff66cc99, 0xff33cc99, 0xff00cc99, 0xffff9999, 0xffcc9999, 0xff999999, 0xff669999, 0xff339999, 0xff009999, 0xffff6699, 0xffcc6699, 0xff996699, 0xff666699, 0xff336699,
    0xff006699, 0xffff3399, 0xffcc3399, 0xff993399, 0xff663399, 0xff333399, 0xff003399, 0xffff0099, 0xffcc0099, 0xff990099, 0xff660099, 0xff330099, 0xff000099, 0xffffff66, 0xffccff66, 0xff99ff66,
    0xff66ff66, 0xff33ff66, 0xff00ff66, 0xffffcc66, 0xffcccc66, 0xff99cc66, 0xff66cc66, 0xff33cc66, 0xff00cc66, 0xffff9966, 0xffcc9966, 0xff999966, 0xff669966, 0xff339966, 0xff009966, 0xffff6666,
    0xffcc6666, 0xff996666, 0xff666666, 0xff336666, 0xff006666, 0xffff3366, 0xffcc3366, 0xff993366, 0xff663366, 0xff333366, 0xff003366, 0xffff0066, 0xffcc0066, 0xff990066, 0xff660066, 0xff330066,
    0xff000066, 0xffffff33, 0xffccff33, 0xff99ff33, 0xff66ff33, 0xff33ff33, 0xff00ff33, 0xffffcc33, 0xffcccc33, 0xff99cc33, 0xff66cc33, 0xff33cc33, 0xff00cc33, 0xffff9933, 0xffcc9933, 0xff999933,
    0xff669933, 0xff339933, 0xff009933, 0xffff6633, 0xffcc6633, 0xff996633, 0xff666633, 0xff336633, 0xff006633, 0xffff3333, 0xffcc3333, 0xff993333, 0xff663333, 0xff333333, 0xff003333, 0xffff0033,
    0xffcc0033, 0xff990033, 0xff660033, 0xff330033, 0xff000033, 0xffffff00, 0xffccff00, 0xff99ff00, 0xff66ff00, 0xff33ff00, 0xff00ff00, 0xffffcc00, 0xffcccc00, 0xff99cc00, 0xff66cc00, 0xff33cc00,
    0xff00cc00, 0xffff9900, 0xffcc9900, 0xff999900, 0xff669900, 0xff339900, 0xff009900, 0xffff6600, 0xffcc6600, 0xff996600, 0xff666600, 0xff336600, 0xff006600, 0xffff3300, 0xffcc3300, 0xff993300,
    0xff663300, 0xff333300, 0xff003300, 0xffff0000, 0xffcc0000, 0xff990000, 0xff660000, 0xff330000, 0xff0000ee, 0xff0000dd, 0xff0000bb, 0xff0000aa, 0xff000088, 0xff000077, 0xff000055, 0xff000044,
    0xff000022, 0xff000011, 0xff00ee00, 0xff00dd00, 0xff00bb00, 0xff00aa00, 0xff008800, 0xff007700, 0xff005500, 0xff004400, 0xff002200, 0xff001100, 0xffee0000, 0xffdd0000, 0xffbb0000, 0xffaa0000,
    0xff880000, 0xff770000, 0xff550000, 0xff440000, 0xff220000, 0xff110000, 0xffeeeeee, 0xffdddddd, 0xffbbbbbb, 0xffaaaaaa, 0xff888888, 0xff777777, 0xff555555, 0xff444444, 0xff222222, 0xff111111,
};

test "validateHeader: valid header accepted" {
    const valid_test_buffer: []const u8 = "VOX " ++ [_]u8{ 150, 0, 0, 0 } ++ "MAIN";

    try validateHeader(valid_test_buffer);
}

test "validateHeader: invalid id detected" {
    const invalid_test_buffer: []const u8 = "!VOX" ++ [_]u8{ 150, 0, 0, 0 } ++ "MAIN";

    try std.testing.expectError(ParseError.InvalidId, validateHeader(invalid_test_buffer));
}

test "validateHeader: invalid version detected" {
    const invalid_test_buffer: []const u8 = "VOX " ++ [_]u8{ 169, 0, 0, 0 } ++ "MAIN";

    try std.testing.expectError(ParseError.UnexpectedVersion, validateHeader(invalid_test_buffer));
}
