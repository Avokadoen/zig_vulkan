const std = @import("std");
const Allocator = std.mem.Allocator;

const glfw = @import("glfw");
const imgui = @import("imgui");

pub const WindowHandle = glfw.Window.Handle;
pub const Key = glfw.Key;
pub const Action = glfw.Action;
pub const Mods = glfw.Mods;
pub const MouseButton = glfw.mouse_button.MouseButton;
pub const InputModeCursor = glfw.Window.InputModeCursor;

// TODO: use callbacks for easier key binding
// const int scancode = glfwGetKeyScancode(GLFW_KEY_X);
// set_key_mapping(scancode, swap_weapons);

// TODO: imgui should be optional

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
    allocator: Allocator,
    key_handle_fn: KeyHandleFn,
    mouse_btn_handle_fn: MouseButtonHandleFn,
    cursor_pos_handle_fn: CursorPosHandleFn,
};

const ImguiContext = struct {
    mouse_cursors: [imgui.ImGuiMouseCursor_COUNT]?glfw.Cursor,
    hid_cursor: bool,
};

const Input = @This();

window: glfw.Window,
window_context: *WindowContext,
imgui_context: ImguiContext,

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
        .allocator = allocator,
        .key_handle_fn = input_handle_fn,
        .mouse_btn_handle_fn = input_mouse_btn_handle_fn,
        .cursor_pos_handle_fn = input_cursor_pos_handle_fn,
    };

    try window.setInputMode(glfw.Window.InputMode.cursor, InputModeCursor.normal);

    _ = window.setKeyCallback(keyCallback);
    _ = window.setCharCallback(charCallback);
    _ = window.setMouseButtonCallback(mouseBtnCallback);
    _ = window.setCursorPosCallback(cursorPosCallback);
    _ = window.setScrollCallback(scrollCallback);
    window.setUserPointer(@ptrCast(?*anyopaque, window_context));

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

pub fn setInputModeCursor(self: Input, mode: InputModeCursor) !void {
    try self.window.setInputModeCursor(mode);
}

pub fn setCursorPosCallback(self: Input, input_cursor_pos_handle_fn: CursorPosHandleFn) void {
    self.window_context.cursor_pos_handle_fn = input_cursor_pos_handle_fn;
}

pub fn setKeyCallback(self: Input, input_key_handle_fn: KeyHandleFn) void {
    self.window_context.key_handle_fn = input_key_handle_fn;
}

/// update cursor based on imgui 
pub fn updateCursor(self: *Input) !void {
    const io = imgui.igGetIO();
    if (io.ConfigFlags & imgui.ImGuiConfigFlags_NoMouseCursorChange == 0) {
        const cursor = imgui.igGetMouseCursor();
        if (io.MouseDrawCursor or cursor == imgui.ImGuiMouseCursor_None) {
            try self.window.setInputModeCursor(.hidden);
            self.imgui_context.hid_cursor = true;
        } else {
            const new_cursor = self.imgui_context.mouse_cursors[@intCast(usize, cursor)] orelse self.imgui_context.mouse_cursors[@intCast(usize, imgui.ImGuiMouseCursor_Arrow)].?;
            try self.window.setCursor(new_cursor);

            if (self.imgui_context.hid_cursor == true) {
                try self.window.setInputModeCursor(.normal);
                self.imgui_context.hid_cursor = false;
            }
        }
    }
}

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

    const io = imgui.igGetIO();
    io.KeysDown[@intCast(usize, @enumToInt(key))] = action == Action.press;
    io.KeyShift = mods.shift;
    io.KeyCtrl = mods.control;
    io.KeyAlt = mods.alt;
    io.KeySuper = mods.super;
}

fn charCallback(window: glfw.Window, codepoint: u21) void {
    const context = if (window.getUserPointer(WindowContext)) |some| some else return;
    const io = imgui.igGetIO();
    var buffer: [8]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, buffer[0..]) catch return;
    const text = std.cstr.addNullByte(context.allocator, buffer[0..len]) catch return;
    defer context.allocator.free(text);
    imgui.ImGuiIO_AddInputCharactersUTF8(io, text);
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

    const io = imgui.igGetIO();
    switch (button) {
        .left => io.MouseDown[0] = action == .press,
        .right => io.MouseDown[1] = action == .press,
        .middle => io.MouseDown[2] = action == .press,
        else => {},
    }
}

fn cursorPosCallback(window: glfw.Window, x_pos: f64, y_pos: f64) void {
    const event = CursorPosEvent{
        .x = x_pos,
        .y = y_pos,
    };
    const context = if (window.getUserPointer(WindowContext)) |some| some else return;
    context.cursor_pos_handle_fn(event);

    const io = imgui.igGetIO();
    io.MousePos = imgui.ImVec2.init(@floatCast(f32, x_pos), @floatCast(f32, y_pos));
}

fn scrollCallback(window: glfw.Window, xoffset: f64, yoffset: f64) void {
    _ = window;
    const io = imgui.igGetIO();
    if (xoffset > 0) io.MouseWheelH -= 1;
    if (xoffset < 0) io.MouseWheelH += 1;
    if (yoffset > 0) io.MouseWheel += 1;
    if (yoffset > 0) io.MouseWheel -= 1;
}

