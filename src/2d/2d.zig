const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const zlm = @import("zlm");
const stbi = @import("stbi");

const render = @import("../renderer/renderer.zig");
const sc = render.swapchain;
const descriptor = render.descriptor;

const knapsack = @import("knapsack.zig");
const DB = @import("DB.zig");
const util_types = @import("util_types.zig");

pub const Rectangle = util_types.Rectangle;
pub const UV = util_types.UV;
pub const TextureHandle = util_types.TextureHandle;
pub const Camera = @import("Camera.zig");
pub const Sprite = @import("Sprite.zig");

// Type declarations

// State/Variable declarations

pub const ApiStateError = error {
    AlreadyInitialized,     // can't call init twice
    NotInitialized,         // api state must be atleast initialized
    MustBeInitialized,      // api state has to be initialized 
    NotPreparedForDraw,     // api state must be atleast prepare for draw
};
const ApiState = enum {
    Dormant,            // library not initialized
    Initialized,        // libray has initialized most of the library memory 
    PreparedForDraw,    // library is capable of doing drawing operations

    pub inline fn requireInit(state: CallState) ApiStateError!void {
        if (@enumToInt(state) < @enumToInt(.Initialized)) {
            return ApiStateError.NotInitialized;
        }
    }

    pub inline fn requirePreparedForDraw(state: CallState) ApiStateError!void {
        if (@enumToInt(state) < @enumToInt(.PreparedForDraw)) {
            return ApiStateError.NotInitialized;
        }
    }
};
var api_state: CallState = .Dormant;

// image container, used to compile a mega texture 
var alloc: *Allocator = undefined;
var images: std.ArrayList(stbi.Image) = undefined;
var image_paths: std.StringArrayHashMap(TextureHandle) = undefined;

var mega_image: stbi.Image = undefined;
var uv_buffer: []zlm.Vec2 = undefined;

var ctx: render.Context = undefined;
var swapchain: sc.Data = undefined;
var camera: Camera = undefined; // TODO: not pub!!
var subo: ?descriptor.SyncDescriptor = null; // TODO: not pub!!
var pipeline: ?render.Pipeline2D = null;

var sprite_db: DB = undefined;

// End State/Variable declarations

// Public functions

/// initialize the sprite library, caller must make sure to call deinit
/// - init_capacity: how many sprites should be preallocated 
pub fn init(allocator: *Allocator, context: render.Context, init_capacity: usize) !void {
    if (@enumToInt(api_state) > .Dormant) {
        return ApiStateError.AlreadyInitialized;
    }

    alloc = allocator;
    images = std.ArrayList(stbi.Image).init(alloc);
    image_paths = std.StringArrayHashMap(TextureHandle).init(alloc);

    ctx = context;
    swapchain = try sc.Data.init(alloc, ctx, null);
    camera = Camera{
        .zoom_speed = undefined,
        .move_speed = undefined,
        .view = sc.ViewportScissor.init(swapchain.extent),
        .sync_desc_ptr = undefined,
    };
    sprite_db = try DB.initCapacity(alloc, init_capacity);
}

/// get a handle to the sprite camera, require that library is prepared to draw
pub fn createCamera(move_speed: f32, zoom_speed: f32) !Camera {
    try api_state.requirePrepareToDraw();

    camera.move_speed = move_speed;
    camera.zoom_speed = zoom_speed;
    return camera;
}

/// loads a given texture using path relative to executable location. In the event of a success the returned value is an texture ID 
pub fn loadTexture(path: []const u8) !TextureHandle {
    if (api_state != .Initialized) {
        return ApiStateError.MustBeInitialized; // can't load a new texture before init, or after prepare for draw 
    }

    if (image_paths.get(path)) |some| {
        return some;
    }

    const image = try stbi.Image.from_file(alloc, path, stbi.DesiredChannels.STBI_rgb_alpha);
    try images.append(image);

    const handle: TextureHandle = @intCast(c_int, images.items.len - 1);
    try image_paths.put(path, handle);
    return handle;
}

/// Create a new sprite 
pub fn createSprite(texture: TextureHandle, position: zlm.Vec2, rotation: f32, size: zlm.Vec2) !Sprite {
    if (api_state != .Initialized) {
        return ApiStateError.MustBeInitialized; // can't load a new texture before init, or after prepare for draw 
    }

    const new_sprite = try Sprite.init(&sprite_db);
    sprite_db.positions.items[new_sprite.db_id] = position;
    sprite_db.scales.items[new_sprite.db_id] = size;
    sprite_db.rotations.items[new_sprite.db_id] = zlm.toRadians(rotation);
    sprite_db.uv_indices.items[new_sprite.db_id] = texture;

    return new_sprite;
}

// deinitialize sprite library
pub fn deinit() void {
    api_state.requireInit();

    switch (api_state) {
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
            
            if (pipeline) |some| {
                some.deinit(ctx);
            }
            if (subo) |some| {
                some.deinit(ctx);
            }
        }
    }

    sprite_db.deinit();
    swapchain.deinit(ctx);
}

