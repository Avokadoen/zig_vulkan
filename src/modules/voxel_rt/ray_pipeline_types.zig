const vk = @import("vulkan");
const render = @import("../render.zig");
const Context = render.Context;

pub const RayBufferCursor = extern struct {
    /// how many rays that was written to the buffer in total
    max_index: c_int,
    /// where the last ray write occured
    cursor: c_int,
};

// Must be synced with assets\shaders\emit_primary_rays.comp Ray
pub const Ray = extern struct {
    origin: [3]f32,
    t_value: f32,
    direction: [3]f32,
};

pub const Dispatch2 = struct {
    x: u32,
    y: u32,
    pub fn init(ctx: Context) Dispatch2 {
        const device_properties = ctx.getPhysicalDeviceProperties();
        const dim_size = device_properties.limits.max_compute_work_group_invocations;
        const uniform_dim = @as(u32, @intFromFloat(@floor(@sqrt(@as(f64, @floatFromInt(dim_size))))));
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
