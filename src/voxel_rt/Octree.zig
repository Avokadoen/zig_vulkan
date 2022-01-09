const std = @import("std");
const Allocator = std.mem.Allocator;

const za = @import("zalgebra");

const gpu_t = @import("gpu_types.zig");
const Node = gpu_t.Node;
const Ints = gpu_t.Ints;
const Floats = gpu_t.Floats;

const IVec3 = @Vector(3, i32);
const Vec3 = @Vector(3, f32);
const Vec4 = @Vector(4, f32);

/// CPU abstraction for a GPU octree 
const Octree = @This();

allocator: Allocator,
active_cell_count: u32,
indirect_cells: []Node,
indirect_cell_dim: Vec3,

floats: Floats,
ints: Ints,

pub fn init() Octree {
    @compileError("Octree.init() is not supported, use Octree.Builder or direct initialization instead");
}

pub fn deinit(self: Octree) void {
    self.allocator.free(self.indirect_cells);
}

/// Insert a leaf node into the octree. 
/// Will also insert any parent nodes if needed.
/// @parameters:
///     - at: xyz coordinates in range [0, 1]
///     - value: the new value of leaf node at xyz
pub fn insert(self: *Octree, at: *const Vec3, value: u32) void {
    // TODO: 1 is not a valid value because of wrap around and therefor not be what caller expect
    // TODO: this function is failable (should return error)
    const visitor = struct {
        pub fn visit(
            octree: *Octree,
            node: *Node,
            depth: usize,
        ) Abort {
            if (node.@"type" == .empty) {
                // TODO: avoid this if somehow
                if (depth != octree.ints.max_depth - 1) {
                    octree.active_cell_count += 1;
                    node.@"type" = .parent;
                    node.value = octree.active_cell_count;
                }
            }
            return .no;
        }
    }.visit;
    const index = self.traverse(visitor, at);

    self.indirect_cells[index] = Node{
        .@"type" = .leaf,
        .value = value,
    };
}

pub const Abort = enum { yes, no };
pub const VisitorFn = fn (octree: *Octree, node: *Node, depth: usize) Abort;

/// Traverse the octree and perform the VisitorFn in each node
/// @parameters:
///     - at: xyz coordinates in range [0, 1]
/// @return:
///     - node of index that called abort, or the leaf node of the coordinates if no abort
pub fn traverse(self: *Octree, comptime visitor: VisitorFn, at: *const Vec3) usize {
    const @"vec3(0.5)" = @splat(3, @as(f32, 0.4999));
    const @"vec3(2)" = @splat(3, @as(f32, 2));

    var depth_coords: Vec3 = at.*;
    var node = Node{
        .@"type" = Node.Type.empty,
        .value = 0,
    };

    var index: usize = 0;
    var i: usize = 0;
    while (i < self.ints.max_depth) : (i += 1) {
        var point_uv = depth_coords - @floor(depth_coords);
        point_uv[0] = (@intToFloat(f32, node.value) + point_uv[0]) * self.floats.inv_cell_count;

        const pointf = @round(point_uv * self.indirect_cell_dim - @"vec3(0.5)");
        const point: IVec3 = [3]i32{ @floatToInt(i32, pointf[0]), @floatToInt(i32, pointf[1]), @floatToInt(i32, pointf[2]) };
        index = @intCast(usize, point[2] + 2 * (point[1] + 2 * point[0]));

        // call visitor function inline
        const abort = @call(.{ .modifier = .always_inline }, visitor, .{ self, &self.indirect_cells[index], i });
        if (abort == .yes) {
            break;
        }
        if (self.indirect_cells[index].@"type" != .parent) {
            break;
        }
        node = self.indirect_cells[index];
        depth_coords *= @"vec3(2)";
    }

    return index;
}

