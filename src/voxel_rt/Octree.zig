const std = @import("std");
const Allocator = std.mem.Allocator;

const za = @import("zalgebra");

const gpu_t = @import("gpu_types.zig");
const Node = gpu_t.Node;
pub const Ints = gpu_t.Ints;
pub const Floats = gpu_t.Floats;

const IVec3 = @Vector(3, i32);
const Vec3 = @Vector(3, f32);
const Vec4 = @Vector(4, f32);

/// CPU abstraction for a GPU octree 
const Octree = @This();

allocator: Allocator,
active_cell_count: u32,
indirect_cells: []Node,
indirect_cell_dim: Vec3,

dimensions: Vec3,

floats: Floats,
ints: Ints,

pub fn init(allocator: Allocator, cell_count: i32, floats: Floats, ints: Ints) !Octree {
    var my_floats = floats;
    my_floats.inv_cell_count = 1.0 / @intToFloat(f32, cell_count);

    var my_ints = ints;
    my_ints.cell_count = cell_count;

    const indirect_cells = try allocator.alloc(Node, @intCast(usize, cell_count * 8));
    errdefer allocator.free(indirect_cells);
    std.mem.set(Node, indirect_cells, .{ .@"type" = .empty, .value = 0 });

    return Octree{
        .allocator = allocator,
        .active_cell_count = 0,
        .dimensions = @splat(3, std.math.pow(f32, 2.0, @intToFloat(f32, my_ints.max_depth))),
        .indirect_cells = indirect_cells,
        .indirect_cell_dim = [3]f32{ @intToFloat(f32, my_ints.cell_count) * 2, 2.0, 2.0 },
        .floats = my_floats,
        .ints = my_ints,
    };
}

pub fn deinit(self: Octree) void {
    self.allocator.free(self.indirect_cells);
}

/// Insert a leaf node into the octree. 
/// Will also insert any parent nodes if needed.
/// @parameters:
///     - x: nth voxel in x axis
///     - y: nth voxel in y axis
///     - z: nth voxel in z axis
///     - value: the new value of leaf node at xyz
pub fn insert(self: *Octree, x: u32, y: u32, z: u32, value: u32) !void {
    const dim = @floatToInt(u32, self.dimensions[0]); // uniform dimension
    if (x >= dim or x < 0 or y >= dim or y < 0 or z >= dim or z < 0) {
        return error.IllegalCoordinate; // Coordinate out of bounds
    }

    // TODO: this function is failable (should return error)
    const visitor = struct {
        pub fn visit(
            octree: *Octree,
            node: *Node,
            depth: usize,
        ) Abort {
            if (node.@"type" != .parent and depth != octree.ints.max_depth - 1) {
                octree.active_cell_count += 1;
                node.@"type" = .parent;
                node.value = octree.active_cell_count;
            }
            return .no;
        }
    }.visit;
    const uvs = za.Vec3.new(@intToFloat(f32, x), @intToFloat(f32, y), @intToFloat(f32, z)) / self.dimensions;
    const index = self.traverse(visitor, &uvs);

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
    const half = @splat(3, @as(f32, 0.49999));
    const two = @splat(3, @as(f32, 2));

    var depth_coords: Vec3 = at.*;
    var node = Node{
        .@"type" = Node.Type.empty,
        .value = 0,
    };

    // var inv_pow_depth: f32 = 1;
    // var grid_uv = za.Vec3.zero();

    var index: usize = 0;
    var i: usize = 0;
    while (i < self.ints.max_depth) : (i += 1) {
        // inv_pow_depth = inv_pow_depth * 0.5;
        var point_uv = depth_coords - @floor(depth_coords);
        point_uv[0] = (@intToFloat(f32, node.value) + point_uv[0]) * self.floats.inv_cell_count;

        var pointf = @round(point_uv * self.indirect_cell_dim - half);
        const point: IVec3 = [3]i32{ @floatToInt(i32, pointf[0]), @floatToInt(i32, pointf[1]), @floatToInt(i32, pointf[2]) };
        index = @intCast(usize, point[2] + 2 * (point[1] + 2 * point[0]));

        // grid_uv += za.Vec3.scale(@mod(pointf, za.Vec3.new(2, 2, 2)), inv_pow_depth);

        // const cell = @floor(@intToFloat(f32, index) * @as(f32, 1.0 / 8.0));
        // std.debug.print("cell: {d}\n", .{cell});

        // call visitor function inline
        const abort = @call(.{ .modifier = .always_inline }, visitor, .{ self, &self.indirect_cells[index], i });
        if (abort == .yes) {
            break;
        }
        node = self.indirect_cells[index];
        depth_coords *= two;
    }
    // std.debug.print("grid_uv: {d} {d} {d}\n", .{ grid_uv[0], grid_uv[1], grid_uv[2] });
    return index;
}

test "Octree init works" {
    const expect = Octree{
        .allocator = std.testing.allocator,
        .active_cell_count = 0,
        .indirect_cells = try std.testing.allocator.alloc(Node, 1),
        .indirect_cell_dim = [3]f32{ 2, 2, 2 },
        .dimensions = @splat(3, std.math.pow(f32, 2.0, 2.0)),
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
    const floats = Floats.init(min_point, expect.floats.scale);
    const ints = Ints.init(expect.ints.max_depth, expect.ints.max_iter);

    var octree = try Octree.init(std.testing.allocator, expect.ints.cell_count, floats, ints);
    defer octree.deinit();

    // HACK: comparing two slices will fail since .ptr will be unique ...
    expect.allocator.free(octree.indirect_cells);
    octree.indirect_cells = expect.indirect_cells;
    try std.testing.expectEqual(expect, octree);
}

test "Octree insert works" {
    const min_point = za.Vec3.new(-0.5, -0.5, -1.0);

    var octree = try Octree.init(std.testing.allocator, 8 * 5, Floats.init(min_point, 1.0), Ints.init(2, 10));
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
        octree.insert(0, 0, 0, child.value);

        try std.testing.expectEqual(octree.indirect_cells[0], parent);
        try std.testing.expectEqual(octree.indirect_cells[8], child);
    }

    {
        const parent = Node{
            .@"type" = .parent,
            .value = 1,
        };
        const child = Node{
            .@"type" = .leaf,
            .value = 420,
        };
        octree.insert(1, 0, 0, child.value);

        try std.testing.expectEqual(octree.indirect_cells[0], parent);
        try std.testing.expectEqual(octree.indirect_cells[12], child);
    }

    {
        const parent = Node{
            .@"type" = .parent,
            .value = 2,
        };
        const child = Node{
            .@"type" = .leaf,
            .value = 1,
        };
        octree.insert(0, 2, 0, child.value);

        try std.testing.expectEqual(octree.indirect_cells[2], parent);
        try std.testing.expectEqual(octree.indirect_cells[16], child);
    }
}
