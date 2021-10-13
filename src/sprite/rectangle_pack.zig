// This file contains code to help merge images into one single image aka. [the knapsack problem](https://en.wikipedia.org/wiki/Knapsack_problem). 
// Source: https://www.david-colson.com/2020/03/10/exploring-rect-packing.html

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rectangle = struct {
    // set by caller of pack function
    id: usize, 
    width: u32, 
    height: u32,

    // set by pack function
    x: usize,    
    y: usize,
};

pub const PackError = error {
    InsufficentSpace,
};

fn sortByHeight(context: void, lhs: Rectangle, rhs: Rectangle) bool {
    _ = context;
    return lhs.height < rhs.height;
}

// TODO: pixelScanPack() might be viable to optimize depending on the load time 

/// attempts to pack a slice of rectangles through brute force. This method is slower than others, but should have the best 
/// packing efficeny
/// !caller should note that parameter slice will mutate!
pub fn pixelScanPack(allocator: *Allocator, image_width: u32, image_height: u32, rectangles: []Rectangle) !void {

    // sort rectangles by height
    std.sort.sort(Rectangle, rectangles, {}, sortByHeight);

    const image_size = image_width * image_height;

    var image_map = try std.ArrayList(bool).initCapacity(allocator, image_size);
    defer image_map.deinit();

    // we have a image of empty pixels (false), this might technically be UB since each
    // entries can be set to undefined, but from testing zig seems to set them to false 
    // so in current zig version we are good :)
    image_map.items.len = image_size;

    // loop rectangles
    for (rectangles) |*rect| {
        var was_packed = false;
        // loop mega texture pixels
        im_loop: for (image_map.items) |pixel, i| {
            const x = i % image_width; 
            const y = i / image_width; 

            const x_bound = x + (rect.width - 1);
            const y_bound = y + (rect.height - 1);
            
            // Check if rectangle doesn't go over the edge of the boundary
            if (x_bound >= image_width or y_bound >= image_height) {
                continue :im_loop;
            }

            // For every coordinate, check top left and bottom right, if set, skip
            const end_index = y_bound * image_width + x_bound;
            if (pixel or image_map.items[end_index]) {
                continue :im_loop;
            }

            {   // Check all pixels inside rectangle if we have a valid slot
                var iy = y;  
                while (iy <= y_bound) : (iy += 1) {
                    const y_element = iy * image_width;

                    var ix = x;
                    while (ix <= x_bound) : (ix += 1) {
                        const index = y_element + ix;
                        if (image_map.items[index]) {
                            continue :im_loop; // skip, occupied 
                        }
                    }
                }
            }

            // All pixels were cleared so we can place current rectangle
            rect.x = x;
            rect.y = y;
            was_packed = true;

            // update image map to mark pixels as occupied
            var iy = y;
            while (iy <= y_bound) : (iy += 1) {
                const y_element = iy * image_width;

                var ix = x;
                while (ix <= x_bound) : (ix += 1) {
                    const index = y_element + ix;
                    image_map.items[index] = true;
                }
            }

            break :im_loop;
        }

        // current rectangle was never placed in the image
        if (was_packed == false) {
            return PackError.InsufficentSpace; // the image size is less than the best sum of rectangle sizes
        }
    }
}


test "symmetric square pixelScanPack" {
    const allocator = std.testing.allocator;
    const rectangles = try allocator.alloc(Rectangle, 4);
    defer allocator.free(rectangles);

    for (rectangles) |*rect| {
        rect.width = 1;
        rect.height = 1;
    }

    try pixelScanPack(allocator, 2, 2, rectangles);
    
    try std.testing.expectEqual(@as(usize, 0), rectangles[0].x);
    try std.testing.expectEqual(@as(usize, 0), rectangles[0].y);

    try std.testing.expectEqual(@as(usize, 1), rectangles[1].x);
    try std.testing.expectEqual(@as(usize, 0), rectangles[1].y);

    try std.testing.expectEqual(@as(usize, 0), rectangles[2].x);
    try std.testing.expectEqual(@as(usize, 1), rectangles[2].y);
    
    try std.testing.expectEqual(@as(usize, 1), rectangles[3].x);
    try std.testing.expectEqual(@as(usize, 1), rectangles[3].y);
}

test "asymmetric square pixelScanPack" {
    const allocator = std.testing.allocator;
    const rectangles = try allocator.alloc(Rectangle, 2);
    defer allocator.free(rectangles);

    rectangles[0].width = 1;
    rectangles[0].height = 2;
    rectangles[1].width = 3;
    rectangles[1].height = 4;
 
    try pixelScanPack(allocator, 4, 4, rectangles);

    try std.testing.expectEqual(@as(usize, 0), rectangles[0].x);
    try std.testing.expectEqual(@as(usize, 0), rectangles[0].y);
    
    try std.testing.expectEqual(@as(usize, 1), rectangles[1].x);
    try std.testing.expectEqual(@as(usize, 0), rectangles[1].y);
}

test "asymmetric square full pixelScanPack" {
    const allocator = std.testing.allocator;
    const rectangles = try allocator.alloc(Rectangle, 3);
    defer allocator.free(rectangles);

    rectangles[0].width = 3;
    rectangles[0].height = 1;
    rectangles[1].width = 4;
    rectangles[1].height = 3;
    rectangles[2].width = 1;
    rectangles[2].height = 1;

    try pixelScanPack(allocator, 4, 4, rectangles);

    try std.testing.expectEqual(@as(usize, 0), rectangles[0].x);
    try std.testing.expectEqual(@as(usize, 0), rectangles[0].y);
    
    try std.testing.expectEqual(@as(usize, 3), rectangles[1].x);
    try std.testing.expectEqual(@as(usize, 0), rectangles[1].y);

    try std.testing.expectEqual(@as(usize, 0), rectangles[2].x);
    try std.testing.expectEqual(@as(usize, 1), rectangles[2].y);
}

test "InsufficentSpace error in event of insufficent space" {
    const allocator = std.testing.allocator;
    const rectangles = try allocator.alloc(Rectangle, 2);
    defer allocator.free(rectangles);

    rectangles[0].width = 1;
    rectangles[0].height = 1;
    rectangles[1].width = 1;
    rectangles[1].height = 1;

    try std.testing.expectError(PackError.InsufficentSpace, pixelScanPack(allocator, 1, 1, rectangles));
}
