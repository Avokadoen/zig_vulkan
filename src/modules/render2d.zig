const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const za = @import("zalgebra");
const stbi = @import("stbi");
const glfw = @import("glfw");
const vk = @import("vulkan");

const render = @import("render.zig");
const dispatch = render.dispatch;
const sc = render.swapchain;
const descriptor = render.descriptor;

const knapsack = @import("render2d/knapsack.zig");
const bruteForceFn = knapsack.InitBruteForceWidthHeightFn(false).bruteForceWidthHeight;

const DB = @import("render2d/DB.zig");
const util_types = @import("render2d/util_types.zig");

const Pipeline = @import("render2d/Pipeline.zig");
const PipeType = Pipeline.PipeType;

// Exterior public types
pub const Rectangle = util_types.Rectangle;
pub const UV = util_types.UV;
pub const TextureHandle = util_types.TextureHandle;
pub const ImageHandle = util_types.ImageHandle;
pub const BufferUpdateRate = util_types.BufferUpdateRate;
pub const Camera = @import("render2d/Camera.zig");
pub const Sprite = @import("render2d/Sprite.zig");

pub const InvalidApiUseError = error{
    Invalidated,
};

const Vec2 = @Vector(2, f32);

/// initialize the sprite library, caller must make sure to call deinit
/// - init_capacity: how many sprites should be preallocated 
pub fn init(allocator: Allocator, context: render.Context, init_capacity: usize) !InitializedApi {
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
        .empty_image_indices = std.ArrayList(usize).init(allocator),
        .sprite_images = std.ArrayList(stbi.Image).init(allocator),
        .sprite_image_paths = std.StringArrayHashMap(TextureHandle).init(allocator),
        .image_images = std.ArrayList(stbi.Image).init(allocator),
    };
}

