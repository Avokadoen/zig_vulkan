const std = @import("std");
const Vec3 = @Vector(3, f32);
const Vec4 = @Vector(4, f32);

pub const BufferConfig = @import("../render.zig").ComputeDrawPipeline.BufferConfig;

// storage value that hold the binidng value in shader, and size of a given type
const MapValue = struct {
    binding: u32,
    size: u64,
};

// Camera uniform is defined in Camera.zig

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

    type: Type,
    /// index in the type array
    /// i.e: type = material, type_index = 0 points to index 0 in metal array
    type_index: u6,
    /// index to the color of the voxel
    albedo_index: u8,
};

pub const Albedo = extern struct {
    color: [4]f32,
};

pub const Metal = extern struct {
    fuzz: f32,
};

pub const Dielectric = extern struct {
    internal_reflection: f32,
};

pub const Node = extern struct {
    pub const Type = enum(u32) {
        empty = 0,
        parent,
        leaf,
    };

    type: Type,
    value: u32,
};
