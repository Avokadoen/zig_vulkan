pub const Config = struct {
    enabled: bool = true,
    position: ?[3]f32 = null,
    color: [3]f32 = [_]f32{ 1, 1.1, 1 },
};

pub const Device = extern struct {
    position: [3]f32,
    enabled: u32,
    color: [3]f32,
    padding2: u32 = 0,
};

const Sun = @This();

device_data: Device,

pub fn init(enabled: bool, position: [3]f32, color: [3]f32) Sun {
    return Sun{ .device_data = .{
        .enabled = @intCast(u32, @boolToInt(enabled)),
        .position = position,
        .color = color,
    } };
}
