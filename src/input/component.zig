const zglfw = @import("zglfw");
const za = @import("zalgebra");
const event_argument = @import("event_argument.zig");

pub const ImguiContext = struct {
    hand: *zglfw.Cursor,
    arrow: *zglfw.Cursor,
    ibeam: *zglfw.Cursor,
    crosshair: *zglfw.Cursor,
    resize_ns: *zglfw.Cursor,
    resize_ew: *zglfw.Cursor,
    resize_nesw: *zglfw.Cursor,
    resize_nwse: *zglfw.Cursor,
    not_allowed: *zglfw.Cursor,
};

// TODO: remove VecN from component
pub const UserInput = struct {
    activate_sprint: bool,
    call_translate: u8,
    camera_translate: za.Vec3,
    call_yaw: bool,
    call_pitch: bool,
    mouse_delta: za.Vec2,
    mouse_ignore_frames: u32,
};

pub const PrevCursorPos = struct {
    event: event_argument.CursorPosEvent,
};

pub const MenuActiveTag = struct {};
