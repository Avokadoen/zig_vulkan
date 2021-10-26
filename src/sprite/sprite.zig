const std = @import("std");

const Allocator = std.mem.Allocator;

const zlm = @import("zlm");
const stbi = @import("stbi");

const render = @import("../renderer/renderer.zig");
const sc = render.swapchain;
const descriptor = render.descriptor;

const rectangle_pack = @import("rectangle_pack.zig");
const Rectangle = rectangle_pack.Rectangle;
const pixelScanPack = rectangle_pack.pixelScanPack;


// Type declarations

// const Camera = struct {
//     pos: za.Vec2,
//     screen_dimentions: za.Vec2,
// };

pub const TextureHandle = usize;

// State/Variable declarations

const CallStateTypes = enum {
    Dormant, // library not initialized
    Initialized,
    PreparedForDraw,
};

/// used to verify correct use of the API
fn CallState() type {
    comptime var state: CallStateTypes = .Dormant;

    return struct {
        const Self = @This();

        pub fn getState(self: Self) CallStateTypes {
            _ = self;
            return state;
        }

        pub fn requireInit(self: Self) void {
            _ = self;
            if (@enumToInt(state) <= @enumToInt(CallStateTypes.Dormant)) {
                @compileError("sprite library not initialized");
            }
        }

        pub fn setInit(self: Self) void {
            _ = self;
            state = .Initialized;
        }

        pub fn prepareDraw(self: Self) void {
            _ = self;
            state = .PreparedForDraw;
        }
    };
}

var api_state: CallState() = .{};

// image container, used to compile a mega texture 
var alloc: *Allocator = undefined;
var images: std.ArrayList(stbi.Image) = undefined;
var image_paths: std.StringArrayHashMap(TextureHandle) = undefined;

var mega_image: stbi.Image = undefined;
var uv_buffer: []zlm.Vec2 = undefined;

var ctx: render.Context = undefined;
var swapchain: sc.Data = undefined;
var view: sc.ViewportScissor = undefined;
pub var subo: descriptor.SyncDescriptor = undefined; // TODO: not pub!!
var pipeline: render.Pipeline2D = undefined;

// End State/Variable declarations

// Public functions

/// initialize the sprite library, caller must make sure to call deinit
pub fn init(allocator: *Allocator, context: render.Context) !void {
    comptime {
        if (api_state.getState() != CallStateTypes.Dormant) {
            @compileError("sprite library already initialized");
        }
        api_state.setInit();
    } 

    alloc = allocator;
    images = std.ArrayList(stbi.Image).init(alloc);
    image_paths = std.StringArrayHashMap(TextureHandle).init(alloc);

    ctx = context;
    swapchain = try sc.Data.init(alloc, ctx, null);
    view = sc.ViewportScissor.init(swapchain.extent);
}

// deinitialize sprite library
pub fn deinit() void {
    comptime api_state.requireInit();

    pipeline.deinit(ctx);
    swapchain.deinit(ctx);
    subo.deinit(ctx);

    switch (api_state.getState()) {
        .Dormant => unreachable, // see first line in function
        .Initialized => {
            // prepareDraw removes the image data, so we only have to clean it if we did not call prepareDraw
            image_paths.deinit();
            images.deinit();
        },
        .PreparedForDraw => {
            // since sprite package made pixels, we manually free them instead of calling mega_image.deinit()
            alloc.free(mega_image.data);
            alloc.free(uv_buffer);
        }
    }
}
 
/// loads a given texture using path relative to executable location. In the event of a success the returned value is an texture ID 
pub fn loadTexture(path: []const u8) !TextureHandle {
    comptime api_state.requireInit();

    if (image_paths.get(path)) |some| {
        return some;
    }

    const image = try stbi.Image.from_file(alloc, path, stbi.DesiredChannels.STBI_rgb_alpha);
    try images.append(image);

    const handle: TextureHandle = images.items.len - 1;
    try image_paths.put(path, handle);
    return handle;
}

