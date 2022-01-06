const std = @import("std");
const Vec3 = @Vector(3, f32);
const Vec4 = @Vector(4, f32);

pub const BufferConfig = @import("../render/pipeline.zig").ComputeDrawPipeline.BufferConfig;

// get all BufferConfig objects generated from type_binding_map
pub fn getAllBufferConfigs() [type_binding_map.kvs.len]BufferConfig {
    // TODO: assign a buffer size for each type ..
    comptime var buffer_config: [type_binding_map.kvs.len]BufferConfig = undefined;
    inline for (type_binding_map.kvs) |type_binding, i| {
        buffer_config[i] = BufferConfig{
            .size = type_binding.value.size,
            .constant = false, // TODO
        };
    }
    return buffer_config;
}

pub fn getTypeBinding(comptime T: type) u32 {
    return type_binding_map.get(@typeName(T)) orelse @compileError(@typeName(T) ++ " not part of shader types");
}

// Camera uniform is defined in Camera.zig

// storage buffer, binding: 2
pub const Node = extern struct {
    pub const Type = enum(u32) {
        empty = 0,
        parent,
        leaf,
    };

    @"type": Type,
    value: u32,
};

// storage buffer, binding: 3
pub const Material = extern struct {
    pub const Type = enum(i32) {
        lambertian,
        metal,
        dielectric,
    };

    @"type": Type,
    attribute_index: i32,
    albedo_index: i32,
};

// TODO: convert to push constants: Albedo, Metal, Dielectric

// storage buffer, binding: 4
pub const Albedo = extern struct { value: Vec3 };

// storage buffer, binding: 5
pub const Metal = extern struct {
    fuzz: f32,
};

// storage buffer, binding: 6
pub const Dielectric = extern struct {
    ir: f32,
};

// storage buffer, binding: 7
pub const OctreeFloats = extern struct {
    min_point: Vec4,
    scale: f32,
    inv_scale: f32,
    inv_cell_count: f32,
};

// storage buffer, binding: 8
pub const OctreeInts = extern struct {
    max_depth: i32,
    max_iter: i32,
    cell_count: i32,
};

// map of bindings ...
// unless you have some very specific reason to read code under this comment i advise you to scroll up ... :)
const type_binding_map = std.ComptimeStringMap(MapValue, .{
    // 0 is target texture
    // skip camera for now (hard coded uniform in pipeline)
    // .{ mapEntryFromType(Camera) },
    mapEntryFromType(Node, 2),
    mapEntryFromType(Material, 3),
    mapEntryFromType(Albedo, 4),
    mapEntryFromType(Metal, 5),
    mapEntryFromType(Dielectric, 6),
    mapEntryFromType(OctreeFloats, 7),
    mapEntryFromType(OctreeInts, 8),
});

// storage value that hold the binidng value in shader, and size of a given type
const MapValue = struct {
    binding: u32,
    size: u64,
};

fn mapEntryFromType(comptime T: type, comptime binding: u32) @TypeOf(.{ @typeName(T), MapValue{ .binding = binding, .size = @sizeOf(T) } }) {
    return .{ @typeName(T), MapValue{ .binding = binding, .size = @sizeOf(T) } };
}
