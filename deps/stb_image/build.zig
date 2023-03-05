const std = @import("std");

pub fn linkStep(b: *std.build.Builder, step: *std.build.LibExeObjStep) void {
    const this_dir = std.fs.path.dirname(@src().file) orelse ".";
    var include_dir = std.fs.path.join(b.allocator, &.{ this_dir, "c_src/" }) catch unreachable;
    defer b.allocator.free(include_dir);
    step.addIncludePath(include_dir);

    var src_path = std.fs.path.join(b.allocator, &.{ include_dir, "stb_image.c" }) catch unreachable;
    defer b.allocator.free(src_path);
    const src_paths = [_][]u8{src_path};
    step.addCSourceFiles(src_paths[0..], &.{});

    step.addModule("stbi", b.createModule(.{
        .source_file = .{ .path = "src/main.zig" },
    }));
}

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("stbi", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
