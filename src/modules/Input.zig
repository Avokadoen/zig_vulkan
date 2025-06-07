const std = @import("std");
const Allocator = std.mem.Allocator;

const zgui = @import("zgui");
const za = @import("zalgebra");

const zglfw = @import("zglfw");
const WindowHandle = zglfw.Window;
const Key = zglfw.Key;
const Action = zglfw.Action;
const Mods = zglfw.Mods;
const MouseButton = zglfw.MouseButton;

const VoxelRT = @import("VoxelRT.zig");

const ecez = @import("ecez");

pub const EventArgument = struct {
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
};

pub const Component = struct {
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
        event: EventArgument.CursorPosEvent,
    };

    pub const MenuActiveTag = struct {};
};

pub const Queries = struct {
    pub const GameUserInput = ecez.QueryAny(
        struct {
            entity: ecez.Entity,
            user_input: *Component.UserInput,
        },
        .{},
        .{
            Component.MenuActiveTag,
        },
    );

    pub const MenuUserInput = ecez.QueryAny(
        struct {
            entity: ecez.Entity,
            user_input: *Component.UserInput,
        },
        .{
            Component.MenuActiveTag,
        },
        .{},
    );

    pub const MenuActive = ecez.QueryAny(
        struct {},
        .{Component.MenuActiveTag},
        .{},
    );

    pub const ImguiContext = ecez.QueryAny(
        struct {
            ctx: Component.ImguiContext,
        },
        .{},
        .{},
    );
};

