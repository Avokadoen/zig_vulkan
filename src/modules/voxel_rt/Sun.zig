pub const Config = struct {
    enabled: bool = true,
    position: ?[3]f32 = null,
    color: [3]f32 = [_]f32{ 1, 1.1, 1 },
    intensity: f32 = 1.0,
};

pub const Device = extern struct {
    position: [3]f32,
    enabled: u32,
    color: [3]f32,
    intensity: f32,
};

const Sun = @This();

device_data: Device,

pub fn init(voxel_dim_y: u32, config: Config) Sun {
    const position = config.position orelse [_]f32{ 0, -@intToFloat(f32, voxel_dim_y) * 2, 0 };
    return Sun{ .device_data = .{
        .enabled = @intCast(u32, @boolToInt(config.enabled)),
        .position = position,
        .color = config.color,
        .intensity = config.intensity,
    } };
}
