const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ecez = @import("ecez");
const za = @import("zalgebra");
const zglfw = @import("zglfw");
const ztracy = @import("ztracy");

const input = @import("input.zig");
const render = @import("render.zig");
const consts = render.consts;
const VoxelRT = @import("VoxelRT.zig");
const grid = VoxelRT.grid;
const gpu_types = VoxelRT.gpu_types;
const vox = VoxelRT.vox;
const terrain = VoxelRT.terrain;

pub const Storage = ecez.CreateStorage(.{
    input.component.ImguiContext,
    input.component.UserInput,
    input.component.PrevCursorPos,
    input.component.MenuActiveTag,

    VoxelRT.camera.components.Camera,
    VoxelRT.camera.components.DeviceCamera,
    VoxelRT.sun.components.Sun,
    VoxelRT.sun.components.DeviceSun,
    VoxelRT.benchmark.components.Benchmark,
    VoxelRT.benchmark.components.Report,

    VoxelRT.grid_state.components.ActiveBricks,
    VoxelRT.grid_state.components.Statuses,
    VoxelRT.grid_state.components.StatusDelta,
    VoxelRT.grid_state.components.Indices,
    VoxelRT.grid_state.components.IndicesDelta,
    VoxelRT.grid_state.components.Occupancy,
    VoxelRT.grid_state.components.OccupancyDelta,
    VoxelRT.grid_state.components.StartIndices,
    VoxelRT.grid_state.components.StartIndicesDelta,
    VoxelRT.grid_state.components.MaterialIndices,
    VoxelRT.grid_state.components.MaterialIndicesDelta,
    VoxelRT.grid_state.components.MaterialAllocator,
    VoxelRT.grid_state.components.Device,

    VoxelRT.grid.components.InsertVoxel,
    VoxelRT.grid.components.InsertVoxelTag,

    VoxelRT.terrain.components.ChunkToGenerate,
    VoxelRT.terrain.components.Perlin,

    render.context.components.vk_dispatch.Base,
    render.context.components.vk_dispatch.Instance,
    render.context.components.vk_dispatch.Device,
    render.context.components.Instance,
    render.context.components.PhysicalDeviceProperties,
    render.context.components.PhysicalDeviceHostImageCopyProperties,
    render.context.components.PhysicalDevice,
    render.context.components.Device,
    render.context.components.Surface,
    render.context.components.DebugUtilsMessenger,
    render.context.components.ComputeQueue,
    render.context.components.GraphicsQueue,
    render.context.components.QueueFamilyIndices,
    render.context.components.AuxillaryCommandPool,
    render.context.components.WindowPtr,

    render.vk_utils.components.Pipeline,
    render.vk_utils.components.PipelineLayout,

    render.swapchain.components.SwapchainData,
    render.gpu_buffer_memory.components.GpuBufferMemory,
});

pub const InputTypes = input.CreateInputTypes(Storage);
pub const VoxelRTEvents = VoxelRT.CreateEvents(Storage);
pub const Scheduler = ecez.CreateScheduler(.{
    InputTypes.events.input_on_key_events,
    InputTypes.events.input_on_mouse_button,
    InputTypes.events.input_on_cursor_pos,
    InputTypes.events.input_on_char,
    InputTypes.events.input_on_scroll,
    InputTypes.events.input_on_event_update,

    VoxelRTEvents.events.voxel_rt_update,

    render.CreateEvents(Storage).render_deinit,
});

pub const InputRuntime = input.CreateInputRuntime(Storage, Scheduler);

pub const application_name = "zig vulkan";
pub const internal_render_resolution = [2]u32{ 2560, 1440 };

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

    const ctx_entity = try render.context.createContextEntity(
        Storage,
        &storage,
        allocator,
        application_name,
        window,
    );

    // init input module with default input handler functions
    const input_rt = try InputRuntime.init(
        allocator,
        window,
        &storage,
        &scheduler,
        .{},
    );
    defer input_rt.deinit(allocator, window);

    const grid_entity = try grid.createAndStoreStateComponents(Storage, &storage, .{
        .min_point = [3]f32{ 0, 0, 0 },
        .scale = 0.5,
    });

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

    try terrain.createAndStoreInitialTerrainGenEntites(
        Storage,
        &storage,
        420,
        4,
        20,
    );

    for (0..8) |index| {
        try grid.scheduleInsert(
            Storage,
            &storage,
            @intCast(index),
            0,
            0,
            @intCast(index),
        );
    }

    for (model.xyzi_chunks[0]) |xyzi| {
        const material_index: u8 = xyzi.color_index + @as(u8, @intCast(terrain.materials.len));
        try grid.scheduleInsert(
            Storage,
            &storage,
            @intCast(xyzi.x),
            @intCast(xyzi.z),
            @intCast(xyzi.y),
            material_index,
        );
    }

    var voxel_rt = try VoxelRT.init(allocator, Storage, &storage, ctx_entity, grid_entity, .{
        .internal_resolution_width = internal_render_resolution[0],
        .internal_resolution_height = internal_render_resolution[1],
        .camera = .{
            .samples_per_pixel = 2,
            .max_bounce = 2,
            .origin = za.Vec3.new(8, 8, 15).data,
        },
        .sun = .{
            .enabled = true,
        },
        .pipeline = .{},
    });
    defer {
        // TODO: this should be removed when render is 100% ecez
        voxel_rt.deinit(Storage, &storage, ctx_entity);
        scheduler.dispatchEvent(&storage, .render_deinit, .{});
    }

    try voxel_rt.pushMaterials(Storage, &storage, materials[0..]);

    var prev_frame = std.time.milliTimestamp();
    // Loop until the user closes the window
    while (!window.shouldClose()) {
        const current_frame = std.time.milliTimestamp();
        const delta_time = @as(f64, @floatFromInt(current_frame - prev_frame)) / @as(f64, std.time.ms_per_s);
        const f32_delta_time: f32 = @floatCast(delta_time);

        scheduler.dispatchEvent(&storage, .voxel_rt_update, VoxelRT.EventArgument{
            .voxel_rt = &voxel_rt,
            .delta_time = f32_delta_time,
        });
        scheduler.waitEvent(.voxel_rt_update);

        try voxel_rt.draw(ctx_entity, Storage, &storage, f32_delta_time);

        // Poll for and process events
        zglfw.pollEvents();
        prev_frame = current_frame;

        // this event runs on the main thread and does not need a wait
        scheduler.dispatchEvent(&storage, .input_on_event_update, input.event_argument.Update{
            .window = window,
            .voxel_rt = &voxel_rt,
            .delta_time = f32_delta_time,
        });

        ztracy.FrameMark();
    }
}
