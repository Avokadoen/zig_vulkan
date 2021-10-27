const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const zlm = @import("zlm");
const stbi = @import("stbi");

const render = @import("../renderer/renderer.zig");
const sc = render.swapchain;
const descriptor = render.descriptor;

const rectangle_pack = @import("rectangle_pack.zig");

// Type declarations

// const Camera = struct {
//     pos: za.Vec2,
//     screen_dimentions: za.Vec2,
// };

pub const TextureHandle = c_int;

// State/Variable declarations

const UV = struct {
    min: zlm.Vec2,
    max: zlm.Vec2,
};

const Rectangle = struct {
    pos: zlm.Vec2,
    bounds: zlm.Vec2,
};

const SpriteDB = struct {
    // TODO: dirty and transfer
    // global data
    len: usize,
    sprite_pool_size: usize,
    uv_buffer: ArrayList(zlm.Vec2),
    // instance data
    positions: ArrayList(zlm.Vec2),
    scales: ArrayList(zlm.Vec2),
    rotations: ArrayList(f32),
    uv_indices: ArrayList(c_int),

    pub fn initCapacity(allocator: *Allocator, capacity: usize) !SpriteDB {
        return SpriteDB{
            .len = 0,
            .sprite_pool_size = capacity,
            .uv_buffer  = try ArrayList(zlm.Vec2).initCapacity(allocator, 10 * 4 * 2), // TODO: allow configure
            .positions  = try ArrayList(zlm.Vec2).initCapacity(allocator, capacity),
            .scales     = try ArrayList(zlm.Vec2).initCapacity(allocator, capacity),
            .rotations  = try ArrayList(f32).initCapacity(allocator, capacity),
            .uv_indices = try ArrayList(c_int).initCapacity(allocator, capacity),
        };
    }

    /// get a new sprite id
    pub fn getNewId(self: *SpriteDB) !usize {
        const newId = self.len;
        if (newId < self.sprite_pool_size) {
            self.sprite_pool_size += 1;
        }

        try self.positions.append(zlm.Vec2.zero);
        try self.scales.append(zlm.Vec2.zero);
        try self.rotations.append(0);
        try self.uv_indices.append(0);

        self.len += 1;
        return newId;
    }

    /// generate uv buffer based on 
    pub inline fn generateUvBuffer(self: *SpriteDB, mega_uvs: []UV) !void {
        for (mega_uvs) |uv| {
            try self.uv_buffer.append(zlm.Vec2.new(uv.min.x, uv.max.y));
            try self.uv_buffer.append(uv.max);
            try self.uv_buffer.append(uv.min);
            try self.uv_buffer.append(zlm.Vec2.new(uv.max.x, uv.min.y));
        }
    }

    pub fn deinit(self: *SpriteDB) void {
        self.positions.deinit();
        self.scales.deinit();
        self.rotations.deinit();
        self.uv_indices.deinit();
        self.uv_buffer.deinit();
    }
};

/// A opaque sprite handle, can be used to manipulate a given sprite
pub const Sprite = struct {
    db_ptr: *SpriteDB,
    db_id: usize,

    fn init(db: *SpriteDB) !Sprite {
        return Sprite {
            .db_ptr = db,
            .db_id = try db.getNewId(),
        };
    }

    /// set sprite position
    pub inline fn setPosition(self: Sprite, pos: zlm.Vec2) void {
        self.db_ptr.positions.items[self.db_id] = pos;
    }

    pub inline fn getPosition(self: Sprite) zlm.Vec2 {
        return self.db_ptr.positions.items[self.db_id];
    }

    /// set sprite size in pixels
    pub inline fn setSize(self: Sprite, scale: zlm.Vec2) void {
        self.db_ptr.scales.items[self.db_id] = scale;
    }

    pub inline fn getSize(self: Sprite) zlm.Vec2 {
        return self.db_ptr.scales.items[self.db_id];
    }

    /// set sprite rotation
    pub inline fn setRotation(self: Sprite, rotation: f32) void {
        self.db_ptr.rotations.items[self.db_id] = zlm.toRadians(rotation);
    }

    pub inline fn getRotation(self: Sprite) f32 {
        return zlm.toDegrees(self.db_ptr.rotations.items[self.db_id]);
    }

    /// Update sprite image to a new handle
    pub inline fn setTexture(self: Sprite, new_handle: TextureHandle) void {
        self.db_ptr.uv_indices.items[self.db_id] = new_handle;
    }

    pub inline fn getTexture(self: Sprite) TextureHandle {
        return self.db_ptr.uv_indices.items[self.db_id];
    }

    pub inline fn getRect(self: Sprite) Rectangle {
        const position = self.db_ptr.positions.items[self.db_id];
        const scale = self.db_ptr.scales.items[self.db_id];
        return Rectangle{
            .pos = position,
            .bounds = scale,
        };
    }

    /// Scale sprite to a given height while preserving ratio
    pub fn scaleToHeight(self: Sprite, height: f32) void {
        const rect = self.getRect();
        const ratio = @intToFloat(f32, rect.height) / @intToFloat(f32, rect.width);
        self.scales.items[self.db_id] = zlm.Vec2{
            .x = height * ratio,
            .y = height,
        };
    }
};

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
pub var subo: ?descriptor.SyncDescriptor = null; // TODO: not pub!!
var pipeline: ?render.Pipeline2D = null;