/// Get the library initialize struct
/// - gpu_update_rate: how often updates to sprites should be dispatched to the GPU
pub const InitializedApi = struct {
    const Self = @This();

    // set to true after a DrawAPI struct has been initialized
    prepared_to_draw: bool = false,

    // image container, used to compile a mega texture
    allocator: Allocator,

    // render specific state
    ctx: render.Context,
    swapchain: sc.Data,

    // render2d specific state
    view: sc.ViewportScissor,
    db_ptr: *DB,

    // used to keep track of images loaded by loadEmptySpriteTexture
    empty_image_indices: std.ArrayList(usize),
    sprite_images: std.ArrayList(stbi.Image),
    sprite_image_paths: std.StringArrayHashMap(TextureHandle),

    // TODO: MVP support 1 image, but should be N images
    image_images: std.ArrayList(stbi.Image),

    /// loads a given texture to be used by sprites using path relative to executable location. 
    /// In the event of a success the returned value is an texture ID 
    pub fn loadSpriteTexture(self: *Self, path: []const u8) !TextureHandle {
        if (self.prepared_to_draw) {
            return InvalidApiUseError.Invalidated; // this function can not be called after prepareDraw has been called
        }
        if (self.sprite_image_paths.get(path)) |some| {
            return some;
        }
        const image = try stbi.Image.fromFile(self.allocator, path, stbi.DesiredChannels.STBI_rgb_alpha);
        errdefer image.deinit();
        try self.sprite_images.append(image);
        errdefer _ = self.sprite_images.pop();

        const handle = TextureHandle{
            .id = @intCast(c_int, self.sprite_images.items.len - 1),
            .width = @intToFloat(f32, image.width),
            .height = @intToFloat(f32, image.height),
        };
        try self.db_ptr.*.uv_meta.append(handle);
        errdefer _ = self.db_ptr.*.uv_meta.pop();

        try self.sprite_image_paths.put(path, handle);
        return handle;
    }

    // TODO: HACK: init a empty texture for compute, see issue https://github.com/Avokadoen/zig_vulkan/issues/62
    pub fn loadEmptySpriteTexture(self: *Self, width: i32, height: i32) !TextureHandle {
        const image = try stbi.Image.initUndefined(self.allocator, width, height);
        errdefer image.deinit();

        try self.sprite_images.append(image);
        const handle = TextureHandle{
            .id = @intCast(c_int, self.sprite_images.items.len - 1),
            .width = @intToFloat(f32, image.width),
            .height = @intToFloat(f32, image.height),
        };
        try self.db_ptr.*.uv_meta.append(handle);

        try self.empty_image_indices.append(self.sprite_images.items.len - 1);

        return handle;
    }

    /// Create a new image from file
    pub fn imageFromFile(self: *Self, path: []const u8) !ImageHandle {
        std.debug.assert(self.image_images.items.len == 0); // Unimplemented, only support 1 image currently

        if (self.prepared_to_draw) {
            return InvalidApiUseError.Invalidated; // this function can not be called after prepareDraw has been called
        }

        const image = try stbi.Image.fromFile(self.allocator, path, stbi.DesiredChannels.STBI_rgb_alpha);
        errdefer image.deinit();

        try self.image_images.append(image);
        const id = self.image_images.items.len - 1;
        return ImageHandle{
            .id = id,
            .width = image.width,
            .height = image.height,
        };
    }

    /// Create a new undefined image
    pub fn imageUndefined(self: *Self, width: i32, height: i32) !ImageHandle {
        std.debug.assert(self.image_images.items.len == 0); // Unimplemented, only support 1 image currently

        if (self.prepared_to_draw) {
            return InvalidApiUseError.Invalidated; // this function can not be called after prepareDraw has been called
        }

        const image = try stbi.Image.initUndefined(self.allocator, width, height);
        errdefer image.deinit();

        try self.image_images.append(image);
        const id = self.image_images.items.len - 1;
        return ImageHandle{
            .id = id,
            .width = image.width,
            .height = image.height,
        };
    }

    /// Create a new sprite 
    pub fn createSprite(self: *Self, texture: TextureHandle, position: Vec2, rotation: f32, size: Vec2) !Sprite {
        if (self.prepared_to_draw) {
            return InvalidApiUseError.Invalidated; // this function can not be called after prepareDraw has been called
        }

        var new_sprite = Sprite{
            .db_ptr = self.db_ptr,
            .db_id = try self.db_ptr.*.getNewId(),
            // a new sprite will by default be in the top layer
            .layer = self.db_ptr.*.layer_data.items[self.db_ptr.*.layer_data.items.len - 1].id,
        };
        self.db_ptr.*.layer_data.items[self.db_ptr.*.layer_data.items.len - 1].len += 1;

        const index = self.db_ptr.*.getIndex(&new_sprite.db_id);
        self.db_ptr.*.positions.updateAt(index, position);
        self.db_ptr.*.scales.updateAt(index, size);
        self.db_ptr.*.rotations.updateAt(index, za.toRadians(rotation));
        self.db_ptr.*.uv_indices.updateAt(index, texture.id);

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
        const packjobs = try self.allocator.alloc(knapsack.PackJob, self.sprite_images.items.len);
        defer self.allocator.free(packjobs);

        for (self.sprite_images.items) |image, i| {
            packjobs[i].id = i; // we will use id to identify the
            packjobs[i].width = @intCast(u32, image.width);
            packjobs[i].height = @intCast(u32, image.height);
        }

        // brute force optimal width and height with no restrictions in size ...
        const mega_size = try bruteForceFn(self.allocator, packjobs);

        // place each texture in the mega texture
        const sprite_mega_image = try stbi.Image.initUndefined(
            self.allocator,
            @intCast(i32, mega_size.width),
            @intCast(i32, mega_size.height),
        );
        errdefer sprite_mega_image.deinit();

        var mega_uvs = try self.allocator.alloc(UV, self.sprite_images.items.len);
        defer self.allocator.free(mega_uvs);

        const mega_widthf = @intToFloat(f64, mega_size.width);
        const mega_heightf = @intToFloat(f64, mega_size.height);
        for (packjobs) |packjob| {
            // the max texture index components
            const y_bound = packjob.y + packjob.height;
            const x_bound = packjob.x + packjob.width;

            // image we are moving from (src)
            const image = self.sprite_images.items[packjob.id];
            mega_uvs[packjob.id] = .{ .min = [2]f32{
                @floatCast(f32, @intToFloat(f64, packjob.x) / mega_widthf),
                @floatCast(f32, @intToFloat(f64, packjob.y) / mega_heightf),
            }, .max = [2]f32{
                @floatCast(f32, @intToFloat(f64, x_bound) / mega_widthf),
                @floatCast(f32, @intToFloat(f64, y_bound) / mega_heightf),
            } };

            var iy = packjob.y;
            while (iy < y_bound) : (iy += 1) {

                // the y component to the image index
                const y_dest_index = iy * mega_size.width;
                const y_src_index = (iy - packjob.y) * @intCast(u32, image.width);

                var ix = packjob.x;
                while (ix < x_bound) : (ix += 1) {
                    const src_index = y_src_index + (ix - packjob.x);
                    sprite_mega_image.data[y_dest_index + ix] = image.data[src_index];
                }
            }
        }

        // clear original sprite_images
        self.sprite_image_paths.deinit();
        for (self.sprite_images.items) |image, i| {
            const index = [_]usize{i};
            if (std.mem.indexOf(usize, self.empty_image_indices.items, index[0..])) |some| {
                _ = some;
                self.allocator.free(image.data);
            } else {
                image.deinit();
            }
        }
        self.sprite_images.deinit();
        self.empty_image_indices.deinit();

        var api = DrawApi(gpu_update_rate){
            .state = .{
                .allocator = self.allocator,
                .ctx = self.ctx,
                .swapchain = try self.allocator.create(sc.Data),
                .subos = try self.allocator.create([Pipeline.pipe_type_count]descriptor.SyncDescriptor),
                .view = try self.allocator.create(sc.ViewportScissor),
                .pipeline = undefined,
                .sprite_mega_image = sprite_mega_image,
                .image_images = self.image_images,
                .db_ptr = self.db_ptr,
            },
        };
        api.state.swapchain.* = self.swapchain;
        api.state.view.* = self.view;
        {
            const sprite_buffer_sizes = [_]u64{
                @sizeOf(Vec2) * self.db_ptr.*.sprite_pool_size,
                @sizeOf(Vec2) * self.db_ptr.*.sprite_pool_size,
                @sizeOf(f32) * self.db_ptr.*.sprite_pool_size,
                @sizeOf(c_int) * self.db_ptr.*.sprite_pool_size,
                @sizeOf(Vec2) * mega_uvs.len * 4,
            };
            var desc_config = render.descriptor.Config{
                .allocator = self.allocator,
                .ctx = self.ctx,
                .image = sprite_mega_image,
                .viewport = self.view.viewport[0],
                .buffer_count = self.swapchain.images.len,
                .buffer_sizes = sprite_buffer_sizes[0..],
                .is_compute_target = true,
            };
            api.state.subos[0] = try descriptor.SyncDescriptor.init(desc_config);

            desc_config.image = self.image_images.items[0]; // TODO: support none, and multiple images
            const image_buffer_sizes = [0]u64{};
            desc_config.buffer_sizes = image_buffer_sizes[0..];
            desc_config.is_compute_target = false;
            api.state.subos[1] = try descriptor.SyncDescriptor.init(desc_config);
        }
        api.state.pipeline = try Pipeline.init(
            self.allocator,
            self.ctx,
            api.state.swapchain,
            @intCast(u32, self.db_ptr.*.len),
            api.state.view,
            api.state.subos,
            [2]i32{ 800, 600 },
        );
        try api.state.db_ptr.generateUvBuffer(mega_uvs);

        for (api.state.swapchain.images) |_, i| {
            const buffers = api.state.subos[0].ubo.storage_buffers[i];
            try api.state.db_ptr.*.uv_buffer.handleDeviceTransfer(self.ctx, &buffers[4]);
        }

        self.prepared_to_draw = true;

        return api;
    }
};

