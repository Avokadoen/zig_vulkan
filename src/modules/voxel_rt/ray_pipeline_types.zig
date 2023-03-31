const vk = @import("vulkan");
const render = @import("../render.zig");
const Context = render.Context;

pub const RayBufferCursor = extern struct {
    /// how many rays that was written to the buffer in total
    total_written: c_int,
    /// where the last ray write occured
    cursor: c_int,

    pub const buffer_offset = 0;
};

// Must be synced with assets\shaders\emit_primary_rays.comp Ray
pub const Ray = extern struct {
    origin: [3]f32,
    internal_reflection: f32,
    direction: [3]f32,
    t_value: f32,
    color: [3]f32,
    pixel_coord: c_uint,
};

pub const Dispatch2 = struct {
    x: u32,
    y: u32,
    pub fn init(ctx: Context) Dispatch2 {
        const device_properties = ctx.getPhysicalDeviceProperties();
        const dim_size = device_properties.limits.max_compute_work_group_invocations;
        const uniform_dim = @floatToInt(u32, @floor(@sqrt(@intToFloat(f64, dim_size))));
        return Dispatch2{
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
