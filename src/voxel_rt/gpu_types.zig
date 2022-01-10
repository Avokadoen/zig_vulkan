const std = @import("std");
const Vec3 = @Vector(3, f32);
const Vec4 = @Vector(4, f32);

pub const BufferConfig = @import("../render/pipeline.zig").ComputeDrawPipeline.BufferConfig;

// storage value that hold the binidng value in shader, and size of a given type
const MapValue = struct {
    binding: u32,
    size: u64,
};

// map of bindings ...
// unless you have some very specific reason to read code under this comment i advise you to scroll up ... :)
const type_binding_map = std.ComptimeStringMap(MapValue, .{
    // 0 is target texture
    // skip camera for now (hard coded uniform in pipeline)
    // .{ mapEntryFromType(Camera) },
    .{ @typeName(Node), MapValue{ .binding = 2, .size = @sizeOf(Node) } },
    .{ @typeName(Material), MapValue{ .binding = 3, .size = @sizeOf(Material) } },
    .{ @typeName(Albedo), MapValue{ .binding = 4, .size = @sizeOf(Albedo) } },
    .{ @typeName(Metal), MapValue{ .binding = 5, .size = @sizeOf(Metal) } },
    .{ @typeName(Dielectric), MapValue{ .binding = 6, .size = @sizeOf(Dielectric) } },
    .{ @typeName(Floats), MapValue{ .binding = 7, .size = @sizeOf(Floats) } },
    .{ @typeName(Ints), MapValue{ .binding = 8, .size = @sizeOf(Ints) } },
});

// get all BufferConfig objects generated from type_binding_map
pub fn allBufferConfigs() [type_binding_map.kvs.len]BufferConfig {
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

pub fn typeBinding(comptime T: type) u32 {
    return type_binding_map.get(@typeName(T)) orelse {
        @compileError(@typeName(T) ++ " not part of shader types");
    };
}

pub fn typeBufferIndex(comptime T: type) u32 {
    return typeBinding(T) - 2;
}

// Camera uniform is defined in Camera.zig

// storage buffer, binding: 3
/// Materials define how a ray should interact with a given voxel
pub const Material = extern struct {
    /// Type is the main attribute of a material and define reflection and refraction behaviour
    pub const Type = enum(i32) {
        /// normal diffuse material
        lambertian,
        /// shiny material with fuzz
        metal,
        /// glass and other see through material
        dielectric,
    };

    @"type": Type,
    /// index in the type array
    /// i.e: type = material, type_index = 0 points to index 0 in metal array
    type_index: i32,
    /// index to the color of the voxel
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
pub const Floats = extern struct {
    min_point: Vec4,
    scale: f32,
    inv_scale: f32,
    inv_cell_count: f32,
};

// storage buffer, binding: 8
pub const Ints = extern struct {
    max_depth: i32,
    max_iter: i32,
    cell_count: i32,
};

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