// data shared between DrawApi types
const CommonDrawState = struct {
    // image container, used to compile a mega texture
    allocator: Allocator,

    // render specific state
    ctx: render.Context,
    swapchain: *sc.Data,
    subos: *[Pipeline.pipe_type_count]descriptor.SyncDescriptor,
    pipeline: Pipeline,
    view: *sc.ViewportScissor,

    // render2d specific state
    sprite_mega_image: stbi.Image,
    image_images: std.ArrayList(stbi.Image),
    db_ptr: *DB,
};

pub fn DrawApi(comptime rate: BufferUpdateRate) type {
    switch (rate) {
        .always => {
            return struct {
                const Self = @This();

                state: CommonDrawState,

                usingnamespace CommonDrawAPI(Self);

                /// draw with sprite api
                pub inline fn draw(self: *Self) !void {
                    try self.state.pipeline.draw(self.state.ctx, &self, true, updateBuffers, .sprite);
                }

                fn updateBuffers(image_index: usize, user_ctx: anytype) void {
                    const buffers = user_ctx.*.subos[PipeType.sprite].ubo.storage_buffers[image_index];
                    user_ctx.*.state.db_ptr.*.positions.handleDeviceTransfer(user_ctx.*.state.ctx, &buffers[0]) catch {};
                    user_ctx.*.state.db_ptr.*.scales.handleDeviceTransfer(user_ctx.*.state.ctx, &buffers[1]) catch {};
                    user_ctx.*.state.db_ptr.*.rotations.handleDeviceTransfer(user_ctx.*.state.ctx, &buffers[2]) catch {};
                    user_ctx.*.state.db_ptr.*.uv_indices.handleDeviceTransfer(user_ctx.*.state.ctx, &buffers[3]) catch {};
                    user_ctx.*.state.db_ptr.*.flush() catch {};
                }
            };
        },
        .every_ms => |ms| {
            return struct {
                const Self = @This();

                state: CommonDrawState,

                // set default value for members that are not common with .always
                last_update_counter: i64 = 0,
                prev_frame: i64 = 0,
                update_frame_count: u32 = 0,

                usingnamespace CommonDrawAPI(Self);

                /// draw with sprite api
                pub inline fn draw(self: *Self) !void {
                    try self.state.pipeline.draw(self.state.ctx, &self, false, updateSpriteBuffers, .sprite);
                    try self.state.pipeline.draw(self.state.ctx, .{}, true, updateImageBuffers, .image);
                }

                fn updateImageBuffers(image_index: usize, user_ctx: anytype) void {
                    _ = image_index;
                    _ = user_ctx;
                }

                fn updateSpriteBuffers(image_index: usize, user_ctx: anytype) void {
                    const current_frame = std.time.milliTimestamp();
                    user_ctx.*.last_update_counter += (current_frame - user_ctx.*.prev_frame);

                    if (user_ctx.*.last_update_counter >= ms) {
                        user_ctx.*.update_frame_count = 0;
                    }

                    const image_count = user_ctx.*.state.swapchain.images.len;
                    if (user_ctx.*.update_frame_count < image_count) {
                        const buffers = user_ctx.*.state.subos[PipeType.sprite.asUsize()].ubo.storage_buffers[image_index];
                        user_ctx.*.state.db_ptr.*.positions.handleDeviceTransfer(user_ctx.*.state.ctx, &buffers[0]) catch {};
                        user_ctx.*.state.db_ptr.*.scales.handleDeviceTransfer(user_ctx.*.state.ctx, &buffers[1]) catch {};
                        user_ctx.*.state.db_ptr.*.rotations.handleDeviceTransfer(user_ctx.*.state.ctx, &buffers[2]) catch {};
                        user_ctx.*.state.db_ptr.*.uv_indices.handleDeviceTransfer(user_ctx.*.state.ctx, &buffers[3]) catch {};

                        user_ctx.*.update_frame_count += 1;
                        user_ctx.*.last_update_counter = 0;

                        if (user_ctx.*.update_frame_count >= image_count) {
                            user_ctx.*.state.db_ptr.*.flush();
                        }
                    }

                    user_ctx.*.prev_frame = current_frame;
                }
            };
        },
    }
}