var sprite_db: SpriteDB = undefined;

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
    sprite_db = try SpriteDB.initCapacity(alloc, 1024);
}

/// loads a given texture using path relative to executable location. In the event of a success the returned value is an texture ID 
pub fn loadTexture(path: []const u8) !TextureHandle {
    comptime {
        api_state.requireInit();
        if (api_state.getState() == .PreparedForDraw) {
            @compileError("can't load texture after prepareDraw is called"); // a temporary restriction :(
        }
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
    comptime {
        api_state.requireInit();
        if (api_state.getState() == .PreparedForDraw) {
            @compileError("can't create sprite after prepareDraw is called"); // a temporary restriction :(
        }
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
    comptime api_state.requireInit();

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
    comptime {
        api_state.requireInit();
        api_state.prepareDraw();
    }

    // calculate position of each image registered
    const rectangles = try alloc.alloc(rectangle_pack.Rectangle, images.items.len);
    defer alloc.free(rectangles);

    for (images.items) |image, i| {
        rectangles[i].id = i; // note pack function sort slice, so we mark which rectangle is which
        rectangles[i].width = @intCast(u32, image.width);
        rectangles[i].height = @intCast(u32, image.height);
    }

    // brute force optimal width and height with no restrictions in size ...
    const bruteForceFn = rectangle_pack.InitBruteForceWidthHeightFn(false).bruteForceWidthHeight;
    const mega_size = try bruteForceFn(alloc, rectangles);

    // place each image in the mega texture
    var mega_data = try alloc.alloc(stbi.Pixel, mega_size.width * mega_size.height);

    var mega_uvs = try alloc.alloc(UV, images.items.len);
    defer alloc.free(mega_uvs);

    const mega_widthf = @intToFloat(f64, mega_size.width);
    const mega_heightf = @intToFloat(f64, mega_size.height);
    for (rectangles) |rect| {
        // the max image index components 
        const y_bound = rect.y + rect.height;
        const x_bound = rect.x + rect.width;

        // image we are moving from (src)
        const image = images.items[rect.id];
        mega_uvs[rect.id] = .{
            .min = .{
                .x = @floatCast(f32, @intToFloat(f64, rect.x) / mega_widthf),
                .y = @floatCast(f32, @intToFloat(f64, rect.y) / mega_heightf),
            },
            .max = .{
                .x = @floatCast(f32, @intToFloat(f64, x_bound) / mega_widthf),
                .y = @floatCast(f32, @intToFloat(f64, y_bound) / mega_heightf),
            }
        };

        var iy = rect.y;
        while (iy < y_bound) : (iy += 1) {

            // the y component to the image index
            const y_dest_index = iy * mega_size.width;
            const y_src_index = (iy - rect.y) * @intCast(u32, image.width);

            var ix = rect.x;
            while (ix < x_bound) : (ix += 1) {
                const src_index = y_src_index + (ix - rect.x);
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
        .viewport = view.viewport[0],
        .buffer_count = swapchain.images.items.len, 
        .buffer_sizes = buffer_sizes[0..],
    };
    subo = try descriptor.SyncDescriptor.init(desc_config);
    pipeline = try render.Pipeline2D.init(alloc, ctx, &swapchain, @intCast(u32, sprite_db.len), &view, &subo.?);

    try sprite_db.generateUvBuffer(mega_uvs);
  
    var i: usize = 0;
    while (i < swapchain.images.items.len) : (i += 1) {
        updateBuffers(i);
    }
}

pub inline fn draw() !void {
    try pipeline.?.draw(ctx, updateBuffers);
}

// TODO: only send dirty data arrays, 
// TODO: only send dirty data slices of array
fn updateBuffers(image_index: usize) void {
    subo.?.ubo.storage_buffers[image_index][0].transferData(ctx, zlm.Vec2, sprite_db.positions.items) catch {};
    subo.?.ubo.storage_buffers[image_index][1].transferData(ctx, zlm.Vec2, sprite_db.scales.items) catch {};
    subo.?.ubo.storage_buffers[image_index][2].transferData(ctx, f32,      sprite_db.rotations.items) catch {};
    subo.?.ubo.storage_buffers[image_index][3].transferData(ctx, c_int,    sprite_db.uv_indices.items) catch {};
    subo.?.ubo.storage_buffers[image_index][4].transferData(ctx, zlm.Vec2, sprite_db.uv_buffer.items) catch {};
}

// Private functions