pub fn CreateInputTypes(comptime Storage: type) type {
    return struct {
        // TODO: single handle input event event. This will then flush a queue of events
        pub const Events = struct {
            pub const input_on_key_events = ecez.Event("input_on_key_events", .{
                Systems.HandleKeyEvent.game,
                Systems.HandleKeyEvent.menu,
            }, .{
                .run_on_main_thread = true,
            });

            pub const input_on_mouse_button = ecez.Event("input_on_mouse_button", .{
                Systems.HandleMouseButton.menu,
            }, .{
                .run_on_main_thread = true,
            });

            pub const input_on_cursor_pos = ecez.Event("input_on_cursor_pos", .{
                Systems.HandleCursorPos.game,
                Systems.HandleCursorPos.menu,
            }, .{
                .run_on_main_thread = true,
            });

            pub const input_on_char = ecez.Event("input_on_char", .{
                Systems.HandleChar.menu,
            }, .{
                .run_on_main_thread = true,
            });

            pub const input_on_scroll = ecez.Event("input_on_scroll", .{
                Systems.HandleScroll.menu,
            }, .{
                .run_on_main_thread = true,
            });

            pub const input_on_event_update = ecez.Event("input_on_event_update", .{
                Systems.Update.game,
                Systems.Update.menu,
            }, .{
                .run_on_main_thread = true,
            });
        };

        pub const SubStorages = struct {
            pub const MenuActive = Storage.Subset(.{*Component.MenuActiveTag});

            pub const PrevCursorPos = Storage.Subset(.{*Component.PrevCursorPos});
        };

        const Systems = struct {
            pub const Update = struct {
                pub fn game(
                    state: *Queries.GameUserInput,
                    event: EventArgument.Update,
                ) void {
                    if (state.getAny()) |item_entity| {
                        const user_input = item_entity.user_input;

                        user_input.mouse_ignore_frames -= if (user_input.mouse_ignore_frames > 0) 1 else 0;

                        if (user_input.call_translate > 0) {
                            if (user_input.activate_sprint) {
                                event.voxel_rt.camera.activateSprint();
                            } else {
                                event.voxel_rt.camera.disableSprint();
                            }
                            event.voxel_rt.camera.translate(event.dt, user_input.camera_translate);
                        }
                        if (user_input.call_yaw) {
                            event.voxel_rt.camera.turnYaw(-user_input.mouse_delta.x() * event.dt);
                        }
                        if (user_input.call_pitch) {
                            event.voxel_rt.camera.turnPitch(user_input.mouse_delta.y() * event.dt);
                        }
                        if (user_input.call_translate > 0 or user_input.call_yaw or user_input.call_pitch) {
                            user_input.call_yaw = false;
                            user_input.call_pitch = false;
                            user_input.mouse_delta.data[0] = 0;
                            user_input.mouse_delta.data[1] = 0;
                        }
                    }
                }

                /// update cursor based on imgui
                pub fn menu(
                    state: *Queries.MenuUserInput,
                    imgui_ctx: *Queries.ImguiContext,
                    event: EventArgument.Update,
                ) void {
                    if (state.getAny()) |item_entity| {
                        const user_input = item_entity.user_input;

                        user_input.mouse_ignore_frames -= if (user_input.mouse_ignore_frames > 0) 1 else 0;

                        const window = event.window;
                        const imgui_context: Component.ImguiContext = imgui_ctx.getAny().?.ctx;

                        switch (zgui.getMouseCursor()) {
                            .none => window.setInputMode(.cursor, .hidden) catch {},
                            .arrow => window.setCursor(imgui_context.arrow),
                            .text_input => window.setCursor(imgui_context.ibeam),
                            .resize_all => window.setCursor(imgui_context.crosshair),
                            .resize_ns => window.setCursor(imgui_context.resize_ns),
                            .resize_ew => window.setCursor(imgui_context.resize_ew),
                            .resize_nesw => window.setCursor(imgui_context.resize_nesw),
                            .resize_nwse => window.setCursor(imgui_context.resize_nwse),
                            .hand => window.setCursor(imgui_context.hand),
                            .not_allowed => window.setCursor(imgui_context.not_allowed),
                            .count => window.setCursor(imgui_context.ibeam),
                        }
                    }
                }
            };

            pub const HandleKeyEvent = struct {
                pub fn game(
                    state: *Queries.GameUserInput,
                    menu_active_storage: *SubStorages.MenuActive,
                    event: EventArgument.KeyEvent,
                ) void {
                    if (state.getAny()) |input_entity| {
                        const user_input = input_entity.user_input;

                        if (event.action == .press) {
                            switch (event.key) {
                                Key.w => {
                                    user_input.call_translate += 1;
                                    user_input.camera_translate.data[2] -= 1;
                                },
                                Key.s => {
                                    user_input.call_translate += 1;
                                    user_input.camera_translate.data[2] += 1;
                                },
                                Key.d => {
                                    user_input.call_translate += 1;
                                    user_input.camera_translate.data[0] += 1;
                                },
                                Key.a => {
                                    user_input.call_translate += 1;
                                    user_input.camera_translate.data[0] -= 1;
                                },
                                Key.left_control => {
                                    user_input.call_translate += 1;
                                    user_input.camera_translate.data[1] += 1;
                                },
                                Key.left_shift => user_input.activate_sprint = true,
                                Key.space => {
                                    user_input.call_translate += 1;
                                    user_input.camera_translate.data[1] -= 1;
                                },
                                Key.escape => {
                                    if (user_input.mouse_ignore_frames == 0) {
                                        user_input.mouse_ignore_frames = 5;

                                        menu_active_storage.setComponents(input_entity.entity, .{Component.MenuActiveTag{}}) catch {};
                                        event.window.setInputMode(.cursor, .normal) catch {};
                                    }
                                },
                                else => {},
                            }
                        } else if (event.action == .release) {
                            switch (event.key) {
                                Key.w => {
                                    user_input.call_translate -= 1;
                                    user_input.camera_translate.data[2] += 1;
                                },
                                Key.s => {
                                    user_input.call_translate -= 1;
                                    user_input.camera_translate.data[2] -= 1;
                                },
                                Key.d => {
                                    user_input.call_translate -= 1;
                                    user_input.camera_translate.data[0] -= 1;
                                },
                                Key.a => {
                                    user_input.call_translate -= 1;
                                    user_input.camera_translate.data[0] += 1;
                                },
                                Key.left_control => {
                                    user_input.call_translate -= 1;
                                    user_input.camera_translate.data[1] -= 1;
                                },
                                Key.left_shift => {
                                    user_input.activate_sprint = false;
                                },
                                Key.space => {
                                    user_input.call_translate -= 1;
                                    user_input.camera_translate.data[1] += 1;
                                },
                                else => {},
                            }
                        }
                    }
                }

                pub fn menu(
                    state: *Queries.MenuUserInput,
                    menu_active_storage: *SubStorages.MenuActive,
                    event: EventArgument.KeyEvent,
                ) void {
                    if (state.getAny()) |input_entity| {
                        const user_input = input_entity.user_input;

                        if (event.action == .press) {
                            switch (event.key) {
                                Key.escape => {
                                    // Ignore if we just changed to menu
                                    if (user_input.mouse_ignore_frames == 0) {
                                        // ignore first 5 frames of input after
                                        user_input.mouse_ignore_frames = 5;

                                        menu_active_storage.unsetComponents(input_entity.entity, .{Component.MenuActiveTag});
                                        event.window.setInputMode(.cursor, .disabled) catch {};
                                    }
                                },
                                else => {},
                            }
                        }

                        zgui.io.addKeyEvent(zgui.Key.mod_shift, event.mods.shift);
                        zgui.io.addKeyEvent(zgui.Key.mod_ctrl, event.mods.control);
                        zgui.io.addKeyEvent(zgui.Key.mod_alt, event.mods.alt);
                        zgui.io.addKeyEvent(zgui.Key.mod_super, event.mods.super);
                        // zgui.addKeyEvent(zgui.Key.mod_caps_lock, mod.caps_lock);
                        // zgui.addKeyEvent(zgui.Key.mod_num_lock, mod.num_lock);

                        zgui.io.addKeyEvent(mapGlfwKeyToImgui(event.key), event.action == .press);
                    }
                }
            };

            pub const HandleMouseButton = struct {
                pub fn menu(
                    state: *Queries.MenuActive,
                    event: EventArgument.MouseButtonEvent,
                ) void {
                    if (state.getAny()) |_| {
                        if (switch (event.button) {
                            .left => zgui.MouseButton.left,
                            .right => zgui.MouseButton.right,
                            .middle => zgui.MouseButton.middle,
                            .four, .five, .six, .seven, .eight => null,
                        }) |zgui_button| {
                            // apply modifiers
                            zgui.io.addKeyEvent(zgui.Key.mod_shift, event.mods.shift);
                            zgui.io.addKeyEvent(zgui.Key.mod_ctrl, event.mods.control);
                            zgui.io.addKeyEvent(zgui.Key.mod_alt, event.mods.alt);
                            zgui.io.addKeyEvent(zgui.Key.mod_super, event.mods.super);

                            zgui.io.addMouseButtonEvent(zgui_button, event.action == .press);
                        }
                    }
                }
            };

            pub const HandleCursorPos = struct {
                pub fn game(
                    state: *Queries.GameUserInput,
                    prev_event_storage: *SubStorages.PrevCursorPos,
                    event: EventArgument.CursorPosEvent,
                ) void {
                    if (state.getAny()) |item| {
                        const prev_cursor_pos = prev_event_storage.getComponent(item.entity, *Component.PrevCursorPos) catch null;
                        defer {
                            prev_event_storage.setComponents(item.entity, .{Component.PrevCursorPos{
                                .event = event,
                            }}) catch {};
                        }

                        // TODO: mouse_ignore_frames dedicated component
                        if (item.user_input.mouse_ignore_frames == 0) {
                            // let prev_event be defined before processing Input
                            if (prev_cursor_pos) |p_event| {
                                item.user_input.mouse_delta.data[0] += @floatCast(event.x - p_event.event.x);
                                item.user_input.mouse_delta.data[1] += @floatCast(event.y - p_event.event.y);
                            }
                            item.user_input.call_yaw = item.user_input.call_yaw or @abs(item.user_input.mouse_delta.x()) > 0.00001;
                            item.user_input.call_pitch = item.user_input.call_pitch or @abs(item.user_input.mouse_delta.y()) > 0.00001;
                        }
                    }
                }

                pub fn menu(
                    state: *Queries.MenuActive,
                    event: EventArgument.CursorPosEvent,
                ) void {
                    if (state.getAny()) |_| {
                        zgui.io.addMousePositionEvent(@floatCast(event.x), @floatCast(event.y));
                    }
                }
            };

            pub const HandleChar = struct {
                pub fn menu(
                    state: *Queries.MenuActive,
                    event: EventArgument.CharEvent,
                ) void {
                    if (state.getAny()) |_| {
                        var buffer: [8]u8 = undefined;
                        const len = std.unicode.utf8Encode(event.codepoint, buffer[0..]) catch return;
                        const cstr = buffer[0 .. len + 1];
                        cstr[len] = 0; // null terminator
                        zgui.io.addInputCharactersUTF8(@ptrCast(cstr.ptr));
                    }
                }
            };

            pub const HandleScroll = struct {
                pub fn menu(
                    state: *Queries.MenuActive,
                    event: EventArgument.ScrollEvent,
                ) void {
                    if (state.getAny()) |_| {
                        zgui.io.addMouseWheelEvent(
                            event.offset_x,
                            event.offset_y,
                        );
                    }
                }
            };
        };
    };
}