fn CommonDrawAPI(comptime Self: type) type {
    return struct {
        // deinitialize sprite library
        pub fn deinit(self: *Self) void {
            self.state.image_images.deinit();
            self.state.allocator.free(self.state.sprite_mega_image.data);
            self.state.pipeline.deinit(self.state.ctx);
            for (self.state.subos) |*subo| {
                subo.deinit(self.state.ctx);
            }

            self.state.db_ptr.*.deinit();
            self.state.swapchain.deinit(self.state.ctx);

            // destroy render pointers
            self.state.allocator.free(self.state.subos);
            self.state.allocator.destroy(self.state.swapchain);
            self.state.allocator.destroy(self.state.view);

            // destroy sprite db ptr
            self.state.allocator.destroy(self.state.db_ptr);
        }

        /// get a handle to the sprite camera
        pub fn createCamera(self: *Self, move_speed: f32, zoom_speed: f32) Camera {
            return Camera{
                .move_speed = move_speed,
                .zoom_speed = zoom_speed,
                .sync_desc_ptr = self.state.subos[PipeType.sprite],
            };
        }

        /// program pipeline dynamically scale with window
        /// caller should make sure to call noHandleWindowResize
        pub fn handleWindowResize(self: *Self, window: glfw.Window) void {
            window.setUserPointer(@ptrCast(*anyopaque, &self.state.pipeline.requested_rescale_pipeline));
            _ = window.setFramebufferSizeCallback(framebufferSizeCallbackFn);
        }

        pub fn noHandleWindowResize(self: Self, window: glfw.Window) void {
            _ = self;
            _ = window.setFramebufferSizeCallback(null);
        }
    };
}

pub fn framebufferSizeCallbackFn(window: glfw.Window, width: u32, height: u32) void {
    _ = width;
    _ = height;

    // get application pointer data, and set rescale to true to signal pipeline rescale
    if (window.getUserPointer(bool)) |rescale| {
        rescale.* = true;
    }
}
