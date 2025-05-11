const std = @import("std");
const Allocator = std.mem.Allocator;

const zglfw = @import("zglfw");
const zgui = @import("zgui");

pub const WindowHandle = zglfw.Window;
pub const Key = zglfw.Key;
pub const Action = zglfw.Action;
pub const Mods = zglfw.Mods;
pub const MouseButton = zglfw.MouseButton;

// TODO: use callbacks for easier key binding
// const int scancode = glfwGetKeyScancode(GLFW_KEY_X);
// set_key_mapping(scancode, swap_weapons);

// TODO: imgui should be optional

// TODO: thread safety

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

pub const KeyHandleFn = *const fn (KeyEvent) void;
pub const MouseButtonHandleFn = *const fn (MouseButtonEvent) void;
pub const CursorPosHandleFn = *const fn (CursorPosEvent) void;

const WindowContext = struct {
    allocator: Allocator,
    imgui_want_input: bool,
    key_handle_fn: KeyHandleFn,
    mouse_btn_handle_fn: MouseButtonHandleFn,
    cursor_pos_handle_fn: CursorPosHandleFn,
};

const ImguiContext = struct {
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

const Input = @This();

window: *zglfw.Window,
window_context: *WindowContext,
imgui_context: ImguiContext,

/// !This will set the glfw window user context!
/// create a input module.
pub fn init(
    allocator: Allocator,
    input_window: *zglfw.Window,
    input_handle_fn: KeyHandleFn,
    input_mouse_btn_handle_fn: MouseButtonHandleFn,
    input_cursor_pos_handle_fn: CursorPosHandleFn,
) !Input {
    const window = input_window;
    const window_context = try allocator.create(WindowContext);
    window_context.* = .{
        .allocator = allocator,
        .imgui_want_input = false,
        .key_handle_fn = input_handle_fn,
        .mouse_btn_handle_fn = input_mouse_btn_handle_fn,
        .cursor_pos_handle_fn = input_cursor_pos_handle_fn,
    };

    try window.setInputMode(.cursor, .normal);

    _ = window.setKeyCallback(keyCallback);
    _ = window.setCharCallback(charCallback);
    _ = window.setMouseButtonCallback(mouseBtnCallback);
    _ = window.setCursorPosCallback(cursorPosCallback);
    _ = window.setScrollCallback(scrollCallback);
    window.setUserPointer(@ptrCast(window_context));

    const imgui_context = try linkImguiCodes();

    return Input{
        .window = window,
        .window_context = window_context,
        .imgui_context = imgui_context,
    };
}

/// kill input module
pub fn deinit(self: Input, allocator: Allocator) void {
    self.window.setUserPointer(null);
    allocator.destroy(self.window_context);

    // unregister callback functions
    _ = self.window.setKeyCallback(null);
    _ = self.window.setCharCallback(null);
    _ = self.window.setMouseButtonCallback(null);
    _ = self.window.setCursorPosCallback(null);
    _ = self.window.setScrollCallback(null);
}

pub fn setImguiWantInput(self: Input, want_input: bool) void {
    self.window_context.imgui_want_input = want_input;
}

pub fn setInputModeCursor(self: Input, mode: zglfw.Cursor.Mode) !void {
    try self.window.setInputMode(.cursor, mode);
}

pub fn setCursorPosCallback(self: Input, input_cursor_pos_handle_fn: CursorPosHandleFn) void {
    self.window_context.cursor_pos_handle_fn = input_cursor_pos_handle_fn;
}

pub fn setKeyCallback(self: Input, input_key_handle_fn: KeyHandleFn) void {
    self.window_context.key_handle_fn = input_key_handle_fn;
}

/// update cursor based on imgui
pub fn updateCursor(self: *Input) !void {
    const context = if (self.window.getUserPointer(WindowContext)) |some| some else return;
    if (context.imgui_want_input == false) {
        return;
    }

    try self.window.setInputMode(.cursor, .normal);
    switch (zgui.getMouseCursor()) {
        .none => try self.window.setInputMode(.cursor, .hidden),
        .arrow => self.window.setCursor(self.imgui_context.arrow),
        .text_input => self.window.setCursor(self.imgui_context.ibeam),
        .resize_all => self.window.setCursor(self.imgui_context.crosshair),
        .resize_ns => self.window.setCursor(self.imgui_context.resize_ns),
        .resize_ew => self.window.setCursor(self.imgui_context.resize_ew),
        .resize_nesw => self.window.setCursor(self.imgui_context.resize_nesw),
        .resize_nwse => self.window.setCursor(self.imgui_context.resize_nwse),
        .hand => self.window.setCursor(self.imgui_context.hand),
        .not_allowed => self.window.setCursor(self.imgui_context.not_allowed),
        .count => self.window.setCursor(self.imgui_context.ibeam),
    }
}

fn keyCallback(window: *zglfw.Window, key: Key, scan_code: c_int, action: Action, mods: Mods) callconv(.c) void {
    _ = scan_code;

    var owned_mods = mods;
    const parsed_mods: *Mods = @ptrCast(&owned_mods);
    const event = KeyEvent{
        .key = key,
        .action = action,
        .mods = parsed_mods.*,
    };
    const context = if (window.getUserPointer(WindowContext)) |some| some else return;
    context.key_handle_fn(event);

    if (context.imgui_want_input) {
        zgui.io.addKeyEvent(zgui.Key.mod_shift, mods.shift);
        zgui.io.addKeyEvent(zgui.Key.mod_ctrl, mods.control);
        zgui.io.addKeyEvent(zgui.Key.mod_alt, mods.alt);
        zgui.io.addKeyEvent(zgui.Key.mod_super, mods.super);
        // zgui.addKeyEvent(zgui.Key.mod_caps_lock, mod.caps_lock);
        // zgui.addKeyEvent(zgui.Key.mod_num_lock, mod.num_lock);

        zgui.io.addKeyEvent(mapGlfwKeyToImgui(key), action == .press);
    }
}

fn charCallback(window: *zglfw.Window, codepoint: u32) callconv(.c) void {
    const context = if (window.getUserPointer(WindowContext)) |some| some else return;
    if (context.imgui_want_input) {
        var buffer: [8]u8 = undefined;
        const code: u21 = @intCast(codepoint);
        const len = std.unicode.utf8Encode(code, buffer[0..]) catch return;
        const cstr = buffer[0 .. len + 1];
        cstr[len] = 0; // null terminator
        zgui.io.addInputCharactersUTF8(@ptrCast(cstr.ptr));
    }
}

fn mouseBtnCallback(window: *zglfw.Window, button: MouseButton, action: Action, mods: Mods) callconv(.c) void {
    var owned_mods = mods;
    const parsed_mods: *Mods = @ptrCast(&owned_mods);
    const event = MouseButtonEvent{
        .button = button,
        .action = action,
        .mods = parsed_mods.*,
    };
    const context = if (window.getUserPointer(WindowContext)) |some| some else return;
    context.mouse_btn_handle_fn(event);

    if (context.imgui_want_input) {
        if (switch (button) {
            .left => zgui.MouseButton.left,
            .right => zgui.MouseButton.right,
            .middle => zgui.MouseButton.middle,
            .four, .five, .six, .seven, .eight => null,
        }) |zgui_button| {
            // apply modifiers
            zgui.io.addKeyEvent(zgui.Key.mod_shift, mods.shift);
            zgui.io.addKeyEvent(zgui.Key.mod_ctrl, mods.control);
            zgui.io.addKeyEvent(zgui.Key.mod_alt, mods.alt);
            zgui.io.addKeyEvent(zgui.Key.mod_super, mods.super);

            zgui.io.addMouseButtonEvent(zgui_button, action == .press);
        }
    }
}

fn cursorPosCallback(window: *zglfw.Window, x_pos: f64, y_pos: f64) callconv(.c) void {
    const event = CursorPosEvent{
        .x = x_pos,
        .y = y_pos,
    };
    const context = if (window.getUserPointer(WindowContext)) |some| some else return;
    context.cursor_pos_handle_fn(event);

    if (context.imgui_want_input) {
        zgui.io.addMousePositionEvent(@floatCast(x_pos), @floatCast(y_pos));
    }
}

fn scrollCallback(window: *zglfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    const context = if (window.getUserPointer(WindowContext)) |some| some else return;

    if (context.imgui_want_input) {
        zgui.io.addMouseWheelEvent(@floatCast(xoffset), @floatCast(yoffset));
    }
}

/// link imgui and glfw codes
fn linkImguiCodes() !ImguiContext {
    const hand = try zglfw.Cursor.createStandard(.hand);
    errdefer hand.destroy();
    const arrow = try zglfw.Cursor.createStandard(.arrow);
    errdefer arrow.destroy();
    const ibeam = try zglfw.Cursor.createStandard(.ibeam);
    errdefer ibeam.destroy();
    const crosshair = try zglfw.Cursor.createStandard(.crosshair);
    errdefer crosshair.destroy();
    const resize_ns = try zglfw.Cursor.createStandard(.resize_ns);
    errdefer resize_ns.destroy();
    const resize_ew = try zglfw.Cursor.createStandard(.resize_ew);
    errdefer resize_ew.destroy();
    const resize_nesw = try zglfw.Cursor.createStandard(.resize_nesw);
    errdefer resize_nesw.destroy();
    const resize_nwse = try zglfw.Cursor.createStandard(.resize_nwse);
    errdefer resize_nwse.destroy();
    const not_allowed = try zglfw.Cursor.createStandard(.not_allowed);
    errdefer not_allowed.destroy();

    return ImguiContext{
        .hand = hand,
        .arrow = arrow,
        .ibeam = ibeam,
        .crosshair = crosshair,
        .resize_ns = resize_ns,
        .resize_ew = resize_ew,
        .resize_nesw = resize_nesw,
        .resize_nwse = resize_nwse,
        .not_allowed = not_allowed,
    };
}

fn getClipboardTextFn(ctx: ?*anyopaque) callconv(.C) [*c]const u8 {
    _ = ctx;

    const clipboard_string = zglfw.getClipboardString() catch blk: {
        break :blk "";
    };
    return clipboard_string;
}

fn setClipboardTextFn(ctx: ?*anyopaque, text: [*c]const u8) callconv(.C) void {
    _ = ctx;
    zglfw.setClipboardString(text) catch {};
}

inline fn mapGlfwKeyToImgui(key: zglfw.Key) zgui.Key {
    return switch (key) {
        .unknown => zgui.Key.none,
        .space => zgui.Key.space,
        .apostrophe => zgui.Key.apostrophe,
        .comma => zgui.Key.comma,
        .minus => zgui.Key.minus,
        .period => zgui.Key.period,
        .slash => zgui.Key.slash,
        .zero => zgui.Key.zero,
        .one => zgui.Key.one,
        .two => zgui.Key.two,
        .three => zgui.Key.three,
        .four => zgui.Key.four,
        .five => zgui.Key.five,
        .six => zgui.Key.six,
        .seven => zgui.Key.seven,
        .eight => zgui.Key.eight,
        .nine => zgui.Key.nine,
        .semicolon => zgui.Key.semicolon,
        .equal => zgui.Key.equal,
        .a => zgui.Key.a,
        .b => zgui.Key.b,
        .c => zgui.Key.c,
        .d => zgui.Key.d,
        .e => zgui.Key.e,
        .f => zgui.Key.f,
        .g => zgui.Key.g,
        .h => zgui.Key.h,
        .i => zgui.Key.i,
        .j => zgui.Key.j,
        .k => zgui.Key.k,
        .l => zgui.Key.l,
        .m => zgui.Key.m,
        .n => zgui.Key.n,
        .o => zgui.Key.o,
        .p => zgui.Key.p,
        .q => zgui.Key.q,
        .r => zgui.Key.r,
        .s => zgui.Key.s,
        .t => zgui.Key.t,
        .u => zgui.Key.u,
        .v => zgui.Key.v,
        .w => zgui.Key.w,
        .x => zgui.Key.x,
        .y => zgui.Key.y,
        .z => zgui.Key.z,
        .left_bracket => zgui.Key.left_bracket,
        .backslash => zgui.Key.back_slash,
        .right_bracket => zgui.Key.right_bracket,
        .grave_accent => zgui.Key.grave_accent,
        .world_1 => zgui.Key.none, // ????
        .world_2 => zgui.Key.none, // ????
        .escape => zgui.Key.escape,
        .enter => zgui.Key.enter,
        .tab => zgui.Key.tab,
        .backspace => zgui.Key.back_space,
        .insert => zgui.Key.insert,
        .delete => zgui.Key.delete,
        .right => zgui.Key.right_arrow,
        .left => zgui.Key.left_arrow,
        .down => zgui.Key.down_arrow,
        .up => zgui.Key.up_arrow,
        .page_up => zgui.Key.page_up,
        .page_down => zgui.Key.page_down,
        .home => zgui.Key.home,
        .end => zgui.Key.end,
        .caps_lock => zgui.Key.caps_lock,
        .scroll_lock => zgui.Key.scroll_lock,
        .num_lock => zgui.Key.num_lock,
        .print_screen => zgui.Key.print_screen,
        .pause => zgui.Key.pause,
        .F1 => zgui.Key.f1,
        .F2 => zgui.Key.f2,
        .F3 => zgui.Key.f3,
        .F4 => zgui.Key.f4,
        .F5 => zgui.Key.f5,
        .F6 => zgui.Key.f6,
        .F7 => zgui.Key.f7,
        .F8 => zgui.Key.f8,
        .F9 => zgui.Key.f9,
        .F10 => zgui.Key.f10,
        .F11 => zgui.Key.f11,
        .F12 => zgui.Key.f12,
        .F13,
        .F14,
        .F15,
        .F16,
        .F17,
        .F18,
        .F19,
        .F20,
        .F21,
        .F22,
        .F23,
        .F24,
        .F25,
        => zgui.Key.none,
        .kp_0 => zgui.Key.keypad_0,
        .kp_1 => zgui.Key.keypad_1,
        .kp_2 => zgui.Key.keypad_2,
        .kp_3 => zgui.Key.keypad_3,
        .kp_4 => zgui.Key.keypad_4,
        .kp_5 => zgui.Key.keypad_5,
        .kp_6 => zgui.Key.keypad_6,
        .kp_7 => zgui.Key.keypad_7,
        .kp_8 => zgui.Key.keypad_8,
        .kp_9 => zgui.Key.keypad_9,
        .kp_decimal => zgui.Key.keypad_decimal,
        .kp_divide => zgui.Key.keypad_divide,
        .kp_multiply => zgui.Key.keypad_multiply,
        .kp_subtract => zgui.Key.keypad_subtract,
        .kp_add => zgui.Key.keypad_add,
        .kp_enter => zgui.Key.keypad_enter,
        .kp_equal => zgui.Key.keypad_equal,
        .left_shift => zgui.Key.left_shift,
        .left_control => zgui.Key.left_ctrl,
        .left_alt => zgui.Key.left_alt,
        .left_super => zgui.Key.left_super,
        .right_shift => zgui.Key.right_shift,
        .right_control => zgui.Key.right_ctrl,
        .right_alt => zgui.Key.right_alt,
        .right_super => zgui.Key.right_super,
        .menu => zgui.Key.menu,
    };
}
