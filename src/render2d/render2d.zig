const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const zlm = @import("zlm");
const stbi = @import("stbi");
const glfw = @import("glfw");
const vk = @import("vulkan");

const render = @import("../render/render.zig");
const dispatch = render.dispatch;
const sc = render.swapchain;
const descriptor = render.descriptor;

const knapsack = @import("knapsack.zig");
const bruteForceFn = knapsack.InitBruteForceWidthHeightFn(false).bruteForceWidthHeight;

const DB = @import("DB.zig");
const util_types = @import("util_types.zig");

const Pipeline = render.PipelineTypesFn(void).Pipeline;
const PipelineBuilder = render.PipelineTypesFn(void).PipelineBuilder;

// Exterior public types
pub const Rectangle = util_types.Rectangle;
pub const UV = util_types.UV;
pub const TextureHandle = util_types.TextureHandle;
pub const BufferUpdateRate = util_types.BufferUpdateRate;
pub const Camera = @import("Camera.zig");
pub const Sprite = @import("Sprite.zig");

pub const InvalidApiUseError = error{
    Invalidated,
};

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
    allocator: Allocator,

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

        const handle = TextureHandle{
            .id = @intCast(c_int, self.images.items.len - 1),
            .width = @intToFloat(f32, image.width),
            .height = @intToFloat(f32, image.height),
        };
        try self.db_ptr.*.uv_meta.append(handle);

        try self.image_paths.put(path, handle);
        return handle;
    }

    /// Create a new sprite 
    pub fn createSprite(self: *Self, texture: TextureHandle, position: zlm.Vec2, rotation: f32, size: zlm.Vec2) !Sprite {
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
        self.db_ptr.*.rotations.updateAt(index, zlm.toRadians(rotation));
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
        const packjobs = try self.allocator.alloc(knapsack.PackJob, self.images.items.len);
        defer self.allocator.free(packjobs);

        for (self.images.items) |image, i| {
            packjobs[i].id = i; // we will use id to identify the
            packjobs[i].width = @intCast(u32, image.width);
            packjobs[i].height = @intCast(u32, image.height);
        }

        // brute force optimal width and height with no restrictions in size ...
        const mega_size = try bruteForceFn(self.allocator, packjobs);

        // place each texture in the mega texture
        var mega_data = try self.allocator.alloc(stbi.Pixel, mega_size.width * mega_size.height);

        var mega_uvs = try self.allocator.alloc(UV, self.images.items.len);
        defer self.allocator.free(mega_uvs);

        const mega_widthf = @intToFloat(f64, mega_size.width);
        const mega_heightf = @intToFloat(f64, mega_size.height);
        for (packjobs) |packjob| {
            // the max texture index components
            const y_bound = packjob.y + packjob.height;
            const x_bound = packjob.x + packjob.width;

            // image we are moving from (src)
            const image = self.images.items[packjob.id];
            mega_uvs[packjob.id] = .{ .min = .{
                .x = @floatCast(f32, @intToFloat(f64, packjob.x) / mega_widthf),
                .y = @floatCast(f32, @intToFloat(f64, packjob.y) / mega_heightf),
            }, .max = .{
                .x = @floatCast(f32, @intToFloat(f64, x_bound) / mega_widthf),
                .y = @floatCast(f32, @intToFloat(f64, y_bound) / mega_heightf),
            } };

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
            .channels = 4,
            .data = mega_data,
        };

        const buffer_sizes = [_]u64{
            @sizeOf(zlm.Vec2) * self.db_ptr.*.sprite_pool_size,
            @sizeOf(zlm.Vec2) * self.db_ptr.*.sprite_pool_size,
            @sizeOf(f32) * self.db_ptr.*.sprite_pool_size,
            @sizeOf(c_int) * self.db_ptr.*.sprite_pool_size,
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
        var api = DrawApi(gpu_update_rate){ .state = .{
            .allocator = self.allocator,
            .ctx = self.ctx,
            .swapchain = try self.allocator.create(sc.Data),
            .subo = try self.allocator.create(descriptor.SyncDescriptor),
            .view = try self.allocator.create(sc.ViewportScissor),
            .pipeline = undefined,
            .mega_image = mega_image,
            .db_ptr = self.db_ptr,
        } };
        api.state.swapchain.* = self.swapchain;
        api.state.view.* = self.view;
        api.state.subo.* = try descriptor.SyncDescriptor.init(desc_config);
        api.state.pipeline = blk: {
            var pipe_builder = try PipelineBuilder.init(self.allocator, self.ctx, api.state.swapchain, @intCast(u32, self.db_ptr.*.len), api.state.view, api.state.subo, .{}, recordGfxCmdBuffers);
            try pipe_builder.addPipeline("../../render2d.vert.spv", "../../render2d.frag.spv");
            break :blk (try pipe_builder.build());
        };
        try api.state.db_ptr.generateUvBuffer(mega_uvs);

        for (api.state.swapchain.images.items) |_, i| {
            const buffers = api.state.subo.*.ubo.storage_buffers[i];
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
    subo: *descriptor.SyncDescriptor,
    pipeline: Pipeline,
    view: *sc.ViewportScissor,

    // render2d specific state
    mega_image: stbi.Image,
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
                    try self.state.pipeline.draw(self.state.ctx, updateBuffers, &self);
                }

                fn updateBuffers(image_index: usize, user_ctx: anytype) void {
                    const buffers = user_ctx.*.subo.ubo.storage_buffers[image_index];
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
                    try self.state.pipeline.draw(self.state.ctx, updateBuffers, &self);
                }

                fn updateBuffers(image_index: usize, user_ctx: anytype) void {
                    const current_frame = std.time.milliTimestamp();
                    user_ctx.*.last_update_counter += (current_frame - user_ctx.*.prev_frame);

                    if (user_ctx.*.last_update_counter >= ms) {
                        user_ctx.*.update_frame_count = 0;
                    }

                    const image_count = user_ctx.*.state.swapchain.images.items.len;
                    if (user_ctx.*.update_frame_count < image_count) {
                        const buffers = user_ctx.*.state.subo.ubo.storage_buffers[image_index];
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
        pub fn deinit(self: Self) void {
            self.state.allocator.free(self.state.mega_image.data);
            self.state.pipeline.deinit(self.state.ctx);
            self.state.subo.deinit(self.state.ctx);

            self.state.db_ptr.*.deinit();
            self.state.swapchain.deinit(self.state.ctx);

            // destroy render pointers
            self.state.allocator.destroy(self.state.swapchain);
            self.state.allocator.destroy(self.state.view);
            self.state.allocator.destroy(self.state.subo);

            // destroy sprite db ptr
            self.state.allocator.destroy(self.state.db_ptr);
        }

        /// get a handle to the sprite camera
        pub fn createCamera(self: *Self, move_speed: f32, zoom_speed: f32) Camera {
            return Camera{
                .move_speed = move_speed,
                .zoom_speed = zoom_speed,
                .sync_desc_ptr = self.state.subo,
            };
        }

        /// program pipeline dynamically scale with window
        /// caller should make sure to call noHandleWindowResize
        pub fn handleWindowResize(self: *Self, window: glfw.Window) void {
            window.setUserPointer(bool, &self.state.pipeline.requested_rescale_pipeline);
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
    if (window.getUserPointer(*bool)) |rescale| {
        rescale.* = true;
    }
}

/// record default commands for the render2D pipeline
fn recordGfxCmdBuffers(ctx: render.Context, pipeline: *Pipeline) dispatch.BeginCommandBufferError!void {
    const image = pipeline.sync_descript.ubo.my_texture.image;
    const image_use = render.texture.getImageTransitionBarrier(image, .general, .general);
    const clear_color = [_]vk.ClearColorValue{
        .{
            .float_32 = [_]f32{ 0.0, 0.0, 0.0, 1.0 },
        },
    };
    for (pipeline.command_buffers) |command_buffer, i| {
        const command_begin_info = vk.CommandBufferBeginInfo{
            .flags = .{},
            .p_inheritance_info = null,
        };
        try ctx.vkd.beginCommandBuffer(command_buffer, &command_begin_info);

        // make sure compute shader complet writer before beginning render pass
        ctx.vkd.cmdPipelineBarrier(command_buffer, image_use.transition.src_stage, image_use.transition.dst_stage, vk.DependencyFlags{}, 0, undefined, 0, undefined, 1, @ptrCast([*]const vk.ImageMemoryBarrier, &image_use.barrier));
        const render_begin_info = vk.RenderPassBeginInfo{
            .render_pass = pipeline.render_pass,
            .framebuffer = pipeline.framebuffers[i],
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = pipeline.sc_data.extent },
            .clear_value_count = clear_color.len,
            .p_clear_values = @ptrCast([*]const vk.ClearValue, &clear_color),
        };
        ctx.vkd.cmdSetViewport(command_buffer, 0, pipeline.view.viewport.len, &pipeline.view.viewport);
        ctx.vkd.cmdSetScissor(command_buffer, 0, pipeline.view.scissor.len, &pipeline.view.scissor);
        ctx.vkd.cmdBindPipeline(command_buffer, vk.PipelineBindPoint.graphics, pipeline.pipelines[0]);
        ctx.vkd.cmdBeginRenderPass(command_buffer, &render_begin_info, vk.SubpassContents.@"inline");

        const buffer_offsets = [_]vk.DeviceSize{0};
        ctx.vkd.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast([*]const vk.Buffer, &pipeline.vertex_buffer.buffer), @ptrCast([*]const vk.DeviceSize, &buffer_offsets));
        ctx.vkd.cmdBindIndexBuffer(command_buffer, pipeline.indices_buffer.buffer, 0, .uint32);
        // TODO: Race Condition: sync_descript is not synced here
        ctx.vkd.cmdBindDescriptorSets(command_buffer, .graphics, pipeline.pipeline_layout, 0, 1, @ptrCast([*]const vk.DescriptorSet, &pipeline.sync_descript.ubo.descriptor_sets[i]), 0, undefined);

        ctx.vkd.cmdDrawIndexed(command_buffer, pipeline.indices_buffer.len, pipeline.instance_count, 0, 0, 0);
        ctx.vkd.cmdEndRenderPass(command_buffer);
        try ctx.vkd.endCommandBuffer(command_buffer);
    }
}
