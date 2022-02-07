const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// zig fmt: off
/// A vox file
pub const Vox = struct { 
    allocator: Allocator,
    version_number: i32, 
    nodes: ArrayList(ChunkNode), 
    generic_chunks: ArrayList(Chunk), 
    pack_chunk: Chunk.Pack, 
    size_chunks: []Chunk.Size, 
    xyzi_chunks: [][]Chunk.XyziElement,
    rgba_chunk: [256]Chunk.RgbaElement,

    pub fn init(allocator: Allocator) Vox {
        return Vox{
            .allocator = allocator,
            // if you enable strict parsing in the load function, then this will be validated in validateHeader 
            .version_number = 150,
            .nodes = ArrayList(ChunkNode).init(allocator),
            .generic_chunks = ArrayList(Chunk).init(allocator),
            .pack_chunk = undefined,
            .size_chunks = undefined,
            .xyzi_chunks = undefined,
            .rgba_chunk = undefined,
        };
    }

    pub fn deinit(self: Vox) void {
        for (self.xyzi_chunks) |chunk| {
            self.allocator.free(chunk);
        } 

        self.allocator.free(self.size_chunks);
        self.allocator.free(self.xyzi_chunks);

        self.nodes.deinit();
        self.generic_chunks.deinit();
    }
};
// zig fmt: on

pub const ChunkNode = struct {
    type_id: Chunk.Type,
    generic_index: usize,
    index: usize,
};

/// Generic Chunk and all Chunk types
pub const Chunk = struct {

    /// num bytes of chunk content 
    size: i32,
    /// num bytes of children chunks
    child_size: i32,

    pub const Type = enum { main, pack, size, xyzi, rgba };

    pub const Pack = struct {
        /// num of SIZE and XYZI chunks
        num_models: i32,
    };

    pub const Size = struct {
        size_x: i32,
        size_y: i32,
        /// gravity direction in vox ...
        size_z: i32,
    };

    pub const XyziElement = packed struct {
        x: u8,
        y: u8,
        z: u8,
        color_index: u8,
    };

    // * <NOTICE>
    // * color [0-254] are mapped to palette index [1-255], e.g :
    //
    // for ( int i = 0; i <= 254; i++ ) {
    //     palette[i + 1] = ReadRGBA();
    // }
    pub const RgbaElement = packed struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    // Extension chunks below

    // pub const Material = struct {
    //     pub const Type = enum {
    //         diffuse,
    //         metal,
    //         glass,
    //         emit
    //     };

    //     @"type": Type,

    // }
};
