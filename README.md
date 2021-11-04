# Zig vulkan renderer

A toy renderer written in zig using vulkan and glfw

# Run the project

To build simply ``git pull`` followed by a ``zig build run`` in the root of the project

# Run tests 

Currently the code base is not really well tested, but you can run the few tests by doin ``zig build test``

# 2D API
Currently there is a basic 2D sprite API. Here is a minimal program that draws to the screen:

```zig
const std = @import("std");

const glfw = @import("glfw");
const zlm = @import("zlm");

const render = @import("render/render.zig");
const render2d = @import("render2d/render2d.zig");

pub fn main() anyerror!void {
    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    // create a gpa with default configuration
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &alloc.allocator;
    
    // Initialize the library *
    try glfw.init();
    defer glfw.terminate();

    if (!try glfw.vulkanSupported()) {
        std.debug.panic("vulkan not supported on device (glfw)", .{});
    }

    // Tell glfw that we are planning to use a custom API (not opengl)
    try glfw.Window.hint(glfw.Window.Hint.client_api, glfw.no_api);

    // Create a windowed mode window 
    var window = glfw.Window.create(800, 800, "sprite test", null, null) catch |err| {
        try stderr.print("failed to create window, code: {}", .{err});
        return;
    };
    defer window.destroy();

    var writers = render.Writers{ .stdout = &stdout, .stderr = &stderr };
    // Construct our vulkan instance
    const ctx = try render.Context.init(allocator, "sprite test", &window, &writers);
    defer ctx.deinit();
    
    try render2d.init(allocator, ctx, 1);
    defer render2d.deinit();
    
    const my_texture = try render2d.loadTexture("../assets/images/grasstop.png"[0..]);
    
    const window_size = try window.getSize();
    const windowf = @intToFloat(f32, window_size.height);  
    const my_sprite = try render2d.createSprite(
        my_texture, 
        zlm.Vec2.new(0, 0),            // position
        0,                             // rotation 
        zlm.Vec2.new(windowf, windowf) // scale
    );

    try render2d.prepareDraw();

    var camera = render2d.createCamera(500, 2);

    // Loop until the user closes the window
    while (!window.shouldClose()) {
       
        my_sprite.setPosition(zlm.Vec2.new(0, 0));
        my_sprite.setRotation(10);
        camera.zoomIn(0);
          
        try render2d.draw();
        
        // Poll for and process events
        try glfw.pollEvents();
    }
}
```

# Sources:

* Vulkan fundementals: 
  * https://vkguide.dev/
  * https://vulkan-tutorial.com
* Setup Zig for Gamedev: https://dev.to/fabioarnold/setup-zig-for-gamedev-2bmf 
* Using vulkan-zig: https://github.com/Snektron/vulkan-zig/blob/master/examples