pub const BuildError = error{
    MissingFloats,
    MissingInts,
} || Allocator.Error;
pub const Builder = struct {
    allocator: Allocator,
    floats: ?Floats,
    ints: ?Ints,

    pub inline fn init(allocator: Allocator) *Builder {
        // we can return pointer of stack memory since function is inline
        return &Builder{
            .allocator = allocator,
            .floats = null,
            .ints = null,
        };
    }

    pub fn withFloats(self: *Builder, min_point: Vec3, scale: f32) *Builder {
        self.*.floats = Floats{
            .min_point = [4]f32{ min_point[0], min_point[1], min_point[2], 0.0 },
            .scale = scale,
            .inv_scale = 1.0 / scale,
            .inv_cell_count = undefined,
        };
        return self;
    }

    pub fn withInts(self: *Builder, max_depth: i32, max_iter: i32) *Builder {
        self.*.ints = Ints{
            .max_depth = max_depth,
            .max_iter = max_iter,
            .cell_count = undefined,
        };
        return self;
    }

    /// Build octree from builder, will fail if any member is not initalized
    /// Caller must make sure to call Octree.deinit
    /// - cell_count: how many indirect cells should be allocated and transferable to the GPU, note GPU buffer size will be static
    pub inline fn build(self: *Builder, cell_count: i32) BuildError!Octree {
        if (self.*.floats) |*floats| {
            floats.inv_cell_count = 1.0 / @intToFloat(f32, cell_count);
        }
        if (self.*.ints) |*ints| {
            ints.cell_count = cell_count;
        }

        // unwrap octree values, or return corresponding error
        const floats = self.*.floats orelse return BuildError.MissingFloats;
        const ints = self.*.ints orelse return BuildError.MissingInts;

        const indirect_cells = try self.*.allocator.alloc(Node, @intCast(usize, cell_count * 8));
        errdefer self.*.allocator.free(indirect_cells);
        std.mem.set(Node, indirect_cells, .{ .@"type" = .empty, .value = 0 });

        return Octree{
            .allocator = self.*.allocator,
            .active_cell_count = 0,
            .indirect_cells = indirect_cells,
            .indirect_cell_dim = [3]f32{ @intToFloat(f32, ints.cell_count) * 2.0, 2.0, 2.0 },
            .floats = floats,
            .ints = ints,
        };
    }
};

test "Octree Build works" {
    const expect = Octree{
        .allocator = std.testing.allocator,
        .active_cell_count = 0,
        .indirect_cells = try std.testing.allocator.alloc(Node, 1),
        .indirect_cell_dim = [3]f32{ 2, 2, 2 },
        .floats = Floats{
            .min_point = za.Vec4.new(-0.5, -0.5, -1.0, 0.0),
            .scale = 1.0,
            .inv_scale = 1.0,
            .inv_cell_count = 1.0,
        },
        .ints = Ints{
            .max_depth = 2,
            .max_iter = 10,
            .cell_count = 1,
        },
    };

    const min_point: Vec3 = [3]f32{ expect.floats.min_point[0], expect.floats.min_point[1], expect.floats.min_point[2] };
    var builder = Octree.Builder.init(std.testing.allocator);
    var octree = try builder
        .withFloats(min_point, expect.floats.scale)
        .withInts(expect.ints.max_depth, expect.ints.max_iter)
        .build(expect.ints.cell_count);
    defer octree.deinit();

    // HACK: comparing two slices will fail since .ptr will be unique ...
    expect.allocator.free(octree.indirect_cells);
    octree.indirect_cells = expect.indirect_cells;
    try std.testing.expectEqual(expect, octree);
}

test "Octree insert works" {
    const min_point = za.Vec3.new(-0.5, -0.5, -1.0);

    var builder = Octree.Builder.init(std.testing.allocator);
    var octree = try builder
        .withFloats(min_point, 1.0)
        .withInts(2, 10)
        .build(8 * 5);
    defer octree.deinit();

    {
        const parent = Node{
            .@"type" = .parent,
            .value = 1,
        };
        const child = Node{
            .@"type" = .leaf,
            .value = 69,
        };
        octree.insert(&za.Vec3.zero(), child.value);

        try std.testing.expectEqual(octree.indirect_cells[0], parent);
        try std.testing.expectEqual(octree.indirect_cells[8], child);
    }

    {
        const parent = Node{
            .@"type" = .parent,
            .value = 2,
        };
        const child = Node{
            .@"type" = .leaf,
            .value = 420,
        };

        octree.insert(&za.Vec3.new(0.999, 0, 0), 420);

        try std.testing.expectEqual(octree.indirect_cells[4], parent);
        try std.testing.expectEqual(octree.indirect_cells[20], child);
    }
}
