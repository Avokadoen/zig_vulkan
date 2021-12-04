# Zig vulkan renderer

A toy renderer written in zig using vulkan and glfw

# Run the project

Do the following steps 
```bash
$ git clone --recurse-submodules -j4 <repo>
$ cd <folder>
$ zig build run
```

# Run tests 

Currently the code base is not really well tested, but you can run the few tests by doin ``zig build test``

# 2D API
Currently there is a basic 2D sprite API. This API offers high performance (citation needed :)). A simple tech demo was made as a game jam and can be found [here](https://github.com/Avokadoen/gamejam-zig-vulkan)

Here is a minimal program that draws to the screen:

```zig
const std = @import("std");

const glfw = @import("glfw");
const zlm = @import("zlm");

const render = @import("render/render.zig");
const render2d = @import("render2d/render2d.zig");

pub fn main() anyerror!void {
    // create a gpa with default configuration
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = &alloc.allocator;
  
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
        std.debug.panic("failed to create window, code: {}", .{err});
        return;
    };
    defer window.destroy();

    // Construct our rendering context
    const ctx = try render.Context.init(allocator, "sprite test", &window, null);
    defer ctx.deinit();

    // declare some sprite and texture
    var my_texture: render2d.TextureHandle = undefined;
    var my_sprite: render2d.Sprite = undefined;

    // the api handle ready to draw
    var draw_api = blk: {

        // first init the api with allocator, context and a preallocated sprite size
        var init_api = try render2d.init(allocator, ctx, 1);

        const window_size = try window.getSize();
        const windowf = @intToFloat(f32, window_size.height);

        // currently, you can only load textures 
        // and create sprites *before* you prepare api for draw
        my_texture =  try init_api.loadTexture("../assets/images/grasstop.png"[0..]);
        my_sprite = try init_api.createSprite(
            my_texture,             // texure
            zlm.Vec2.new(0, 0),     // postion
            20,                     // rotation in degrees
            zlm.Vec2.new(
                windowf,
                windowf,
            )                       // scale
        );
        
        // when we are ready to draw we can initialize the draw API
        // here we tell the api to push sprite changes to GPU every 14 millisecond
        // this can be turned off using ``initDrawApi(.always);`` instead
        break :blk try init_api.initDrawApi(.{ .every_ms = 14 });
    };
    defer draw_api.deinit();

    // a camera can be used to move around a 2D scene
    // here we set move speed to 500, and zoom speed to 2 
    var camera = draw_api.createCamera(500, 2);

    // Loop until the user closes the window
    while (!window.shouldClose()) {
        
        //      zooming the camera
        camera.zoomIn(0); // 0 -> delta_time
        camera.zoomOut(0);

        //      moving the camera
        // camera.translate(delta_time, direction_vector);

        // move sprite to the right each frame
        var pos = my_sprite.getPosition();
        pos.x += 0.01;
        try my_sprite.setPosition(pos);

        // rotate sprite 0.5 degrees each frame
        var rot = my_sprite.getRotation();
        rot -= 0.5;
        try my_sprite.setRotation(rot);

        // you can also change scale using .setScale() and layer using setLayer()

        // tell the api to perform a draw call
        try draw_api.draw();
        
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
