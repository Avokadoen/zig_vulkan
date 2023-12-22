const vk = @import("vulkan");
const render = @import("../render.zig");
const Context = render.Context;

// Must be synced with assets/shaders/ray_commons.comp Ray
pub const RayHitLimits = extern struct {
    // How many hit records were emitted by the emit stage for the current frame
    emitted_hit_count: c_uint,
    // How many hit records that are processed by the traverse stage
    in_hit_count: c_uint,
    // How many hits was registered during traverse stage
    out_hit_count: c_uint,
    // How many misses was registered during traverse stage
    out_miss_count: c_uint,
};

// must be kept in sync with assets/shaders/raytracing/traverse_rays.comp BrickGridState
pub const BrickGridMetadata = extern struct {
    /// how many bricks in each axis
    dim: [3]f32,
    padding1: f32,

    min_point: [3]f32,
    scale: f32,
};
// must be kept in sync with assets/shaders/raytracing/ray_commons.glsl BRICK_STATUS_BITS ... etc
pub const BrickIndex = packed struct {
    pub const Status = enum(u2) {
        unloaded = 0,
        loading = 1,
        unloading = 2,
        loaded = 3,
    };
    status: Status,
    request_count: u8,
    index: u22,
};
pub const Brick = packed struct {
    solid_mask: u512,
};

// must be kept in sync with assets/shaders/raytracing/ray_commons.glsl BrickRequest
pub const BrickRequest = extern struct {
    index: c_uint,
};
// must be kept in sync with assets/shaders/raytracing/ray_commons.glsl BrickLimits
pub const BrickLimits = extern struct {
    // Written by host
    max_load_request_count: c_uint,
    // How many bricks have been requested so far
    load_request_count: c_uint,
    // Written by host
    max_unload_request_count: c_uint,
    // How many bricks have been requested so far
    unload_request_count: c_uint,
    // How many active bricks can we have
    max_active_bricks: c_uint,
    // How many active bricks do we have
    active_bricks: c_int,
};
// must be kept in sync with assets/shaders/brick_streaming/brick_load_handling.comp
pub const BrickLoadRequest = extern struct {
    /// Index to the index entry for this brick load
    brick_index_index: c_uint, // :)
    /// Index to the brick in the brick buffer
    brick_index_32b: c_uint,
};

// must be kept in sync with assets/shaders/raytracing/ray_commons.glsl Ray
pub const Ray = extern struct {
    origin: [3]f32,
    internal_reflection: f32,
    direction: [3]f32,
    t_value: f32,
};
// must be kept in sync with assets/shaders/raytracing/ray_commons.glsl RayHit
pub const RayHit = extern struct {
    normal_4b_and_material_index_28b: c_uint,
};
// must be kept in sync with assets/shaders/raytracing/ray_commons.glsl RayShading
pub const RayShading = extern struct {
    color: [3]f32,
    pixel_coord: c_uint,
};
// must be kept in sync with assets/shaders/raytracing/ray_commons.glsl RayHash
pub const RayHash = extern struct {
    value: c_uint,
};

pub const Dispatch1D = extern struct {
    x: c_uint,

    pub fn init(ctx: Context) Dispatch1D {
        const device_properties = ctx.getPhysicalDeviceProperties();
        const dim_size = device_properties.limits.max_compute_work_group_invocations;
        return Dispatch1D{ .x = dim_size };
    }
};

pub const Dispatch2D = extern struct {
    x: c_uint,
    y: c_uint,

    pub fn init(ctx: Context) Dispatch2D {
        const device_properties = ctx.getPhysicalDeviceProperties();
        const dim_size = device_properties.limits.max_compute_work_group_invocations;
        const uniform_dim = @as(u32, @intFromFloat(@floor(@sqrt(@as(f64, @floatFromInt(dim_size))))));
        return Dispatch2D{
            .x = uniform_dim,
            // TODO: change based on NVIDIA vs AMD vs Others?
            .y = uniform_dim / 2,
        };
    }
};

pub const ImageInfo = struct {
    width: f32,
    height: f32,
    image: vk.Image,
    sampler: vk.Sampler,
    image_view: vk.ImageView,
};
