const std = @import("std");
const fs = std.fs;
const vkgen = @import("deps/vulkan-zig/generator/index.zig");

const LibExeObjStep = std.build.LibExeObjStep;
const Builder = std.build.Builder;
const Step = std.build.Step;
const ArrayList = std.ArrayList;

const MoveDirError = error {
    NotFound
};

const ShaderMoveStep = struct {
    step: Step,
    builder: *Builder,

    abs_from: [2]?[]const u8 = [_]?[]const u8{null} ** 2,
    abs_len: usize = 0,

    fn init(b: *Builder, shader_step: *vkgen.ShaderCompileStep) !*ShaderMoveStep {
        var step = Step.init(.custom, "resource", b.allocator, make);
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

        if (fs.makeDirAbsolute(self.builder.install_prefix)) |_| {
            // ok
        } else |err| switch(err) {
            std.os.MakeDirError.PathAlreadyExists => {},
            else => |e| std.debug.panic("got error when creating zig_out: {}", .{e}),
        }

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
        const SplitPath = struct {
            dir: []const u8,
            file_name: []const u8,
        };

        const path_and_file = struct {
            inline fn func(file_path: []const u8) !SplitPath {
                var i = file_path.len - 1;
                while (i > 0) : (i -= 1) {
                    if (file_path[i] == '/') {
                        return SplitPath{
                            .dir = file_path[0..i],
                            .file_name = file_path[i+1..file_path.len],
                        };
                    }
                }
                return MoveDirError.NotFound;
            }
        }.func;
        
        const old_path = try path_and_file(abs_from);
        var old_dir = try fs.openDirAbsolute(old_path.dir, .{});
        defer old_dir.close();

        var new_dir = try fs.openDirAbsolute(self.builder.install_prefix, .{});
        defer new_dir.close();

        const join_arr = [_][]const u8 {old_path.file_name, "spv" };
        const new_file_name = try std.mem.join(self.*.builder.allocator, ".", join_arr[0..join_arr.len]);
        self.*.builder.allocator.destroy(new_file_name.ptr);

        try fs.rename(old_dir, old_path.file_name, new_dir, new_file_name);
    }
};


pub fn build(b: *Builder) void {
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
        .linux => {
            exe.linkSystemLibrary("glfw");
        },
        else => |platform| {
            std.debug.panic("{} is currently not supported", .{platform});
        }
    }
    
    exe.linkLibC();

    exe.addPackagePath("ecs", "deps/zig-ecs/src/ecs.zig");
    exe.addPackagePath("zalgebra", "deps/zalgebra/src/main.zig");

    const vk_xml_path = b.option([]const u8, "vulkan-registry", "Override to the Vulkan registry") orelse "deps/vk.xml";
    const gen = vkgen.VkGenerateStep.init(b, vk_xml_path, "vk.zig");
    exe.step.dependOn(&gen.step);
    exe.addPackage(gen.package);
    
    const shader_comp = vkgen.ShaderCompileStep.init(
        b,
        // TODO: -O (optimize), -I (includes) 
        &[_][]const u8{"glslc", "--target-env=vulkan1.2"}, 
    );
    const resource_step = ShaderMoveStep.init(b, shader_comp) catch unreachable;

    const vert = shader_comp.add("assets/shaders/triangle.vert");
    resource_step.add_abs_resource(vert) catch unreachable;

    const frag = shader_comp.add("assets/shaders/triangle.frag");
    resource_step.add_abs_resource(frag) catch unreachable;

    exe.step.dependOn(&shader_comp.step);
    exe.step.dependOn(&resource_step.step);

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

   
}
