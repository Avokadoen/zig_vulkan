const std = @import("std");
const fs = std.fs;
const os = std.os;

const LibExeObjStep = std.build.LibExeObjStep;
const Builder = std.build.Builder;
const Step = std.build.Step;
const ArrayList = std.ArrayList;

const vkgen = @import("deps/vulkan-zig/generator/index.zig");
const glfw = @import("deps/mach-glfw/build.zig");
const stbi = @import("deps/stb_image/build.zig");
const tracy = @import("deps/Zig-Tracy/build_tracy.zig");
const imgui = @import("deps/zig-gamekit/gamekit/deps/imgui/build.zig");

// TODO: this file could use a refactor pass or atleast some comments to make it more readable

const MoveDirError = error{NotFound};

/// Holds the path to a file where parent directory and file name is separated
const SplitPath = struct {
    dir: []const u8,
    file_name: []const u8,
};

inline fn pathAndFile(file_path: []const u8) !SplitPath {
    var i = file_path.len - 1;
    while (i > 0) : (i -= 1) {
        if (file_path[i] == '/') {
            return SplitPath{
                .dir = file_path[0..i],
                .file_name = file_path[i + 1 .. file_path.len],
            };
        }
    }
    return MoveDirError.NotFound;
}

const ShaderMoveStep = struct {
    step: Step,
    builder: *Builder,

    abs_from: [20]?[]const u8 = [_]?[]const u8{null} ** 20,
    abs_len: usize = 0,

    fn init(b: *Builder, shader_step: *vkgen.ShaderCompileStep) !*ShaderMoveStep {
        var step = Step.init(.custom, "shader_resource", b.allocator, make);
        step.dependOn(&shader_step.step);

        const self = try b.allocator.create(ShaderMoveStep);
        self.* = .{
            .step = step,
            .builder = b,
        };

        return self;
    }

    fn add_abs_resource(self: *ShaderMoveStep, new_abs: []const u8) !void {
        if (self.abs_len >= self.abs_from.len) {
            return error.MaxResources;
        }
        defer self.abs_len += 1;

        self.abs_from[self.abs_len] = new_abs;
    }

    fn make(step: *Step) anyerror!void {
        const self: *ShaderMoveStep = @fieldParentPtr(ShaderMoveStep, "step", step);

        try createFolder(self.builder.install_prefix);

        for (self.abs_from) |from| {
            if (from) |some| {
                try self.moveShaderToOut(some);
            } else {
                break;
            }
        }
    }

    /// moves a given resource to a given path relative to the output binary
    fn moveShaderToOut(self: *ShaderMoveStep, abs_from: []const u8) anyerror!void {
        const old_path = try pathAndFile(abs_from);
        var old_dir = try fs.openDirAbsolute(old_path.dir, .{});
        defer old_dir.close();

        var new_dir = try fs.openDirAbsolute(self.builder.install_prefix, .{});
        defer new_dir.close();

        try fs.rename(old_dir, old_path.file_name, new_dir, old_path.file_name);
    }
};

const AssetMoveStep = struct {
    step: Step,
    builder: *Builder,

    fn init(b: *Builder) !*AssetMoveStep {
        var step = Step.init(.custom, "assets", b.allocator, make);

        const self = try b.allocator.create(AssetMoveStep);
        self.* = .{
            .step = step,
            .builder = b,
        };

        return self;
    }

    fn make(step: *Step) anyerror!void {
        const self: *AssetMoveStep = @fieldParentPtr(AssetMoveStep, "step", step);

        try createFolder(self.builder.install_prefix);

        const dst_asset_path = blk: {
            const dst_asset_path_arr = [_][]const u8{ self.builder.install_prefix, "assets" };
            break :blk try std.fs.path.join(self.builder.allocator, dst_asset_path_arr[0..]);
        };
        try createFolder(dst_asset_path);
        var dst_assets_dir = try fs.openDirAbsolute(dst_asset_path, .{});
        defer dst_assets_dir.close();

        var src_assets_dir = try fs.cwd().openDir("assets/", .{
            .iterate = true,
        });
        defer src_assets_dir.close();

        copyDir(src_assets_dir, dst_assets_dir);
    }
};