pub const Config = struct {
    camera_translate: za.Vec3 = .zero(),
};

pub fn CreateInputRuntime(comptime Storage: type, comptime Scheduler: type) type {
    return struct {
        const InputRuntime = @This();

        input_ctx_entity: ecez.Entity,

        /// !This will set the glfw window user context!
        /// create a input module.
        pub fn init(
            allocator: Allocator,
            window: *zglfw.Window,
            storage: *Storage,
            scheduler: *Scheduler,
            config: Config,
        ) !InputRuntime {
            const window_context = try allocator.create(CallbackWindowContext);
            errdefer allocator.destroy(window_context);

            window_context.* = .{
                .storage = storage,
                .scheduler = scheduler,
            };

            // create imgui context component
            const imgui_context = try linkImguiCodes();
            errdefer unlinkImguiCodes(imgui_context);

            const user_input = Component.UserInput{
                .activate_sprint = false,
                .call_translate = 0,
                .camera_translate = config.camera_translate,
                .call_yaw = false,
                .call_pitch = false,
                .mouse_delta = .zero(),
                .mouse_ignore_frames = 5,
            };

            const input_ctx_entity = try storage.createEntity(.{
                user_input,
                imgui_context,
            });

            try window.setInputMode(.cursor, .disabled);

            _ = window.setKeyCallback(keyCallback);
            _ = window.setCharCallback(charCallback);
            _ = window.setMouseButtonCallback(mouseBtnCallback);
            _ = window.setCursorPosCallback(cursorPosCallback);
            _ = window.setScrollCallback(scrollCallback);
            window.setUserPointer(@ptrCast(window_context));

            return InputRuntime{
                .input_ctx_entity = input_ctx_entity,
            };
        }

        /// kill input module
        pub fn deinit(self: InputRuntime, allocator: Allocator, window: *zglfw.Window) void {
            const window_context = window.getUserPointer(CallbackWindowContext).?;
            defer allocator.destroy(window_context);

            const imgui_context = window_context.storage.getComponent(self.input_ctx_entity, Component.ImguiContext) catch unreachable;
            unlinkImguiCodes(imgui_context);

            window.setUserPointer(null);

            // unregister callback functions
            _ = window.setKeyCallback(null);
            _ = window.setCharCallback(null);
            _ = window.setMouseButtonCallback(null);
            _ = window.setCursorPosCallback(null);
            _ = window.setScrollCallback(null);
        }

        fn keyCallback(window: *zglfw.Window, key: Key, scan_code: c_int, action: Action, mods: Mods) callconv(.c) void {
            _ = scan_code;
            const context = if (window.getUserPointer(CallbackWindowContext)) |some| some else return;

            var owned_mods = mods;
            const parsed_mods: *Mods = @ptrCast(&owned_mods);
            const event = EventArgument.KeyEvent{
                .window = window,
                .key = key,
                .action = action,
                .mods = parsed_mods.*,
            };
            context.scheduler.dispatchEvent(context.storage, .input_on_key_events, event);
        }

        fn mouseBtnCallback(window: *zglfw.Window, button: MouseButton, action: Action, mods: Mods) callconv(.c) void {
            const context = if (window.getUserPointer(CallbackWindowContext)) |some| some else return;

            // TODO: wtf is this mods code?
            var owned_mods = mods;
            const parsed_mods: *Mods = @ptrCast(&owned_mods);

            const event = EventArgument.MouseButtonEvent{
                .button = button,
                .action = action,
                .mods = parsed_mods.*,
            };
            context.scheduler.dispatchEvent(context.storage, .input_on_mouse_button, event);
        }

        fn cursorPosCallback(window: *zglfw.Window, x_pos: f64, y_pos: f64) callconv(.c) void {
            const context = if (window.getUserPointer(CallbackWindowContext)) |some| some else return;

            const event = EventArgument.CursorPosEvent{
                .x = x_pos,
                .y = y_pos,
            };
            context.scheduler.dispatchEvent(context.storage, .input_on_cursor_pos, event);
        }

        fn charCallback(window: *zglfw.Window, codepoint: u32) callconv(.c) void {
            const context = if (window.getUserPointer(CallbackWindowContext)) |some| some else return;

            const event = EventArgument.CharEvent{
                .codepoint = @intCast(codepoint),
            };
            context.scheduler.dispatchEvent(context.storage, .input_on_char, event);
        }

        fn scrollCallback(window: *zglfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
            const context = if (window.getUserPointer(CallbackWindowContext)) |some| some else return;

            const event = EventArgument.ScrollEvent{
                .offset_x = @floatCast(xoffset),
                .offset_y = @floatCast(yoffset),
            };
            context.scheduler.dispatchEvent(context.storage, .input_on_scroll, event);
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

        /// link imgui and glfw codes
        fn linkImguiCodes() !Component.ImguiContext {
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

            return Component.ImguiContext{
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

        fn unlinkImguiCodes(imgui_context: Component.ImguiContext) void {
            imgui_context.hand.destroy();
            imgui_context.arrow.destroy();
            imgui_context.ibeam.destroy();
            imgui_context.crosshair.destroy();
            imgui_context.resize_ns.destroy();
            imgui_context.resize_ew.destroy();
            imgui_context.resize_nesw.destroy();
            imgui_context.resize_nwse.destroy();
            imgui_context.not_allowed.destroy();
        }

        pub const CallbackWindowContext = struct {
            storage: *Storage,
            scheduler: *Scheduler,
        };
    };
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
