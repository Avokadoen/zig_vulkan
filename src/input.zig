const std = @import("std");
const Thread = std.Thread;

const glfw = @import("glfw");

pub const WindowHandle = glfw.Window.Handle;
pub const Key = glfw.Key;
pub const Action = glfw.Action;
pub const Mods = glfw.Mods;
pub const MouseButton = glfw.mouse_button.MouseButton;

const vk = @import("vulkan");

// TODO: file issues on todos instead of using todos comments
// TODO: create a module for input so this can be multiple files
// TODO: input logic could use a small thread pool instead of unique dynamic threads for each
//       event type

const input_buffer_size = 16;

// input stream
var key_stream = KeyEventStream{
    .new_input_event = undefined,
    .mutex = .{},
    .len = 0,
    .buffer = undefined,
}; 

var mouse_btn_stream = MouseButtonEventStream{
    .new_input_event = undefined,
    .mutex = .{},
    .len = 0,
    .buffer = undefined,
};

var cursor_pos_stream = CursorPosEventStream{
    .new_input_event = undefined,
    .mutex = .{},
    .len = 0,
    .buffer = undefined,
};

var key_handle_fn: KeyHandleFn = undefined;
var mouse_btn_handle_fn: MouseButtonHandleFn = undefined;
var cursor_pos_handle_fn: CursorPosHandleFn = undefined;

var window: glfw.Window = undefined;
/// kills all input based threads running 
var kill_all_input_threads: bool = false;

var key_input_thread: std.Thread = undefined;
var mouse_btn_input_thread: std.Thread = undefined;
var cursor_pos_input_thread: std.Thread = undefined;

pub fn init(
    input_window: glfw.Window, 
    input_handle_fn: KeyHandleFn, 
    input_mouse_btn_handle_fn: MouseButtonHandleFn,
    input_cursor_pos_handle_fn: CursorPosHandleFn
) !void {
    window = input_window;
    
    key_handle_fn = input_handle_fn;
    try key_stream.new_input_event.init();

    mouse_btn_handle_fn = input_mouse_btn_handle_fn;
    try mouse_btn_stream.new_input_event.init();

    cursor_pos_handle_fn = input_cursor_pos_handle_fn;
    try cursor_pos_stream.new_input_event.init();

    try window.setInputMode(glfw.Window.InputMode.cursor, glfw.Window.InputModeCursor.normal);

    _ = window.setKeyCallback(keyCallback); 
    _ = window.setMouseButtonCallback(mouseBtnCallback);
    _ = window.setCursorPosCallback(cursorPosCallback);

    key_input_thread = try std.Thread.spawn(.{}, handleKeyboardInput, .{} );
    mouse_btn_input_thread = try std.Thread.spawn(.{}, handleMouseButtonInput, .{} );
    cursor_pos_input_thread = try std.Thread.spawn(.{}, handleCursorPosInput, .{} );
}


/// kill input module, this will make input threads shut down
pub fn deinit() void {
    // unregister callback functions
    _ = window.setKeyCallback(null);
    _ = window.setMouseButtonCallback(null);
    _ = window.setCursorPosCallback(null);

    // tell all threads to kill them self
    kill_all_input_threads = true;

    { // critical zone
        key_stream.mutex.lock();
        defer key_stream.mutex.unlock();

        // wake thread
        key_stream.new_input_event.set();
    }

    { // critical zone 
        mouse_btn_stream.mutex.lock();
        defer mouse_btn_stream.mutex.unlock();

        // wake thread
        mouse_btn_stream.new_input_event.set();
    }

    { // critical zone 
        cursor_pos_stream.mutex.lock();
        defer cursor_pos_stream.mutex.unlock(); 

        // wake thread
        cursor_pos_stream.new_input_event.set();
    }

    key_input_thread.join(); 
    mouse_btn_input_thread.join(); 
    cursor_pos_input_thread.join(); 
}

// TODO: generic?
/// function that user can spawn threads with to handle keyboard input
pub fn handleKeyboardInput() void {
    while(kill_all_input_threads == false) {
        // block loop progression if stream is inactive
        key_stream.new_input_event.wait();

        { // critical zone
            key_stream.mutex.lock();
            defer key_stream.mutex.unlock();

            while(key_stream.len > 0) : (key_stream.len -= 1){
                const event = key_stream.buffer[key_stream.len - 1];
                key_handle_fn(event);
            }
            key_stream.new_input_event.reset(); // event has to be reset in critical zone!
        }
    }
}

// TODO: generic?
/// function that user can spawn threads with to handle mouse button input
pub fn handleMouseButtonInput() void {
    while(kill_all_input_threads == false) {
        // block loop progression if stream is inactive
        mouse_btn_stream.new_input_event.wait();

        { // critical zone
            mouse_btn_stream.mutex.lock();
            defer mouse_btn_stream.mutex.unlock();

            while(mouse_btn_stream.len > 0) : (mouse_btn_stream.len -= 1){
                const event = mouse_btn_stream.buffer[mouse_btn_stream.len - 1];
                mouse_btn_handle_fn(event);
            }
            mouse_btn_stream.new_input_event.reset(); // event has to be reset in critical zone!
        }
    }
}

