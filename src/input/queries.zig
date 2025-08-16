const ecez = @import("ecez");

const component = @import("component.zig");

pub const GameUserInput = ecez.QueryAny(
    struct {
        entity: ecez.Entity,
        user_input: *component.UserInput,
    },
    .{},
    .{
        component.MenuActiveTag,
    },
);

pub const MenuUserInput = ecez.QueryAny(
    struct {
        entity: ecez.Entity,
        user_input: *component.UserInput,
    },
    .{
        component.MenuActiveTag,
    },
    .{},
);

pub const MenuActive = ecez.QueryAny(
    struct {},
    .{component.MenuActiveTag},
    .{},
);

pub const ImguiContext = ecez.QueryAny(
    struct {
        ctx: component.ImguiContext,
    },
    .{},
    .{},
);
