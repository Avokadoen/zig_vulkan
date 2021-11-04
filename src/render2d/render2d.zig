const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const zlm = @import("zlm");
const stbi = @import("stbi");

const render = @import("../render/render.zig");
const sc = render.swapchain;
const descriptor = render.descriptor;

const knapsack = @import("knapsack.zig");
const DB = @import("DB.zig");
const util_types = @import("util_types.zig");

// Exterior public types
pub const Rectangle = util_types.Rectangle;
pub const UV = util_types.UV;
pub const TextureHandle = util_types.TextureHandle;
pub const BufferUpdateRate = util_types.BufferUpdateRate;
pub const Camera = @import("Camera.zig");
pub const Sprite = @import("Sprite.zig");


const ApiValidation = enum {
    Dormant,            // library not initialized
    Initialized,        // libray has initialized most of the library memory 
    PreparedForDraw,    // library is capable of doing drawing operations

    pub inline fn assertEqual(state: ApiValidation, other: ApiValidation) void {
        comptime {
            if(builtin.mode != .Debug) {
                return;
            }
        }

        if (@enumToInt(state) != @enumToInt(other)) {
            std.debug.panic("expected api to be in state {any}, was {any}", .{other, state});
        }
    } 

    pub inline fn assertLessThan(state: ApiValidation, other: ApiValidation) void {
        comptime {
            if(builtin.mode != .Debug) {
                return;
            }
        }

        if (@enumToInt(state) < @enumToInt(other)) {
            std.debug.panic("expected api to be less than {any}, was {any}", .{other, state}); // TODO: format proper message
        }
    } 
};
var api_state: ApiValidation = .Dormant;

// render specific state
var ctx: render.Context = undefined;
var swapchain: sc.Data = undefined;
var subo: ?descriptor.SyncDescriptor = null;
var pipeline: ?render.Pipeline2D = null;

// render2d specific state
var camera: Camera = undefined;
var sprite_db: DB = undefined;

var update_fn: fn(image_index: usize, image_count: usize) void = undefined;
var last_update_counter: i64 = 0; 
var prev_frame: i64 = 0;

// image container, used to compile a mega texture 
var alloc: *Allocator = undefined;
var images: std.ArrayList(stbi.Image) = undefined;
var image_paths: std.StringArrayHashMap(TextureHandle) = undefined;

var mega_image: stbi.Image = undefined;
var uv_buffer: []zlm.Vec2 = undefined;


/// initialize the sprite library, caller must make sure to call deinit
/// - init_capacity: how many sprites should be preallocated 
pub fn init(allocator: *Allocator, context: render.Context, init_capacity: usize) !void {
    api_state.assertEqual(.Dormant);

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

    api_state = .Initialized;
}

/// loads a given texture using path relative to executable location. In the event of a success the returned value is an texture ID 
pub fn loadTexture(path: []const u8) !TextureHandle {
    api_state.assertEqual(.Initialized);

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
    api_state.assertEqual(.Initialized);

    const new_sprite = Sprite {
        .db_ptr = &sprite_db,
        .db_id = try sprite_db.getNewId(),
    };
    sprite_db.positions.items[new_sprite.db_id] = position;
    sprite_db.scales.items[new_sprite.db_id] = size;
    sprite_db.rotations.items[new_sprite.db_id] = zlm.toRadians(rotation);
    sprite_db.uv_indices.items[new_sprite.db_id] = texture;

    return new_sprite;
}

/// get a handle to the sprite camera, require that library is prepared to draw
pub fn createCamera(move_speed: f32, zoom_speed: f32) Camera {
    api_state.assertEqual(.PreparedForDraw);

    camera.move_speed = move_speed;
    camera.zoom_speed = zoom_speed;
    return camera;
}

/// Prepare API to do draw calls 
///  - update_rate: dictate how often the API should push buffers to the GPU
pub fn prepareDraw(comptime gpu_update_rate: BufferUpdateRate) !void {
    api_state.assertEqual(.Initialized);
    
    update_fn = UpdateFn(gpu_update_rate).updateBuffers;
    
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

    api_state = .PreparedForDraw;
}

/// draw with sprite api, requires prepare for draw
pub inline fn draw() !void {
    try pipeline.?.draw(ctx, update_fn);
}

// deinitialize sprite library
pub fn deinit() void {
    switch (api_state) {
        .Dormant => return, 
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

fn UpdateFn(comptime rate: BufferUpdateRate) type {
    switch (rate) {
        .always => {
            return struct {
                fn updateBuffers(image_index: usize, image_count: usize) void {
                    _ = image_count;
                    const buffers = subo.?.ubo.storage_buffers[image_index];
                    buffers[0].transfer(ctx, zlm.Vec2, sprite_db.positions.items) catch {};
                    buffers[1].transfer(ctx, zlm.Vec2, sprite_db.scales.items) catch {};
                    buffers[2].transfer(ctx, f32,      sprite_db.rotations.items) catch {};
                    buffers[3].transfer(ctx, c_int,    sprite_db.uv_indices.items) catch {};
                    buffers[4].transfer(ctx, zlm.Vec2, sprite_db.uv_buffer.items) catch {};
                }
            };
        },
        .every_ms => |ms| {
            return struct {
                const internal_rate: u32 = ms;
                var update_frame_count: usize = 0;

                fn updateBuffers(image_index: usize, image_count: usize) void {
                    const current_frame = std.time.milliTimestamp();
                    last_update_counter += (current_frame - prev_frame);

                    if (last_update_counter >= internal_rate) {
                        update_frame_count = 0;
                    }

                    if (update_frame_count < image_count) {
                        const buffers = subo.?.ubo.storage_buffers[image_index];
                        const posit = sprite_db.positions.items;
                        var pos = [1][]zlm.Vec2{ posit[20000..] };
                        var offsets = [_]usize{ 20000 };
                        buffers[0].batchTransfer(ctx, zlm.Vec2, offsets[0..], pos[0..]) catch {};
                        buffers[1].transfer(ctx, zlm.Vec2, sprite_db.scales.items) catch {};
                        buffers[2].transfer(ctx, f32,      sprite_db.rotations.items) catch {};
                        buffers[3].transfer(ctx, c_int,    sprite_db.uv_indices.items) catch {};
                        buffers[4].transfer(ctx, zlm.Vec2, sprite_db.uv_buffer.items) catch {};
                        
                        update_frame_count += 1;
                        last_update_counter = 0;
                    }

                    prev_frame = current_frame;
                }
            };
        }
    }
}
