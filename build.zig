const std = @import("std");
const fs = std.fs;
const os = std.os;

const Build = std.Build;
const Step = std.Build.Step;
const ArrayList = std.ArrayList;

pub fn build(b: *Build) void {
    // link tracy if in debug mode and nothing else is specified
    const options = .{
        .enable_ztracy = b.option(
            bool,
            "enable_ztracy",
            "Enable Tracy profile markers",
        ) orelse false,
        .enable_fibers = b.option(
            bool,
            "enable_fibers",
            "Enable Tracy fiber support",
        ) orelse false,
        .on_demand = b.option(
            bool,
            "on_demand",
            "Build tracy with TRACY_ON_DEMAND",
        ) orelse false,
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var exe = b.addExecutable(.{
        .name = "zig_vulkan",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();

    const zalgebra = b.dependency("zalgebra", .{});
    exe.root_module.addImport("zalgebra", zalgebra.module("zalgebra"));

    const zstbi = b.dependency("zstbi", .{});
    exe.root_module.addImport("zstbi", zstbi.module("root"));

    const vk_xml_path = b.option([]const u8, "vulkan-registry", "Override to the Vulkan registry") orelse "deps/vk.xml";
    const vulkan = b.dependency("vulkan_zig", .{
        .registry = b.path(vk_xml_path),
    });
    exe.root_module.addImport("vulkan", vulkan.module("vulkan-zig"));

    {
        addShaderModule(b, exe, optimize, "assets/shaders/image.vert", "image_vert");
        addShaderModule(b, exe, optimize, "assets/shaders/image.frag", "image_frag");
        addShaderModule(b, exe, optimize, "assets/shaders/ui.vert", "ui_vert");
        addShaderModule(b, exe, optimize, "assets/shaders/ui.frag", "ui_frag");
        addShaderModule(b, exe, optimize, "assets/shaders/brick_raytracer.comp", "brick_raytracer_comp");
        // addShaderModule(b, exe, optimize, "assets/shaders/height_map_gen.comp", "height_map_gen_comp");
    }

    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = options.enable_ztracy,
        .enable_fibers = options.enable_fibers,
        .on_demand = options.on_demand,
    });
    exe.root_module.addImport("ztracy", ztracy.module("root"));
    exe.linkLibrary(ztracy.artifact("tracy"));

    const ecez = b.dependency("ecez", .{});
    const ecez_module = ecez.module("ecez");
    exe.root_module.addImport("ecez", ecez_module);

    // link zgui
    const zgui = b.dependency("zgui", .{
        .shared = false,
        .with_implot = true,
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    // Link glfw
    const zglfw = b.dependency("zglfw", .{});
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));

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
        .root_source_file = b.path("src/test.zig"),
        .optimize = optimize,
    });

    tests.root_module.addImport("glfw", zglfw.module("root"));
    tests.linkLibrary(zglfw.artifact("glfw"));
    tests.root_module.addImport("zalgebra", zalgebra.module("zalgebra"));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}

fn addShaderModule(
    b: *Build,
    exe: *std.Build.Step.Compile,
    optimize: std.builtin.OptimizeMode,
    input_path: []const u8,
    comptime output_name: []const u8,
) void {
    const shader_path = compileShader(b, optimize, input_path, output_name ++ ".spv");

    exe.root_module.addAnonymousImport(output_name ++ "_spv", .{
        .root_source_file = shader_path,
    });
}

fn compileShader(
    b: *Build,
    optimize: std.builtin.OptimizeMode,
    input_path: []const u8,
    output_file_name: []const u8,
) std.Build.LazyPath {
    const shader_compiler = b.dependency("shader_compiler", .{});
    const compile_shader = b.addRunArtifact(shader_compiler.artifact("shader_compiler"));
    compile_shader.addArgs(&.{
        "--target", "Vulkan-1.3",
    });
    switch (optimize) {
        .Debug => compile_shader.addArgs(&.{
            "--robust-access",
        }),
        .ReleaseSafe => compile_shader.addArgs(&.{
            "--optimize-perf",
            "--robust-access",
        }),
        .ReleaseFast => compile_shader.addArgs(&.{
            "--optimize-perf",
        }),
        .ReleaseSmall => compile_shader.addArgs(&.{
            "--optimize-perf",
            "--optimize-size",
        }),
    }

    compile_shader.addArg("--include-path");
    compile_shader.addDirectoryArg(b.path("assets/shaders"));
    compile_shader.addArg("--write-deps");
    _ = compile_shader.addDepFileOutputArg("deps.d");

    compile_shader.addFileArg(b.path(input_path));
    return compile_shader.addOutputFileArg(output_file_name);
}

const AssetMoveStep = struct {
    step: Step,
    builder: *Build,

    fn init(b: *Build) !*AssetMoveStep {
        const self = try b.allocator.create(AssetMoveStep);
        self.* = .{
            .step = Step.init(.{ .id = .custom, .name = "assets", .owner = b, .makeFn = make }),
            .builder = b,
        };

        return self;
    }

    fn make(step: *Step, make_opt: Step.MakeOptions) anyerror!void {
        const self: *AssetMoveStep = @fieldParentPtr("step", step);

        var node = make_opt.progress_node.start("Asset move", 3);

        try createFolder(self.builder.install_prefix);
        node.setCompletedItems(1);

        const dst_asset_path = blk: {
            const dst_asset_path_arr = [_][]const u8{ self.builder.install_prefix, "assets" };
            break :blk try std.fs.path.join(self.builder.allocator, dst_asset_path_arr[0..]);
        };
        try createFolder(dst_asset_path);
        var dst_assets_dir = try fs.openDirAbsolute(dst_asset_path, .{});
        defer dst_assets_dir.close();
        node.setCompletedItems(2);

        var src_assets_dir = try fs.cwd().openDir("assets/", .{
            .access_sub_paths = true,
            .iterate = true,
        });
        defer src_assets_dir.close();
        copyDir(self.builder, src_assets_dir, dst_assets_dir);
        node.setCompletedItems(3);

        node.end();
    }
};

// TODO: HACK: catch unreachable to avoid error hell from recursion
fn copyDir(b: *Build, src_dir: fs.Dir, dst_parent_dir: fs.Dir) void {
    const Kind = fs.File.Kind;

    var walker = src_dir.walk(b.allocator) catch unreachable;
    defer walker.deinit();
    while (walker.next() catch unreachable) |asset| {
        switch (asset.kind) {
            Kind.directory => {
                var src_child_dir = src_dir.openDir(asset.path, .{
                    .access_sub_paths = true,
                    .iterate = true,
                }) catch unreachable;
                defer src_child_dir.close();

                dst_parent_dir.makeDir(asset.path) catch |err| switch (err) {
                    std.posix.MakeDirError.PathAlreadyExists => {}, // ok
                    else => unreachable,
                };
                var dst_child_dir = dst_parent_dir.openDir(asset.path, .{}) catch unreachable;
                defer dst_child_dir.close();
            },
            Kind.file => {
                if (std.mem.eql(u8, asset.path[0..7], "shaders")) {
                    continue; // skip shader folder which will be compiled by glslc before being moved
                }
                src_dir.copyFile(asset.path, dst_parent_dir, asset.path, .{}) catch unreachable;
            },
            else => {}, // don't care
        }
    }
}

inline fn createFolder(path: []const u8) std.posix.MakeDirError!void {
    if (fs.makeDirAbsolute(path)) |_| {
        // ok
    } else |err| switch (err) {
        std.posix.MakeDirError.PathAlreadyExists => {
            // ok
        },
        else => |e| return e,
    }
}
