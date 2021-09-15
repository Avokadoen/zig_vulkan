const std = @import("std");

const glfw = @import("glfw");
const g_key = glfw.key;
const g_action = glfw.action;
const g_mod = glfw.mod;

const vk = @import("vulkan");

pub const input_buffer_size = 256;

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

const InputEvent = struct {
    key: Key,
    action: Action,
    mods: Mods,
};

const InputEventStream = struct {
    mutex: std.Thread.Mutex,
    len: usize,
    buffer: [input_buffer_size]InputEvent,
};

// global input stream
var input_stream = InputEventStream{
    .mutex = .{},
    .len = 0,
    .buffer = undefined,
}; 

// TODO: use callbacks for easier key binding
// const int scancode = glfwGetKeyScancode(GLFW_KEY_X);
// set_key_mapping(scancode, swap_weapons);

/// sends key events to a the key event to the input stream for further handling
/// Params:
///     - window	    The window that received the event.
///     - key	        The keyboard key that was pressed or released.
///     - scan_code	    The system-specific scancode of the key.
///     - action	    GLFW_PRESS, GLFW_RELEASE or GLFW_REPEAT. Future releases may add more actions.
///     - mod	        Bit field describing which modifier keys were held down.
pub fn keyCallback(window: ?*glfw.RawWindow, key: c_int, scan_code: c_int, action: c_int, mods: c_int) callconv(.C) void {
    _ = window;
    _ = scan_code;

    const lock = input_stream.mutex.acquire();
    defer lock.release();

    // if buffer is full
    if (input_stream.len >= input_stream.buffer.len) {
        return;
    }

    var owned_mods = mods;
    var parsed_mods = @ptrCast(*Mods, &owned_mods);
    const event = InputEvent{
        .key = @intToEnum(Key, key),
        .action = @intToEnum(Action, action),
        .mods = parsed_mods.*,
    };
    input_stream.buffer[input_stream.len] = event;
    input_stream.len += 1;

    std.debug.print("stream len: {d}", .{input_stream.len});
}
