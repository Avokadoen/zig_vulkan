const std = @import("std");
const vkgen = @import("deps/vulkan-zig/generator/index.zig");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{ 
        .default_target = .{ .abi = .gnu },
    });

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zig_vulkan", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    
    // TODO: this will only really work for my computer. Should vary based on platform too
    const sdl_path = "C:\\lib\\SDL2-2.0.14\\";
    exe.addIncludeDir(sdl_path ++ "include");
    exe.addLibPath(sdl_path ++ "lib\\x64");
    b.installBinFile(sdl_path ++ "lib\\x64\\SDL2.dll", "SDL2.dll");
    exe.linkSystemLibrary("sdl2");
    
    exe.linkLibC();

    exe.addPackagePath("ecs", "deps/zig-ecs/src/ecs.zig");

    const vk_xml_path = b.option([]const u8, "vulkan-registry", "Override the to the Vulkan registry") orelse "deps/vk.xml";
    const gen = vkgen.VkGenerateStep.init(b, vk_xml_path, "vk.zig");
    exe.step.dependOn(&gen.step);
    exe.addPackage(gen.package);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