/// generate megatexture according to all specified textures 
/// Parameters
///     - max_sprites:      max sprite instances
///     - mega_width:       the width of the resulting mega texture
///     - mega_height:      the height of the resulting mega texture
pub fn prepareDraw(sprite_pool_size: usize, mega_width: u32, mega_height: u32) !void {
    comptime {
        api_state.requireInit();
        api_state.prepareDraw();
    }

    // calculate position of each image registered
    const rectangles = try alloc.alloc(Rectangle, images.items.len);
    for (images.items) |image, i| {
        rectangles[i].id = i; // note pack function sort slice, so we mark which rectangle is which
        rectangles[i].width = @intCast(u32, image.width);
        rectangles[i].height = @intCast(u32, image.height);
    }
    try rectangle_pack.pixelScanPack(alloc, mega_width, mega_height, rectangles);

    // place each image in the mega texture
    var mega_data = try alloc.alloc(stbi.Pixel, mega_width * mega_height);
    
    const UV = struct {
        min: zlm.Vec2,
        max: zlm.Vec2,
    };
    var mega_uvs = try alloc.alloc(UV, images.items.len);
    defer alloc.free(mega_uvs);

    for (rectangles) |rect| {
        // the max image index components 
        const y_bound = rect.y + rect.height;
        const x_bound = rect.x + rect.width;

        // image we are moving from (src)
        const image = images.items[rect.id];
        mega_uvs[rect.id] = .{
            .min = .{
                .x = @intToFloat(f32, rect.x) / @intToFloat(f32, mega_width),
                .y = @intToFloat(f32, rect.y) / @intToFloat(f32, mega_height),
            },
            .max = .{
                .x = @intToFloat(f32, x_bound) / @intToFloat(f32, mega_width),
                .y = @intToFloat(f32, y_bound) / @intToFloat(f32, mega_height),
            }
        };

        var iy = rect.y;
        while (iy < y_bound) : (iy += 1) {

            // the y component to the image index
            const y_dest_index = iy * mega_width;
            const y_src_index = (iy - rect.y) * @intCast(u32, image.width);

            var ix = rect.x;
            while (ix < x_bound) : (ix += 1) {
                const src_index = y_src_index + (ix - rect.x);
                mega_data[y_dest_index + ix] = image.data[src_index]; 
            }
        }
    }

    // delete rectangles
    alloc.free(rectangles);

    // clear original images
    image_paths.deinit();
    images.deinit();

    mega_image = stbi.Image{
        .width = @intCast(i32, mega_width),
        .height = @intCast(i32, mega_height),
        .channels = 3,
        .data = mega_data,
    };
    
    // TODO: because of a ?bug? in zig, we can't send stack memory into a stack memory struct
    // so we alloc some temp memory instead. Change this to a simply stack definition when that works
    const buffer_sizes = try alloc.alloc(u64, 3);
    defer alloc.free(buffer_sizes);
    buffer_sizes[0] = @sizeOf(zlm.Vec2) * sprite_pool_size;
    buffer_sizes[1] = @sizeOf(c_int) * sprite_pool_size;
    buffer_sizes[2] = @sizeOf(zlm.Vec2) * 4 * sprite_pool_size;
    
    const desc_config = render.descriptor.Config{
        .allocator = alloc,
        .ctx = ctx, 
        .image = mega_image, 
        .viewport = view.viewport[0],
        .buffer_count = swapchain.images.items.len, 
        .buffer_sizes = buffer_sizes,
    };
    subo = try descriptor.SyncDescriptor.init(desc_config);
    pipeline = try render.Pipeline2D.init(alloc, ctx, &swapchain, &view, &subo);

    uv_buffer = try alloc.alloc(zlm.Vec2, 4 * images.items.len);
    for (mega_uvs) |uv, i| {
        const index = i * 4;
        uv_buffer[index]   = zlm.Vec2.new(uv.min.x, uv.max.y);
        uv_buffer[index+1] = uv.max;
        uv_buffer[index+2] = uv.min;
        uv_buffer[index+3] = zlm.Vec2.new(uv.max.x, uv.min.y);
    }

    // initialize GPU test data
    var test_pos = [_]zlm.Vec2{ zlm.Vec2.new(0, 0), zlm.Vec2.new(0.5, 0.2) };
    var test_uv_index = [_]c_int{ 0, 1 };
    var i: usize = 0;
    const wat = uv_buffer;
    while (i < swapchain.images.items.len) : (i += 1) {
        try subo.ubo.storage_buffers[i][0].transferData(ctx, zlm.Vec2, test_pos[0..]);
        try subo.ubo.storage_buffers[i][1].transferData(ctx, c_int, test_uv_index[0..]);
        try subo.ubo.storage_buffers[i][2].transferData(ctx, zlm.Vec2, wat[0..]);
    }
}

pub inline fn draw() !void {
    try pipeline.draw(ctx);
}

// Private functions

