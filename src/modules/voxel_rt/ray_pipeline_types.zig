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
pub const BrickGridState = extern struct {
    /// how many bricks in each axis
    dim: [3]f32,
    padding1: f32,

    min_point: [3]f32,
    scale: f32,
};
pub const BrickIndex = packed struct {
    pub const Status = enum(u1) {
        unloaded = 0,
        loaded = 1,
    };
    status: Status,
    request_count: u7,
    index: u24,
};
// must be kept in sync with assets/shaders/raytracing/ray_commons.glsl BrickRequest
pub const BrickRequest = extern struct {
    index: c_uint,
};
pub const Brick = packed struct {
    solid_mask: u512,
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
