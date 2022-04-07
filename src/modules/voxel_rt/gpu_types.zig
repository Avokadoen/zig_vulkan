const std = @import("std");
const Vec3 = @Vector(3, f32);
const Vec4 = @Vector(4, f32);

pub const BufferConfig = @import("../render.zig").ComputeDrawPipeline.BufferConfig;

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

// Camera uniform is defined in Camera.zig

// storage buffer, binding: 3
/// Materials define how a ray should interact with a given voxel
pub const Material = packed struct {
    /// Type is the main attribute of a material and define reflection and refraction behaviour
    pub const Type = enum(u2) {
        /// normal diffuse material
        lambertian = 0,
        /// shiny material with fuzz
        metal = 1,
        /// glass and other see through material
        dielectric = 2,
    };

    @"type": Type,
    /// index in the type array
    /// i.e: type = material, type_index = 0 points to index 0 in metal array
    type_index: u15,
    /// index to the color of the voxel
    albedo_index: u15,
};

// TODO: convert to push constants: Albedo, Metal, Dielectric

// storage buffer, binding: 4
pub const Albedo = extern struct {
    color: Vec4,
};

// storage buffer, binding: 5
pub const Metal = extern struct {
    fuzz: f32,
};

// storage buffer, binding: 6
pub const Dielectric = extern struct {
    internal_reflection: f32,
};

// storage buffer, binding: 7
pub const Floats = extern struct {
    min_point: Vec4,
    scale: f32,
    inv_scale: f32,
    inv_cell_count: f32,

    pub fn init(min_point: Vec3, scale: f32) Floats {
        return Floats{
            .min_point = [4]f32{ min_point[0], min_point[1], min_point[2], 0.0 },
            .scale = scale,
            .inv_scale = 1.0 / scale,
            .inv_cell_count = undefined,
        };
    }
};

// storage buffer, binding: 8
pub const Ints = extern struct {
    max_depth: i32,
    max_iter: i32,
    cell_count: i32,

    pub fn init(max_depth: i32, max_iter: i32) Ints {
        return Ints{
            .max_depth = max_depth,
            .max_iter = max_iter,
            .cell_count = undefined,
        };
    }
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
