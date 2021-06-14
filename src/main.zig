const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
pub const OutOfMemory = error{OutOfMemory};
const ArrayList = std.ArrayList;
const dbg = std.builtin.mode == std.builtin.Mode.Debug;

const c = @cImport({
    @cInclude("SDL.h");
    @cInclude("SDL_vulkan.h");
});
const vk = @import("vulkan");

// TODO: return error?
fn handleSDLError(function_name: []const u8) void {
    //  if (builtin.mode == .Debug) {
    const sdl_error = c.SDL_GetError();
    std.debug.panic("{s}: {any}", .{function_name, sdl_error});
} 

// Register extensions needed by SDL and the application
fn initialzeInstanceExtensionRequirements(window: ?*c.SDL_Window, allocator: *Allocator) OutOfMemory!void {
    var p_count: c_uint = undefined;
    if(c.SDL_Vulkan_GetInstanceExtensions(window.?, &p_count, null) == c.SDL_bool.SDL_FALSE) {
        handleSDLError("SDL_Vulkan_GetInstanceExtensions1");
    }
    
    var extensions = try allocator.alloc([*c]u8, p_count);
    defer allocator.free(extensions);
    if(c.SDL_Vulkan_GetInstanceExtensions(window.?, &p_count, extensions.ptr) == c.SDL_bool.SDL_FALSE) {
        handleSDLError("SDL_Vulkan_GetInstanceExtensions2");
    }

    // ArrayList([]const u8)
    for (extensions) |extension| {
        // @typeInfo(@TypeOf(extension))
        // std.mem.sliceTo(extension.?);
        std.debug.print("{s}", .{@typeInfo(@TypeOf(std.mem.span(extension).*))});
        // extension += 1;
    }
}

pub fn main() anyerror!void {
    const stderr = std.io.getStdErr().writer();

    // TODO: check if failed
    _ = c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS);
    defer c.SDL_Quit();

    var extent = vk.Extent2D{.width = 800, .height = 600};
    var window = c.SDL_CreateWindow("zig vulkan", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, @intCast(c_int, extent.width), @intCast(c_int, extent.height), c.SDL_WINDOW_VULKAN);
    defer c.SDL_DestroyWindow(window);

    // TODO: use c_allocator in optimized compile mode since we have to link with libc anyways
    // create a gpa with default configuration
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak = gpa.deinit();
        if (leak) {
            // TODO: lazy error handling can be improved
            // If error occur here we are screwed anyways 
            stderr.print("Leak detected in gpa!", .{}) catch unreachable;
        }
    }

    try initialzeInstanceExtensionRequirements(window, &gpa.allocator);


    var renderer = c.SDL_CreateRenderer(window, 0, c.SDL_RENDERER_PRESENTVSYNC);
    defer c.SDL_DestroyRenderer(renderer);


    var frame: usize = 0;
    mainloop: while (true) {
        var sdl_event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&sdl_event) != 0) {
            switch (sdl_event.type) {
                c.SDL_QUIT => break :mainloop,
                else => {},
            }
        }

        _ = c.SDL_SetRenderDrawColor(renderer, 0xff, 0xff, 0xff, 0xff);
        _ = c.SDL_RenderClear(renderer);
        var rect = c.SDL_Rect{ .x = 0, .y = 0, .w = 60, .h = 60 };
        const a = 0.06 * @intToFloat(f32, frame);
        const t = 2 * std.math.pi / 3.0;
        const r = 100 * @cos(0.1 * a);
        rect.x = 290 + @floatToInt(i32, r * @cos(a));
        rect.y = 170 + @floatToInt(i32, r * @sin(a));
        _ = c.SDL_SetRenderDrawColor(renderer, 0xff, 0, 0, 0xff);
        _ = c.SDL_RenderFillRect(renderer, &rect);
        rect.x = 290 + @floatToInt(i32, r * @cos(a + t));
        rect.y = 170 + @floatToInt(i32, r * @sin(a + t));
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0xff, 0, 0xff);
        _ = c.SDL_RenderFillRect(renderer, &rect);
        rect.x = 290 + @floatToInt(i32, r * @cos(a + 2 * t));
        rect.y = 170 + @floatToInt(i32, r * @sin(a + 2 * t));
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0xff, 0xff);
        _ = c.SDL_RenderFillRect(renderer, &rect);
        c.SDL_RenderPresent(renderer);
        frame += 1;
    }
}