// TODO: HACK: catch unreachable to avoid error hell from recursion
fn copyDir(src_dir: fs.Dir, dst_parent_dir: fs.Dir) void {
    const Kind = fs.File.Kind;

    var iter = src_dir.iterate();
    while (iter.next() catch unreachable) |asset| {
        switch (asset.kind) {
            Kind.Directory => {
                if (std.mem.eql(u8, asset.name, "shaders")) {
                    continue; // skip shader folder which will be compiled by glslc before being moved
                }
                var src_child_dir = src_dir.openDir(asset.name, .{
                    .iterate = true,
                }) catch unreachable;
                defer src_child_dir.close();

                dst_parent_dir.makeDir(asset.name) catch |err| switch (err) {
                    std.os.MakeDirError.PathAlreadyExists => {}, // ok
                    else => unreachable,
                };
                var dst_child_dir = dst_parent_dir.openDir(asset.name, .{}) catch unreachable;
                defer dst_child_dir.close();

                copyDir(src_child_dir, dst_child_dir);
            },
            Kind.File => std.fs.Dir.copyFile(src_dir, asset.name, dst_parent_dir, asset.name, .{}) catch unreachable,
            else => {}, // don't care
        }
    }
}

inline fn createFolder(path: []const u8) !void {
    if (fs.makeDirAbsolute(path)) |_| {
        // ok
    } else |err| switch (err) {
        std.os.MakeDirError.PathAlreadyExists => {
            // ok
        },
        else => |e| return e,
    }
}

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zig_vulkan", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkLibC();

    // compile and link with glfw statically
    glfw.link(b, exe, .{});
    exe.addPackagePath("glfw", "deps/mach-glfw/src/main.zig");
    exe.addPackagePath("zalgebra", "deps/zalgebra/src/main.zig");

    // until imgui is a optional component we need to always link c++ system libraries
    exe.linkSystemLibrary("c++");
    imgui.linkArtifact(b, exe, target, "deps/zig-gamekit/");

    stbi.linkStep(b, exe);

    const vk_xml_path = b.option([]const u8, "vulkan-registry", "Override to the Vulkan registry") orelse "deps/vk.xml";
    const gen = vkgen.VkGenerateStep.init(b, vk_xml_path, "vk.zig");
    exe.step.dependOn(&gen.step);
    exe.addPackage(gen.package);

    // TODO: -O (optimize), -I (includes)
    //  !always have -g as last entry! (see glslc_len definition)
    const include_shader_debug = b.option(bool, "shader-debug-info", "include shader debug info, default is false") orelse false;
    const glslc_flags = [_][]const u8{ "glslc", "--target-env=vulkan1.2", "-g" };
    const glslc_len = if (include_shader_debug) glslc_flags.len else glslc_flags.len - 1;
    const shader_comp = vkgen.ShaderCompileStep.init(
        b,
        glslc_flags[0..glslc_len],
        "shaders",
    );
    const shader_move_step = ShaderMoveStep.init(b, shader_comp) catch unreachable;

    {
        const image_vert = shader_comp.add("assets/shaders/image.vert");
        shader_move_step.add_abs_resource(image_vert) catch unreachable;
        const image_frag = shader_comp.add("assets/shaders/image.frag");
        shader_move_step.add_abs_resource(image_frag) catch unreachable;
    }

    {
        const imgui_vert = shader_comp.add("assets/shaders/ui.vert");
        shader_move_step.add_abs_resource(imgui_vert) catch unreachable;
        const imgui_frag = shader_comp.add("assets/shaders/ui.frag");
        shader_move_step.add_abs_resource(imgui_frag) catch unreachable;
    }

    {
        const b_rt = shader_comp.add("assets/shaders/brick_raytracer.comp");
        shader_move_step.add_abs_resource(b_rt) catch unreachable;
        const gen_height = shader_comp.add("assets/shaders/height_map_gen.comp");
        shader_move_step.add_abs_resource(gen_height) catch unreachable;
    }

    exe.step.dependOn(&shader_comp.step);
    exe.step.dependOn(&shader_move_step.step);

    // link tracy if in debug mode and nothing else is specified
    const enable_tracy = b.option(bool, "tracy", "Enable tracy bindings and communication, default is false") orelse false;
    var tracy_path = if (enable_tracy) @as([]const u8, "deps/Zig-Tracy/tracy-0.7.8") else null;
    tracy.link(b, exe, tracy_path);

    const asset_move = AssetMoveStep.init(b) catch unreachable;
    exe.step.dependOn(&asset_move.step);

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    var tests = b.addTest("src/test.zig");
    tests.setBuildMode(mode);

    tests.addPackagePath("glfw", "deps/mach-glfw/src/main.zig");
    tests.addPackagePath("zalgebra", "deps/zalgebra/src/main.zig");

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}
