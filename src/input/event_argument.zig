const zglfw = @import("zglfw");
const Key = zglfw.Key;
const Action = zglfw.Action;
const Mods = zglfw.Mods;
const MouseButton = zglfw.MouseButton;

const VoxelRT = @import("../VoxelRT.zig");

pub const Update = struct {
    window: *zglfw.Window,
    voxel_rt: *VoxelRT,
    dt: f32,
};

pub const KeyEvent = struct {
    window: *zglfw.Window,
    key: Key,
    action: Action,
    mods: Mods,
};

pub const MouseButtonEvent = struct {
    button: MouseButton,
    action: Action,
    mods: Mods,
};

pub const CursorPosEvent = struct {
    x: f64,
    y: f64,
};

pub const CharEvent = struct {
    codepoint: u21,
};

pub const ScrollEvent = struct {
    offset_x: f32,
    offset_y: f32,
};
