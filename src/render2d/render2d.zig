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
const bruteForceFn = knapsack.InitBruteForceWidthHeightFn(false).bruteForceWidthHeight;

const DB = @import("DB.zig");
const util_types = @import("util_types.zig");

// Exterior public types
pub const Rectangle = util_types.Rectangle;
pub const UV = util_types.UV;
pub const TextureHandle = util_types.TextureHandle;
pub const BufferUpdateRate = util_types.BufferUpdateRate;
pub const Camera = @import("Camera.zig");
pub const Sprite = @import("Sprite.zig");

pub const InvalidApiUseError = error {
    Invalidated,
};

/// initialize the sprite library, caller must make sure to call deinit
/// - init_capacity: how many sprites should be preallocated 
pub fn init(allocator: *Allocator, context: render.Context, init_capacity: usize) !InitializedApi {
    const swapchain = try sc.Data.init(allocator, context, null);

    // heap allocate db since this will be tranfered to the draw api
    const db_ptr = try allocator.create(DB);
    db_ptr.* = try DB.initCapacity(allocator, init_capacity);

    return InitializedApi{
        .allocator = allocator,
        .ctx = context,
        .swapchain = swapchain,
        .view = sc.ViewportScissor.init(swapchain.extent),
        .db_ptr = db_ptr,
        .images = std.ArrayList(stbi.Image).init(allocator),
        .image_paths = std.StringArrayHashMap(TextureHandle).init(allocator),
    };
}

