const std = @import("std");

const glfw = @import("glfw");

pub const WindowHandle = glfw.Window.Handle;
pub const Key = glfw.Key;
pub const Action = glfw.Action;
pub const Mods = glfw.Mods;
pub const MouseButton = glfw.mouse_button.MouseButton;

// TODO: use callbacks for easier key binding
// const int scancode = glfwGetKeyScancode(GLFW_KEY_X);
// set_key_mapping(scancode, swap_weapons);

var key_handle_fn: KeyHandleFn = undefined;
var mouse_btn_handle_fn: MouseButtonHandleFn = undefined;
var cursor_pos_handle_fn: CursorPosHandleFn = undefined;

var window: glfw.Window = undefined;

pub fn init(input_window: glfw.Window, input_handle_fn: KeyHandleFn, input_mouse_btn_handle_fn: MouseButtonHandleFn, input_cursor_pos_handle_fn: CursorPosHandleFn) !void {
    window = input_window;

    key_handle_fn = input_handle_fn;
    mouse_btn_handle_fn = input_mouse_btn_handle_fn;
    cursor_pos_handle_fn = input_cursor_pos_handle_fn;

    try window.setInputMode(glfw.Window.InputMode.cursor, glfw.Window.InputModeCursor.normal);

    _ = window.setKeyCallback(keyCallback);
    _ = window.setMouseButtonCallback(mouseBtnCallback);
    _ = window.setCursorPosCallback(cursorPosCallback);
}

/// kill input module
pub fn deinit() void {
    // unregister callback functions
    _ = window.setKeyCallback(null);
    _ = window.setMouseButtonCallback(null);
    _ = window.setCursorPosCallback(null);
}

// TODO: generic wrapper?
/// sends key events to a the key event to the input stream for further handling
/// Params:
///     - window	    The window that received the event.
///     - key	        The keyboard key that was pressed or released.
///     - scan_code	    The system-specific scancode of the key.
///     - action	    GLFW_PRESS, GLFW_RELEASE or GLFW_REPEAT. Future releases may add more actions.
///     - mod	        Bit field describing which modifier keys were held down.
fn keyCallback(_window: glfw.Window, key: Key, scan_code: i32, action: Action, mods: Mods) void {
    _ = _window;
    _ = scan_code;

    var owned_mods = mods;
    var parsed_mods = @ptrCast(*Mods, &owned_mods);
    const event = KeyEvent{
        .key = key,
        .action = action,
        .mods = parsed_mods.*,
    };

    key_handle_fn(event);
}

fn mouseBtnCallback(_window: glfw.Window, button: MouseButton, action: Action, mods: Mods) void {
    _ = _window;

    var owned_mods = mods;
    var parsed_mods = @ptrCast(*Mods, &owned_mods);
    const event = MouseButtonEvent{
        .button = button,
        .action = action,
        .mods = parsed_mods.*,
    };
    mouse_btn_handle_fn(event);
}

fn cursorPosCallback(_window: glfw.Window, x_pos: f64, y_pos: f64) void {
    _ = _window;

    const event = CursorPosEvent{
        .x = x_pos,
        .y = y_pos,
    };
    cursor_pos_handle_fn(event);
}

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
