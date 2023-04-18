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
const ztracy = @import("deps/ztracy/build.zig");
const zgui = @import("deps/zgui/build.zig");

// TODO: this file could use a refactor pass or atleast some comments to make it more readable

const MoveDirError = error{NotFound};

/// Holds the path to a file where parent directory and file name is separated
const SplitPath = struct {
    dir: []const u8,
    file_name: []const u8,
};

inline fn pathAndFile(file_path: []const u8) MoveDirError!SplitPath {
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
        var step = Step.init(.{ .id = .custom, .name = "shader_resource", .owner = b, .makeFn = make });
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

    fn make(step: *Step, prog_node: *std.Progress.Node) anyerror!void {
        const self: *ShaderMoveStep = @fieldParentPtr(ShaderMoveStep, "step", step);

        try createFolder(self.builder.install_prefix);

        for (self.abs_from) |from| {
            if (from) |some| {
                try self.moveShaderToOut(some);
            } else {
                break;
            }
        }
        prog_node.completeOne();
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
        var step = Step.init(.{ .id = .custom, .name = "assets", .owner = b, .makeFn = make });

        const self = try b.allocator.create(AssetMoveStep);
        self.* = .{
            .step = step,
            .builder = b,
        };

        return self;
    }

    fn make(step: *Step, prog_node: *std.Progress.Node) anyerror!void {
        const self: *AssetMoveStep = @fieldParentPtr(AssetMoveStep, "step", step);

        try createFolder(self.builder.install_prefix);

        const dst_asset_path = blk: {
            const dst_asset_path_arr = [_][]const u8{ self.builder.install_prefix, "assets" };
            break :blk try std.fs.path.join(self.builder.allocator, dst_asset_path_arr[0..]);
        };
        try createFolder(dst_asset_path);
        var dst_assets_dir = try fs.openDirAbsolute(dst_asset_path, .{});
        defer dst_assets_dir.close();

        var src_assets_dir = try fs.cwd().openIterableDir("assets/", .{
            .access_sub_paths = true,
        });
        defer src_assets_dir.close();

        copyDir(self.builder, src_assets_dir, dst_assets_dir);

        prog_node.completeOne();
    }
};

// TODO: HACK: catch unreachable to avoid error hell from recursion
fn copyDir(b: *Builder, src_dir: fs.IterableDir, dst_parent_dir: fs.Dir) void {
    const Kind = fs.File.Kind;

    var walker = src_dir.walk(b.allocator) catch unreachable;
    defer walker.deinit();
    while (walker.next() catch unreachable) |asset| {
        switch (asset.kind) {
            Kind.Directory => {
                var src_child_dir = src_dir.dir.openIterableDir(asset.path, .{
                    .access_sub_paths = true,
                }) catch unreachable;
                defer src_child_dir.close();

                dst_parent_dir.makeDir(asset.path) catch |err| switch (err) {
                    std.os.MakeDirError.PathAlreadyExists => {}, // ok
                    else => unreachable,
                };
                var dst_child_dir = dst_parent_dir.openDir(asset.path, .{}) catch unreachable;
                defer dst_child_dir.close();
            },
            Kind.File => {
                if (std.mem.eql(u8, asset.path[0..7], "shaders")) {
                    continue; // skip shader folder which will be compiled by glslc before being moved
                }
                src_dir.dir.copyFile(asset.path, dst_parent_dir, asset.path, .{}) catch unreachable;
            },
            else => {}, // don't care
        }
    }
}

inline fn createFolder(path: []const u8) std.os.MakeDirError!void {
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
    const mode = b.standardOptimizeOption(.{});

    var exe = b.addExecutable(.{
        .name = "zig_vulkan",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    exe.linkLibC();

    // compile and link with glfw statically
    const glfw_module = glfw.module(b);
    exe.addModule("glfw", glfw_module);
    glfw.link(b, exe, .{}) catch @panic("failed to link glfw");

    exe.addModule("zalgebra", b.createModule(.{
        .source_file = .{ .path = "deps/zalgebra/src/main.zig" },
    }));

    stbi.linkStep(b, exe);

    const vk_xml_path = b.option([]const u8, "vulkan-registry", "Override to the Vulkan registry") orelse thisDir() ++ "/deps/vk.xml";
    const gen = vkgen.VkGenerateStep.create(b, vk_xml_path);
    // Add the generated file as package to the final executable
    exe.addModule("vulkan", gen.getModule());

    // TODO: -O (optimize), -I (includes)
    //  !always have -g as last entry! (see glslc_len definition)
    const include_shader_debug = b.option(bool, "shader-debug-info", "include shader debug info, default is false") orelse false;
    const glslc_flags = [_][]const u8{ "glslc", "--target-env=vulkan1.2", "-g" };
    const glslc_len = if (include_shader_debug) glslc_flags.len else glslc_flags.len - 1;
    const shader_comp = vkgen.ShaderCompileStep.create(
        b,
        glslc_flags[0..glslc_len],
        "-o",
    );
    const shader_move_step = ShaderMoveStep.init(b, shader_comp) catch unreachable;

    {
        shader_comp.add("image_vert_spv", "assets/shaders/image.vert", .{});
        shader_comp.add("image_frag_spv", "assets/shaders/image.frag", .{});
        shader_comp.add("ui_vert_spv", "assets/shaders/ui.vert", .{});
        shader_comp.add("ui_frag_spv", "assets/shaders/ui.frag", .{});
        shader_comp.add("brick_raytracer_comp_spv", "assets/shaders/brick_raytracer.comp", .{});
        shader_comp.add("height_map_gen_comp_spv", "assets/shaders/height_map_gen.comp", .{});
    }

    exe.step.dependOn(&shader_move_step.step);
    shader_move_step.step.dependOn(&shader_comp.step);
    exe.addModule("shaders", shader_comp.getModule());

    // link tracy if in debug mode and nothing else is specified
    const enable_tracy = b.option(bool, "tracy", "Enable tracy bindings and communication, default is false") orelse false;
    var ztracy_package = ztracy.package(b, target, mode, .{ .options = .{ .enable_ztracy = enable_tracy } });
    ztracy_package.link(exe);
    exe.addModule("ztracy", ztracy_package.ztracy);

    // link zgui
    const zgui_pkg = zgui.package(b, target, mode, .{
        .options = .{ .backend = .no_backend },
    });
    zgui_pkg.link(exe);
    exe.addModule("zgui", zgui_pkg.zgui);

    const asset_move = AssetMoveStep.init(b) catch unreachable;
    exe.step.dependOn(&asset_move.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/test.zig" },
        .optimize = mode,
    });

    tests.addModule("glfw", glfw_module);
    glfw.link(b, tests, .{}) catch @panic("failed to link glfw");
    tests.addModule("zalgebra", b.createModule(.{
        .source_file = .{ .path = "deps/zalgebra/src/main.zig" },
    }));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
