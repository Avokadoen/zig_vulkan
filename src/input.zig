const std = @import("std");
const Thread = std.Thread;

const glfw = @import("glfw");
const g_key = glfw.key;
const g_action = glfw.action;
const g_mod = glfw.mod;
const g_mouse_button = glfw.mouse_button;

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

    try window.setInputMode(glfw.Window.InputMode.cursor, glfw.cursor_disabled);

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
        var lock = key_stream.mutex.acquire();
        defer lock.release();

        // wake thread
        key_stream.new_input_event.set();
    }

    { // critical zone 
        var lock = mouse_btn_stream.mutex.acquire();
        defer lock.release();

        // wake thread
        mouse_btn_stream.new_input_event.set();
    }

    { // critical zone 
        var lock = cursor_pos_stream.mutex.acquire();
        defer lock.release();

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
            var lock = key_stream.mutex.acquire();
            defer lock.release();
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
            var lock = mouse_btn_stream.mutex.acquire();
            defer lock.release();
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
            var lock = cursor_pos_stream.mutex.acquire();
            defer lock.release();
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
fn keyCallback(_window: ?*glfw.RawWindow, key: c_int, scan_code: c_int, action: c_int, mods: c_int) callconv(.C) void {
    _ = _window;
    _ = scan_code;

    // if buffer is full
    if (key_stream.len >= key_stream.buffer.len) {
        return;
    }

    var owned_mods = mods;
    var parsed_mods = @ptrCast(*Mods, &owned_mods);
    const event = KeyEvent{
        .key = @intToEnum(Key, key),
        .action = @intToEnum(Action, action),
        .mods = parsed_mods.*,
    };

    { // critical zone
        const lock = key_stream.mutex.acquire();
        defer lock.release();
        key_stream.buffer[key_stream.len] = event;
        key_stream.len += 1;
    }

    // wake up input thread(s)
    key_stream.new_input_event.set();
}

// TODO: generic wrapper?
fn mouseBtnCallback(_window: ?*glfw.RawWindow, button: c_int, action: c_int, mods: c_int) callconv(.C) void {
    _ = _window;

      // if buffer is full
    if (mouse_btn_stream.len >= mouse_btn_stream.buffer.len) {
        return;
    }

    var owned_mods = mods;
    var parsed_mods = @ptrCast(*Mods, &owned_mods);
    const event = MouseButtonEvent{
        .button = @intToEnum(MouseButton, button),
        .action = @intToEnum(Action, action),
        .mods = parsed_mods.*,
    };

   { // critical zone
        const lock = mouse_btn_stream.mutex.acquire();
        defer lock.release();
        mouse_btn_stream.buffer[mouse_btn_stream.len] = event;
        mouse_btn_stream.len += 1;
    }

    // wake up input thread(s)
    mouse_btn_stream.new_input_event.set();
}

// TODO: generic?
fn cursorPosCallback(_window: ?*glfw.RawWindow, x_pos: f64, y_pos: f64) callconv(.C) void {
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
        const lock = cursor_pos_stream.mutex.acquire();
        defer lock.release();
        cursor_pos_stream.buffer[cursor_pos_stream.len] = event;
        cursor_pos_stream.len += 1;
    }

    // wake up input thread(s)
    cursor_pos_stream.new_input_event.set();
}