/// link imgui and glfw codes
fn linkImguiCodes() !ImguiContext {
    var io = imgui.igGetIO();
    io.BackendFlags |= imgui.ImGuiBackendFlags_HasMouseCursors;
    io.BackendFlags |= imgui.ImGuiBackendFlags_HasSetMousePos;

    io.KeyMap[imgui.ImGuiKey_Tab] = @enumToInt(Key.tab);
    io.KeyMap[imgui.ImGuiKey_LeftArrow] = @enumToInt(Key.left);
    io.KeyMap[imgui.ImGuiKey_RightArrow] = @enumToInt(Key.right);
    io.KeyMap[imgui.ImGuiKey_UpArrow] = @enumToInt(Key.up);
    io.KeyMap[imgui.ImGuiKey_DownArrow] = @enumToInt(Key.down);
    io.KeyMap[imgui.ImGuiKey_PageUp] = @enumToInt(Key.page_up);
    io.KeyMap[imgui.ImGuiKey_PageDown] = @enumToInt(Key.page_down);
    io.KeyMap[imgui.ImGuiKey_Home] = @enumToInt(Key.home);
    io.KeyMap[imgui.ImGuiKey_End] = @enumToInt(Key.end);
    io.KeyMap[imgui.ImGuiKey_Insert] = @enumToInt(Key.insert);
    io.KeyMap[imgui.ImGuiKey_Delete] = @enumToInt(Key.delete);
    io.KeyMap[imgui.ImGuiKey_Backspace] = @enumToInt(Key.backspace);
    io.KeyMap[imgui.ImGuiKey_Space] = @enumToInt(Key.space);
    io.KeyMap[imgui.ImGuiKey_Enter] = @enumToInt(Key.enter);
    io.KeyMap[imgui.ImGuiKey_Escape] = @enumToInt(Key.escape);
    io.KeyMap[imgui.ImGuiKey_KeyPadEnter] = @enumToInt(Key.kp_enter);
    io.KeyMap[imgui.ImGuiKey_A] = @enumToInt(Key.a);
    io.KeyMap[imgui.ImGuiKey_C] = @enumToInt(Key.c);
    io.KeyMap[imgui.ImGuiKey_V] = @enumToInt(Key.v);
    io.KeyMap[imgui.ImGuiKey_X] = @enumToInt(Key.x);
    io.KeyMap[imgui.ImGuiKey_Y] = @enumToInt(Key.y);
    io.KeyMap[imgui.ImGuiKey_Z] = @enumToInt(Key.z);

    io.SetClipboardTextFn = setClipboardTextFn;
    io.GetClipboardTextFn = getClipboardTextFn;

    const Shape = glfw.Cursor.Shape;
    var self = ImguiContext{
        .mouse_cursors = undefined,
        .hid_cursor = false,
    };
    std.mem.set(?glfw.Cursor, self.mouse_cursors[0..], null);
    self.mouse_cursors[@intCast(usize, imgui.ImGuiMouseCursor_Arrow)] = try glfw.Cursor.createStandard(Shape.arrow);
    self.mouse_cursors[@intCast(usize, imgui.ImGuiMouseCursor_TextInput)] = try glfw.Cursor.createStandard(Shape.ibeam);
    self.mouse_cursors[@intCast(usize, imgui.ImGuiMouseCursor_ResizeAll)] = try glfw.Cursor.createStandard(Shape.crosshair);
    self.mouse_cursors[@intCast(usize, imgui.ImGuiMouseCursor_ResizeNS)] = try glfw.Cursor.createStandard(Shape.vresize);
    self.mouse_cursors[@intCast(usize, imgui.ImGuiMouseCursor_ResizeEW)] = try glfw.Cursor.createStandard(Shape.hresize);
    self.mouse_cursors[@intCast(usize, imgui.ImGuiMouseCursor_ResizeNESW)] = try glfw.Cursor.createStandard(Shape.crosshair);
    self.mouse_cursors[@intCast(usize, imgui.ImGuiMouseCursor_ResizeNWSE)] = try glfw.Cursor.createStandard(Shape.crosshair);
    self.mouse_cursors[@intCast(usize, imgui.ImGuiMouseCursor_Hand)] = try glfw.Cursor.createStandard(Shape.hand);
    self.mouse_cursors[@intCast(usize, imgui.ImGuiMouseCursor_NotAllowed)] = try glfw.Cursor.createStandard(Shape.hand);

    return self;
}

fn getClipboardTextFn(ctx: ?*anyopaque) callconv(.C) [*c]const u8 {
    _ = ctx;

    const clipboard_string = glfw.getClipboardString() catch blk: {
        break :blk "";
    };
    return clipboard_string;
}

fn setClipboardTextFn(ctx: ?*anyopaque, text: [*c]const u8) callconv(.C) void {
    _ = ctx;
    glfw.setClipboardString(text) catch {};
}
