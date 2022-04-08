const std = @import("std");
const Allocator = std.mem.Allocator;

const glfw = @import("glfw");

pub const WindowHandle = glfw.Window.Handle;
pub const Key = glfw.Key;
pub const Action = glfw.Action;
pub const Mods = glfw.Mods;
pub const MouseButton = glfw.mouse_button.MouseButton;
pub const InputModeCursor = glfw.Window.InputModeCursor;

// TODO: use callbacks for easier key binding
// const int scancode = glfwGetKeyScancode(GLFW_KEY_X);
// set_key_mapping(scancode, swap_weapons);

pub const KeyEvent = struct {
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

pub const KeyHandleFn = fn (KeyEvent) void;
pub const MouseButtonHandleFn = fn (MouseButtonEvent) void;
pub const CursorPosHandleFn = fn (CursorPosEvent) void;

const WindowContext = struct {
    key_handle_fn: KeyHandleFn,
    mouse_btn_handle_fn: MouseButtonHandleFn,
    cursor_pos_handle_fn: CursorPosHandleFn,
};

const Input = @This();

window: glfw.Window,
window_context: *WindowContext,

/// !This will set the glfw window user context!
/// create a input module.
pub fn init(
    allocator: Allocator,
    input_window: glfw.Window,
    input_handle_fn: KeyHandleFn,
    input_mouse_btn_handle_fn: MouseButtonHandleFn,
    input_cursor_pos_handle_fn: CursorPosHandleFn,
) !Input {
    const window = input_window;
    const window_context = try allocator.create(WindowContext);
    window_context.* = .{
        .key_handle_fn = input_handle_fn,
        .mouse_btn_handle_fn = input_mouse_btn_handle_fn,
        .cursor_pos_handle_fn = input_cursor_pos_handle_fn,
    };

    try window.setInputMode(glfw.Window.InputMode.cursor, InputModeCursor.normal);

    _ = window.setKeyCallback(keyCallback);
    _ = window.setMouseButtonCallback(mouseBtnCallback);
    _ = window.setCursorPosCallback(cursorPosCallback);
    window.setUserPointer(@ptrCast(?*anyopaque, window_context));

    return Input{
        .window = window,
        .window_context = window_context,
    };
}

/// kill input module
pub fn deinit(self: Input, allocator: Allocator) void {
    self.window.setUserPointer(null);
    allocator.destroy(self.window_context);

    // unregister callback functions
    _ = self.window.setKeyCallback(null);
    _ = self.window.setMouseButtonCallback(null);
    _ = self.window.setCursorPosCallback(null);
}

pub fn setInputModeCursor(self: Input, mode: InputModeCursor) !void {
    try self.window.setInputModeCursor(mode);
}

pub fn setCursorPosCallback(self: Input, input_cursor_pos_handle_fn: CursorPosHandleFn) void {
    self.window_context.cursor_pos_handle_fn = input_cursor_pos_handle_fn;
}

// TODO: generic wrapper?
/// sends key events to a the key event to the input stream for further handling
/// Params:
///     - window	    The window that received the event.
///     - key	        The keyboard key that was pressed or released.
///     - scan_code	    The system-specific scancode of the key.
///     - action	    GLFW_PRESS, GLFW_RELEASE or GLFW_REPEAT. Future releases may add more actions.
///     - mod	        Bit field describing which modifier keys were held down.
fn keyCallback(window: glfw.Window, key: Key, scan_code: i32, action: Action, mods: Mods) void {
    _ = scan_code;

    var owned_mods = mods;
    var parsed_mods = @ptrCast(*Mods, &owned_mods);
    const event = KeyEvent{
        .key = key,
        .action = action,
        .mods = parsed_mods.*,
    };
    const context = if (window.getUserPointer(WindowContext)) |some| some else return;
    context.key_handle_fn(event);
}

fn mouseBtnCallback(window: glfw.Window, button: MouseButton, action: Action, mods: Mods) void {
    var owned_mods = mods;
    var parsed_mods = @ptrCast(*Mods, &owned_mods);
    const event = MouseButtonEvent{
        .button = button,
        .action = action,
        .mods = parsed_mods.*,
    };
    const context = if (window.getUserPointer(WindowContext)) |some| some else return;
    context.mouse_btn_handle_fn(event);
}

fn cursorPosCallback(window: glfw.Window, x_pos: f64, y_pos: f64) void {
    const event = CursorPosEvent{
        .x = x_pos,
        .y = y_pos,
    };
    const context = if (window.getUserPointer(WindowContext)) |some| some else return;
    context.cursor_pos_handle_fn(event);
}