// TODO: generic?
/// function that user can spawn threads with to handle cursor pos input
pub fn handleCursorPosInput() void {
    while(kill_all_input_threads == false) {
        // block loop progression if stream is inactive
        cursor_pos_stream.new_input_event.wait();

        { // critical zone
            cursor_pos_stream.mutex.lock();
            defer cursor_pos_stream.mutex.unlock();

            while(cursor_pos_stream.len > 0) : (cursor_pos_stream.len -= 1){
                const event = cursor_pos_stream.buffer[cursor_pos_stream.len - 1];
                cursor_pos_handle_fn(event);
            }
            cursor_pos_stream.new_input_event.reset(); // event has to be reset in critical zone!
        }
    }
}

// TODO: use callbacks for easier key binding
// const int scancode = glfwGetKeyScancode(GLFW_KEY_X);
// set_key_mapping(scancode, swap_weapons);

// TODO: generic wrapper?
/// sends key events to a the key event to the input stream for further handling
/// Params:
///     - window	    The window that received the event.
///     - key	        The keyboard key that was pressed or released.
///     - scan_code	    The system-specific scancode of the key.
///     - action	    GLFW_PRESS, GLFW_RELEASE or GLFW_REPEAT. Future releases may add more actions.
///     - mod	        Bit field describing which modifier keys were held down.
fn keyCallback(_window: glfw.Window, key: Key, scan_code: isize, action: Action, mods: Mods) void {
    _ = _window;
    _ = scan_code;

    // if buffer is full
    if (key_stream.len >= key_stream.buffer.len) {
        return;
    }

    var owned_mods = mods;
    var parsed_mods = @ptrCast(*Mods, &owned_mods);
    const event = KeyEvent{
        .key = key,
        .action = action,
        .mods = parsed_mods.*,
    };

    { // critical zone
        key_stream.mutex.lock();
        defer key_stream.mutex.unlock();
        key_stream.buffer[key_stream.len] = event;
        key_stream.len += 1;
    }

    // wake up input thread(s)
    key_stream.new_input_event.set();
}

// TODO: generic wrapper?
fn mouseBtnCallback(_window: glfw.Window, button: MouseButton, action: Action, mods: Mods) void {
    _ = _window;

      // if buffer is full
    if (mouse_btn_stream.len >= mouse_btn_stream.buffer.len) {
        return;
    }

    var owned_mods = mods;
    var parsed_mods = @ptrCast(*Mods, &owned_mods);
    const event = MouseButtonEvent{
        .button = button,
        .action = action,
        .mods = parsed_mods.*,
    };

   { // critical zone
        mouse_btn_stream.mutex.lock();
        defer mouse_btn_stream.mutex.unlock();

        mouse_btn_stream.buffer[mouse_btn_stream.len] = event;
        mouse_btn_stream.len += 1;
    }

    // wake up input thread(s)
    mouse_btn_stream.new_input_event.set();
}

// TODO: generic?
fn cursorPosCallback(_window: glfw.Window, x_pos: f64, y_pos: f64) void {
    _ = _window;

      // if buffer is full
    if (cursor_pos_stream.len >= cursor_pos_stream.buffer.len) {
        return;
    }

    const event = CursorPosEvent{
        .x = x_pos,
        .y = y_pos,
    };

   { // critical zone
        cursor_pos_stream.mutex.lock();
        defer cursor_pos_stream.mutex.unlock();
        cursor_pos_stream.buffer[cursor_pos_stream.len] = event;
        cursor_pos_stream.len += 1;
    }

    // wake up input thread(s)
    cursor_pos_stream.new_input_event.set();
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

pub const KeyHandleFn = fn(KeyEvent) void;
pub const MouseButtonHandleFn = fn(MouseButtonEvent) void;
pub const CursorPosHandleFn = fn(CursorPosEvent) void;

// TODO: generic?
const KeyEventStream = struct {
    new_input_event: Thread.ResetEvent,
    mutex: Thread.Mutex,
    len: usize,
    buffer: [input_buffer_size]KeyEvent,
};

// TODO: generic?
const MouseButtonEventStream = struct {
    new_input_event: Thread.ResetEvent,
    mutex: Thread.Mutex,
    len: usize,
    buffer: [input_buffer_size]MouseButtonEvent,
};

// TODO: generic?
const CursorPosEventStream = struct {
    new_input_event: Thread.ResetEvent,
    mutex: Thread.Mutex,
    len: usize,
    buffer: [input_buffer_size]CursorPosEvent,
};

