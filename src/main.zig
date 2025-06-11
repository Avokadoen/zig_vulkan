const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const zglfw = @import("zglfw");
const za = @import("zalgebra");
const ztracy = @import("ztracy");

const render = @import("render.zig");
const consts = render.consts;

const input = @import("input.zig");

// TODO: API topology
const VoxelRT = @import("VoxelRT.zig");
const BrickGrid = VoxelRT.BrickGrid;
const gpu_types = VoxelRT.gpu_types;
const vox = VoxelRT.vox;
const terrain = VoxelRT.terrain;

const ecez = @import("ecez");

pub const Storage = ecez.CreateStorage(.{
    input.component.ImguiContext,
    input.component.UserInput,
    input.component.PrevCursorPos,
    input.component.MenuActiveTag,
});

pub const InputTypes = input.CreateInputTypes(Storage);

pub const Scheduler = ecez.CreateScheduler(.{
    InputTypes.Events.input_on_key_events,
    InputTypes.Events.input_on_mouse_button,
    InputTypes.Events.input_on_cursor_pos,
    InputTypes.Events.input_on_char,
    InputTypes.Events.input_on_scroll,
    InputTypes.Events.input_on_event_update,
});

pub const InputRuntime = input.CreateInputRuntime(Storage, Scheduler);

pub const application_name = "zig vulkan";
pub const internal_render_resolution = za.GenericVector(2, u32).new(2560, 1440);

// TODO: wrap this in render to make main seem simpler :^)
var delta_time: f64 = 0;

pub fn main() anyerror!void {
    ztracy.SetThreadName("main thread");
    const main_zone = ztracy.ZoneN(@src(), "main");
    defer main_zone.End();

    const stderr = std.io.getStdErr().writer();

    // create a gpa with default configuration
    var alloc = if (consts.enable_validation_layers) std.heap.GeneralPurposeAllocator(.{}){} else std.heap.c_allocator;
    defer {
        if (consts.enable_validation_layers) {
            const leak = alloc.deinit();
            if (leak == .leak) {
                stderr.print("leak detected in gpa!", .{}) catch unreachable;
            }
        }
    }
    const allocator = if (consts.enable_validation_layers) alloc.allocator() else alloc;

    // TODO Arena alloc here
    var storage = try Storage.init(allocator);
    defer storage.deinit();

    var scheduler = try Scheduler.init(.{
        .pool_allocator = allocator,
        .query_submit_allocator = allocator,
    });
    defer scheduler.deinit();

    // Initialize the library *
    try zglfw.init();
    defer zglfw.terminate();

    if (!zglfw.isVulkanSupported()) {
        std.debug.panic("vulkan not supported on device (glfw)", .{});
    }

    // Create a windowed mode window
    zglfw.windowHint(.client_api, .no_api);
    zglfw.windowHint(.center_cursor, true);
    zglfw.windowHint(.maximized, true);
    zglfw.windowHint(.scale_to_monitor, true);
    zglfw.windowHint(.focused, true);
    var window = try zglfw.Window.create(3840, 2160, application_name, null);
    defer window.destroy();

    const ctx = try render.Context.init(allocator, application_name, window);
    defer ctx.deinit();

    var grid = try BrickGrid.init(allocator, 128, 64, 128, .{
        .min_point = [3]f32{ -32, -16, -32 },
        .scale = 0.5,
        .workers_count = 4,
    });
    defer grid.deinit();

    const model = try vox.load(false, allocator, "../assets/models/doom.vox");
    defer model.deinit();

    var materials: [256]gpu_types.Material = undefined;
    // insert terrain materials
    for (terrain.materials, 0..) |material, i| {
        materials[i] = material;
    }

    for (
        model.rgba_chunk[0 .. model.rgba_chunk.len - terrain.materials.len],
        materials[terrain.materials.len..],
    ) |rgba, *material| {
        const material_type: gpu_types.Material.Type = if (@as(f32, @floatFromInt(rgba.a)) / 255.0 < 0.8) .dielectric else .lambertian;
        const material_data: f32 = if (material_type == .dielectric) 1.52 else 0.0;
        material.* = .{
            .type = material_type,
            .albedo_r = @as(f32, @floatFromInt(rgba.r)) / 255.0,
            .albedo_g = @as(f32, @floatFromInt(rgba.g)) / 255.0,
            .albedo_b = @as(f32, @floatFromInt(rgba.b)) / 255.0,
            .type_data = material_data,
        };
    }

    // for (0..8) |index| {
    //     // grid.insert(index, (64 * 4) - 1, 1, 0);
    //     grid.insert(index, 3, 0, @intCast(index));
    // }

    // Test what we are loading
    for (model.xyzi_chunks[0]) |xyzi| {
        const material_index: u8 = xyzi.color_index + @as(u8, @intCast(terrain.materials.len));
        grid.insert(
            @as(usize, @intCast(xyzi.x)) + 200,
            @as(usize, @intCast(xyzi.z)) + 50,
            @as(usize, @intCast(xyzi.y)) + 150,
            material_index,
        );
    }

    // generate terrain on CPU
    try terrain.generateCpu(2, allocator, 420, 4, 20, &grid);

    var voxel_rt = try VoxelRT.init(allocator, ctx, &grid, .{
        .internal_resolution_width = internal_render_resolution.x(),
        .internal_resolution_height = internal_render_resolution.y(),
        .camera = .{
            .samples_per_pixel = 2,
            .max_bounce = 2,
        },
        .sun = .{
            .enabled = true,
        },
        .pipeline = .{
            .staging_buffers = 3,
        },
    });
    defer voxel_rt.deinit(allocator, ctx);

    try voxel_rt.pushMaterials(materials[0..]);

    // init input module with default input handler functions
    const input_rt = try InputRuntime.init(
        allocator,
        window,
        &storage,
        &scheduler,
        .{},
    );
    defer input_rt.deinit(allocator, window);

    var input_update_event_arg = input.event_argument.Update{
        .window = window,
        .voxel_rt = &voxel_rt,
        .dt = 0,
    };

    var prev_frame = std.time.milliTimestamp();
    // Loop until the user closes the window
    while (!window.shouldClose()) {
        scheduler.waitEvent(.input_on_event_update);

        const current_frame = std.time.milliTimestamp();
        delta_time = @as(f64, @floatFromInt(current_frame - prev_frame)) / @as(f64, std.time.ms_per_s);
        // f32 variant of delta_time
        input_update_event_arg.dt = @floatCast(delta_time);

        voxel_rt.updateSun(input_update_event_arg.dt);
        try voxel_rt.updateGridDelta();
        try voxel_rt.draw(ctx, input_update_event_arg.dt);

        // Poll for and process events
        zglfw.pollEvents();
        prev_frame = current_frame;

        scheduler.dispatchEvent(&storage, .input_on_event_update, input_update_event_arg);

        ztracy.FrameMark();
    }
}
