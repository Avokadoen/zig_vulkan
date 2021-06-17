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
    
    switch(target.getOs().tag) {
        .linux, .macos => {
            exe.linkSystemLibrary("glfw");
        },
        else => |platform| {
            std.debug.panic("Unsuported system {}", .{platform});
        }
    }
    
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