/// Get the library initialize struct
/// - gpu_update_rate: how often updates to sprites should be dispatched to the GPU
pub const InitializedApi = struct {
    const Self = @This();

    // set to true after a DrawAPI struct has been initialized
    prepared_to_draw: bool = false,

    // image container, used to compile a mega texture 
    allocator: *Allocator,

    // render specific state
    ctx: render.Context,
    swapchain: sc.Data,

    // render2d specific state
    view: sc.ViewportScissor,
    db_ptr: *DB,

    images: std.ArrayList(stbi.Image),
    image_paths: std.StringArrayHashMap(TextureHandle),

    /// loads a given texture using path relative to executable location. In the event of a success the returned value is an texture ID 
    pub fn loadTexture(self: *Self, path: []const u8) !TextureHandle {
        if (self.prepared_to_draw) {
            return InvalidApiUseError.Invalidated; // this function can not be called after prepareDraw has been called
        }

        if (self.image_paths.get(path)) |some| {
            return some;
        }

        const image = try stbi.Image.from_file(self.allocator, path, stbi.DesiredChannels.STBI_rgb_alpha);
        try self.images.append(image);

        const handle: TextureHandle = @intCast(c_int, self.images.items.len - 1);
        try self.image_paths.put(path, handle);
        return handle;
    }

    /// Create a new sprite 
    pub fn createSprite(self: *Self, texture: TextureHandle, position: zlm.Vec2, rotation: f32, size: zlm.Vec2) !Sprite {
        if (self.prepared_to_draw) {
            return InvalidApiUseError.Invalidated; // this function can not be called after prepareDraw has been called
        }

        var new_sprite = Sprite {
            .db_ptr = self.db_ptr,
            .db_id = try self.db_ptr.*.getNewId(),
            // a new sprite will by default be in the top layer 
            .layer = self.db_ptr.*.layer_data.items[self.db_ptr.*.layer_data.items.len-1].id,
        };
        self.db_ptr.*.layer_data.items[self.db_ptr.*.layer_data.items.len-1].len += 1;

        const index = self.db_ptr.*.getIndex(&new_sprite.db_id);
        try self.db_ptr.*.positions.updateAt(index, position);
        try self.db_ptr.*.scales.updateAt(index, size);
        try self.db_ptr.*.rotations.updateAt(index, zlm.toRadians(rotation));
        try self.db_ptr.*.uv_indices.updateAt(index, texture);

        return new_sprite;
    }

    /// Initialize draw API 
    /// !This will invalidate the current InitializedApi!
    ///  - update_rate: dictate how often the API should push buffers to the GPU
    pub fn initDrawApi(self: *Self, comptime gpu_update_rate: BufferUpdateRate) !DrawApi(gpu_update_rate) {
        if (self.prepared_to_draw) {
            return InvalidApiUseError.Invalidated; // this function can not be called after prepareDraw has been called
        }
        
        // calculate position of each image registered
        const packjobs = try self.allocator.alloc(knapsack.PackJob, self.images.items.len);
        defer self.allocator.free(packjobs);

        for (self.images.items) |image, i| {
            packjobs[i].id = i; // we will use id to identify the
            packjobs[i].width = @intCast(u32, image.width);
            packjobs[i].height = @intCast(u32, image.height);
        }

        // brute force optimal width and height with no restrictions in size ...
        const mega_size = try bruteForceFn(self.allocator, packjobs);

        // place each image in the mega texture
        var mega_data = try self.allocator.alloc(stbi.Pixel, mega_size.width * mega_size.height);

        var mega_uvs = try self.allocator.alloc(UV, self.images.items.len);
        defer self.allocator.free(mega_uvs);

        const mega_widthf = @intToFloat(f64, mega_size.width);
        const mega_heightf = @intToFloat(f64, mega_size.height);
        for (packjobs) |packjob| {
            // the max image index components 
            const y_bound = packjob.y + packjob.height;
            const x_bound = packjob.x + packjob.width;

            // image we are moving from (src)
            const image = self.images.items[packjob.id];
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
        self.image_paths.deinit();
        self.images.deinit();

        const mega_image = stbi.Image{
            .width = @intCast(i32, mega_size.width),
            .height = @intCast(i32, mega_size.height),
            .channels = 3,
            .data = mega_data,
        };
        
        const buffer_sizes = [_]u64{
            @sizeOf(zlm.Vec2) * self.db_ptr.*.sprite_pool_size,
            @sizeOf(zlm.Vec2) * self.db_ptr.*.sprite_pool_size,
            @sizeOf(f32)      * self.db_ptr.*.sprite_pool_size,
            @sizeOf(c_int)    * self.db_ptr.*.sprite_pool_size,
            @sizeOf(zlm.Vec2) * mega_uvs.len * 4,
        };

        const desc_config = render.descriptor.Config{
            .allocator = self.allocator,
            .ctx = self.ctx, 
            .image = mega_image, 
            .viewport = self.view.viewport[0],
            .buffer_count = self.swapchain.images.items.len, 
            .buffer_sizes = buffer_sizes[0..],
        };
        var api = DrawApi(gpu_update_rate){
            .allocator = self.allocator,
            .ctx = self.ctx,
            .swapchain = self.swapchain,
            .subo = undefined,
            .pipeline = undefined,
            .view = self.view,
            .mega_image = mega_image,
            .db_ptr = self.db_ptr,
        };
        api.subo = try self.allocator.create(descriptor.SyncDescriptor);
        api.subo.* = try descriptor.SyncDescriptor.init(desc_config);
        api.pipeline = try render.Pipeline2D.init(self.allocator, self.ctx, &self.swapchain, @intCast(u32, self.db_ptr.*.len), &self.view, api.subo);
        
        try api.db_ptr.*.generateUvBuffer(mega_uvs);

        for (api.swapchain.images.items) |_, i| {
            const buffers = api.subo.*.ubo.storage_buffers[i];
            try api.db_ptr.*.uv_buffer.handleDeviceTransfer(self.ctx, &buffers[4]);
        }

        self.prepared_to_draw = true;
        
        return api;
    }
};

// TODO: find a way to not use duplicate code here (using a function variable triggers a bug in the zig compiler)
pub fn DrawApi(comptime rate: BufferUpdateRate) type {
    switch (rate) {
        .always => {
            return struct {
                const Self = @This();

                // image container, used to compile a mega texture 
                allocator: *Allocator,

                // render specific state
                ctx: render.Context,
                swapchain: sc.Data,
                subo: *descriptor.SyncDescriptor,
                pipeline: render.Pipeline2D,

                // render2d specific state
                view: sc.ViewportScissor,
                mega_image: stbi.Image,

                db_ptr: *DB,

                /// get a handle to the sprite camera
                pub fn createCamera(self: Self, move_speed: f32, zoom_speed: f32) Camera {
                    return Camera{
                        .move_speed = move_speed,
                        .zoom_speed = zoom_speed,
                        .view = self.view,
                        .sync_desc_ptr = self.subo,
                    };
                }

                /// draw with sprite api
                pub inline fn draw(self: *Self) !void {
                    try self.pipeline.draw(self.ctx, updateBuffers, &self);
                }

                // deinitialize sprite library
                pub fn deinit(self: Self) void {
                    self.allocator.free(self.mega_image.data);
                    self.pipeline.deinit(self.ctx);
                    self.subo.deinit(self.ctx);

                    self.db_ptr.*.deinit();
                    self.swapchain.deinit(self.ctx);

                    self.allocator.destroy(self.subo);
                    self.allocator.destroy(self.db_ptr);
                }

                fn updateBuffers(image_index: usize, user_ctx: anytype) void {
                    const buffers = user_ctx.*.subo.ubo.storage_buffers[image_index];
                    user_ctx.*.db_ptr.*.positions.handleDeviceTransfer(user_ctx.*.ctx, &buffers[0]) catch {};
                    user_ctx.*.db_ptr.*.scales.handleDeviceTransfer(user_ctx.*.ctx, &buffers[1]) catch {};
                    user_ctx.*.db_ptr.*.rotations.handleDeviceTransfer(user_ctx.*.ctx, &buffers[2]) catch {};
                    user_ctx.*.db_ptr.*.uv_indices.handleDeviceTransfer(user_ctx.*.ctx, &buffers[3]) catch {};
                    user_ctx.*.db_ptr.*.flush() catch {};
                }
            };
        },
        .every_ms => |ms| {
             return struct {
                const Self = @This();

                // image container, used to compile a mega texture 
                allocator: *Allocator,

                // render specific state
                ctx: render.Context,
                swapchain: sc.Data,
                subo: *descriptor.SyncDescriptor,
                pipeline: render.Pipeline2D,

                // render2d specific state
                view: sc.ViewportScissor,
                mega_image: stbi.Image,

                db_ptr: *DB,

                // set default value for members that are not common with .always
                last_update_counter: i64 = 0,
                prev_frame: i64 = 0,
                update_frame_count: u32 = 0,

                /// get a handle to the sprite camera
                pub fn createCamera(self: *Self, move_speed: f32, zoom_speed: f32) Camera {
                    return Camera{
                        .move_speed = move_speed,
                        .zoom_speed = zoom_speed,
                        .view = self.view,
                        .sync_desc_ptr = self.subo,
                    };
                }

                /// draw with sprite api
                pub inline fn draw(self: *Self) !void {
                    try self.pipeline.draw(self.ctx, updateBuffers, &self);
                }

                // deinitialize sprite library
                pub fn deinit(self: Self) void {
                    self.allocator.free(self.mega_image.data);
                    self.pipeline.deinit(self.ctx);
                    self.subo.deinit(self.ctx);

                    self.db_ptr.*.deinit();
                    self.swapchain.deinit(self.ctx);

                    self.allocator.destroy(self.subo);
                    self.allocator.destroy(self.db_ptr);
                }


                fn updateBuffers(image_index: usize, user_ctx: anytype) void {
                    const current_frame = std.time.milliTimestamp();
                    user_ctx.*.last_update_counter += (current_frame - user_ctx.*.prev_frame);

                    if (user_ctx.*.last_update_counter >= ms) {
                        user_ctx.*.update_frame_count = 0;
                    }

                    const image_count = user_ctx.*.swapchain.images.items.len;
                    if (user_ctx.*.update_frame_count < image_count) {
                        const buffers = user_ctx.*.subo.ubo.storage_buffers[image_index];
                        user_ctx.*.db_ptr.*.positions.handleDeviceTransfer(user_ctx.*.ctx, &buffers[0]) catch {};
                        user_ctx.*.db_ptr.*.scales.handleDeviceTransfer(user_ctx.*.ctx, &buffers[1]) catch {};
                        user_ctx.*.db_ptr.*.rotations.handleDeviceTransfer(user_ctx.*.ctx, &buffers[2]) catch {};
                        user_ctx.*.db_ptr.*.uv_indices.handleDeviceTransfer(user_ctx.*.ctx, &buffers[3]) catch {};
                        
                        user_ctx.*.update_frame_count += 1;
                        user_ctx.*.last_update_counter = 0;

                        if (user_ctx.*.update_frame_count >= image_count) {
                            user_ctx.*.db_ptr.*.flush() catch {};
                        }
                    }

                    user_ctx.*.prev_frame = current_frame;
                }
            };
        }
    }
}