/// Prepare API to do draw calls 
pub fn prepareDraw() !void {
    if (api_state != .Initialized) {
        ApiStateError.MustBeInitialized; // can't prepare for draw if api is not initialized
    } 

    // calculate position of each image registered
    const packjobs = try alloc.alloc(knapsack.PackJob, images.items.len);
    defer alloc.free(packjobs);

    for (images.items) |image, i| {
        packjobs[i].id = i; // we will use id to identify the
        packjobs[i].width = @intCast(u32, image.width);
        packjobs[i].height = @intCast(u32, image.height);
    }

    // brute force optimal width and height with no restrictions in size ...
    const bruteForceFn = knapsack.InitBruteForceWidthHeightFn(false).bruteForceWidthHeight;
    const mega_size = try bruteForceFn(alloc, packjobs);

    // place each image in the mega texture
    var mega_data = try alloc.alloc(stbi.Pixel, mega_size.width * mega_size.height);

    var mega_uvs = try alloc.alloc(UV, images.items.len);
    defer alloc.free(mega_uvs);

    const mega_widthf = @intToFloat(f64, mega_size.width);
    const mega_heightf = @intToFloat(f64, mega_size.height);
    for (packjobs) |packjob| {
        // the max image index components 
        const y_bound = packjob.y + packjob.height;
        const x_bound = packjob.x + packjob.width;

        // image we are moving from (src)
        const image = images.items[packjob.id];
        mega_uvs[packjob.id] = .{
            .min = .{
                .x = @floatCast(f32, @intToFloat(f64, packjob.x) / mega_widthf),
                .y = @floatCast(f32, @intToFloat(f64, packjob.y) / mega_heightf),
            },
            .max = .{
                .x = @floatCast(f32, @intToFloat(f64, x_bound) / mega_widthf),
                .y = @floatCast(f32, @intToFloat(f64, y_bound) / mega_heightf),
            }
        };

        var iy = packjob.y;
        while (iy < y_bound) : (iy += 1) {

            // the y component to the image index
            const y_dest_index = iy * mega_size.width;
            const y_src_index = (iy - packjob.y) * @intCast(u32, image.width);

            var ix = packjob.x;
            while (ix < x_bound) : (ix += 1) {
                const src_index = y_src_index + (ix - packjob.x);
                mega_data[y_dest_index + ix] = image.data[src_index]; 
            }
        }
    }

    // clear original images
    image_paths.deinit();
    images.deinit();

    mega_image = stbi.Image{
        .width = @intCast(i32, mega_size.width),
        .height = @intCast(i32, mega_size.height),
        .channels = 3,
        .data = mega_data,
    };
    
    const buffer_sizes = [_]u64{
        @sizeOf(zlm.Vec2) * sprite_db.sprite_pool_size,
        @sizeOf(zlm.Vec2) * sprite_db.sprite_pool_size,
        @sizeOf(f32)      * sprite_db.sprite_pool_size,
        @sizeOf(c_int)    * sprite_db.sprite_pool_size,
        @sizeOf(zlm.Vec2) * mega_uvs.len * 4,
    };
    const desc_config = render.descriptor.Config{
        .allocator = alloc,
        .ctx = ctx, 
        .image = mega_image, 
        .viewport = camera.view.viewport[0],
        .buffer_count = swapchain.images.items.len, 
        .buffer_sizes = buffer_sizes[0..],
    };
    subo = try descriptor.SyncDescriptor.init(desc_config);
    pipeline = try render.Pipeline2D.init(alloc, ctx, &swapchain, @intCast(u32, sprite_db.len), &camera.view, &subo.?);
    camera.sync_desc_ptr = &subo.?;
    
    try sprite_db.generateUvBuffer(mega_uvs);
  
    var i: usize = 0;
    while (i < swapchain.images.items.len) : (i += 1) {
        updateBuffers(i);
        subo.?.ubo.storage_buffers[i][1].transferData(ctx, zlm.Vec2, sprite_db.scales.items) catch {};
    }
}

/// draw with sprite api, requires prepare for draw
pub inline fn draw() !void {
    try pipeline.?.draw(ctx, updateBuffers);
}

// TODO: move to db
// TODO: only send dirty data arrays, 
// TODO: only send dirty data slices of array
fn updateBuffers(image_index: usize) void {
    subo.?.ubo.storage_buffers[image_index][0].transferData(ctx, zlm.Vec2, sprite_db.positions.items) catch {};
    // subo.?.ubo.storage_buffers[image_index][1].transferData(ctx, zlm.Vec2, sprite_db.scales.items) catch {};
    subo.?.ubo.storage_buffers[image_index][2].transferData(ctx, f32,      sprite_db.rotations.items) catch {};
    subo.?.ubo.storage_buffers[image_index][3].transferData(ctx, c_int,    sprite_db.uv_indices.items) catch {};
    subo.?.ubo.storage_buffers[image_index][4].transferData(ctx, zlm.Vec2, sprite_db.uv_buffer.items) catch {};
}

// Private functions