pub const Key = enum(c_int) {
    unknown = g_key.unknown,

    /// Printable glfw.keys
    space = g_key.space,
    apostrophe = g_key.apostrophe,
    comma = g_key.comma,
    minus = g_key.minus,
    period = g_key.period,
    slash = g_key.slash,
    zero = g_key.zero,
    one = g_key.one,
    two = g_key.two,
    three = g_key.three,
    four = g_key.four,
    five = g_key.five,
    six = g_key.six,
    seven = g_key.seven,
    eight = g_key.eight,
    nine = g_key.nine,
    semicolon = g_key.semicolon,
    equal = g_key.equal,
    a = g_key.a,
    b = g_key.b,
    c = g_key.c,
    d = g_key.d,
    e = g_key.e,
    f = g_key.f,
    g = g_key.g,
    h = g_key.h,
    i = g_key.i,
    j = g_key.j,
    k = g_key.k,
    l = g_key.l,
    m = g_key.m,
    n = g_key.n,
    o = g_key.o,
    p = g_key.p,
    q = g_key.q,
    r = g_key.r,
    s = g_key.s,
    t = g_key.t,
    u = g_key.u,
    v = g_key.v,
    w = g_key.w,
    x = g_key.x,
    y = g_key.y,
    z = g_key.z,
    left_bracket = g_key.left_bracket,
    backslash = g_key.backslash,
    right_bracket = g_key.right_bracket,
    grave_accent = g_key.grave_accent,
    world_1 = g_key.world_1, // non-US #1
    world_2 = g_key.world_2, // non-US 

    /// Function glfw.keys
    escape = g_key.escape,
    enter = g_key.enter,
    tab = g_key.tab,
    backspace = g_key.backspace,
    insert = g_key.insert,
    delete = g_key.delete,
    right = g_key.right,
    left = g_key.left,
    down = g_key.down,
    up = g_key.up,
    page_up = g_key.page_up,
    page_down = g_key.page_down,
    home = g_key.home,
    end = g_key.end,
    caps_lock = g_key.caps_lock,
    scroll_lock = g_key.scroll_lock,
    num_lock = g_key.num_lock,
    print_screen = g_key.print_screen,
    pause = g_key.pause,
    F1 = g_key.F1,
    F2 = g_key.F2,
    F3 = g_key.F3,
    F4 = g_key.F4,
    F5 = g_key.F5,
    F6 = g_key.F6,
    F7 = g_key.F7,
    F8 = g_key.F8,
    F9 = g_key.F9,
    F10 = g_key.F10,
    F11 = g_key.F11,
    F12 = g_key.F12,
    F13 = g_key.F13,
    F14 = g_key.F14,
    F15 = g_key.F15,
    F16 = g_key.F16,
    F17 = g_key.F17,
    F18 = g_key.F18,
    F19 = g_key.F19,
    F20 = g_key.F20,
    F21 = g_key.F21,
    F22 = g_key.F22,
    F23 = g_key.F23,
    F24 = g_key.F24,
    F25 = g_key.F25,
    kp_0 = g_key.kp_0,
    kp_1 = g_key.kp_1,
    kp_2 = g_key.kp_2,
    kp_3 = g_key.kp_3,
    kp_4 = g_key.kp_4,
    kp_5 = g_key.kp_5,
    kp_6 = g_key.kp_6,
    kp_7 = g_key.kp_7,
    kp_8 = g_key.kp_8,
    kp_9 = g_key.kp_9,
    kp_decimal = g_key.kp_decimal,
    kp_divide = g_key.kp_divide,
    kp_multiply = g_key.kp_multiply,
    kp_subtract = g_key.kp_subtract,
    kp_add = g_key.kp_add,
    kp_enter = g_key.kp_enter,
    kp_equal = g_key.kp_equal,
    left_shift = g_key.left_shift,
    left_control = g_key.left_control,
    left_alt = g_key.left_alt,
    left_super = g_key.left_super,
    right_shift = g_key.right_shift,
    right_control = g_key.right_control,
    right_alt = g_key.right_alt,
    right_super = g_key.right_super,
    menu = g_key.menu,

    // last = g_key.last, // = g_key.menu
};

pub const Action = enum(c_int) {
    release = g_action.release,
    press = g_action.press,
    repeat = g_action.repeat,
};

// https://www.glfw.org/docs/3.3/group__mods.html
pub const Mods = packed struct {
    shift: bool align(@alignOf(c_int)) = false, 
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    pub usingnamespace vk.FlagsMixin(Mods, c_int);
};

pub const KeyEvent = struct {
    key: Key,
    action: Action,
    mods: Mods,
};

pub const MouseButton = enum(c_int) {
    one = g_mouse_button.one,
    two = g_mouse_button.two,
    three = g_mouse_button.three,
    four = g_mouse_button.four,
    five = g_mouse_button.five,
    six = g_mouse_button.six,
    seven = g_mouse_button.seven,
    eight = g_mouse_button.eight,
};
pub const m_b_last = MouseButton.eight;
pub const m_b_left = MouseButton.one;
pub const m_b_right = MouseButton.two;
pub const m_b_middle = MouseButton.three;

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

