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
pub const Material = extern struct {
    /// Type is the main attribute of a material and define reflection and refraction behaviour
    pub const Type = enum(u32) {
        /// normal diffuse material
        lambertian = 0,
        /// shiny material with fuzz
        metal = 1,
        /// glass and other see through material
        dielectric = 2,
    };

    type: Type,
    albedo_r: f32,
    albedo_g: f32,
    albedo_b: f32,
    type_data: f32,
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
