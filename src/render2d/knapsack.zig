// This file contains code to help merge images into one single image aka. [the knapsack problem](https://en.wikipedia.org/wiki/Knapsack_problem). 
// Source: https://www.david-colson.com/2020/03/10/exploring-rect-packing.html

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rectangle = @import("util_types.zig").Rectangle;

pub const PackJob = struct {
    // set by caller of pack function
    id: usize, 
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const BruteForceFunction = fn(*Allocator, []PackJob, u32, u32) BrutePackError!CalculatedImageSize;

fn sortByHeight(context: void, lhs: PackJob, rhs: PackJob) bool {
    _ = context;
    return lhs.height < rhs.height;
}

// TODO: pixelScanPack() might be viable to optimize depending on the load time 

pub const CalculatedImageSize = struct {
    width: u64,
    height: u64,
};
pub const BrutePackError = PackError || error {
    InsufficentWidth,
    InsufficentHeight,
};
/// Brute force to find *functional* width and height (not optimal)
/// return type of produced function is BrutePackError!CalculatedImageSize
pub fn InitBruteForceWidthHeightFn(comptime use_restrictions: bool) type {
    comptime var Validator: type = undefined;
    if (use_restrictions) {
        Validator = struct {
            pub inline fn validate(max: u32, value: u32, rtr_error: BrutePackError) BrutePackError!void {
                if (max < value) {
                    return rtr_error;
                }
            }
        };
    } else {
        Validator = struct {
             pub inline fn validate(max: u32, value: u32, rtr_error: BrutePackError) BrutePackError!void {
                _ = max;
                _ = value;
                rtr_error catch {};
                return;
            }
        };
    }
    const BruteForcer = struct {
        pub fn bruteForceWidthHeight(allocator: *Allocator, packages: []PackJob, max_image_width: u32, max_image_height: u32) BrutePackError!CalculatedImageSize {
            var image_height: u32 = 0;
            var max_height_index: usize = 0;

            var image_width: u32 = 0;
            var max_width_index: usize = 0;

            for (packages) |package, i| {
                if (image_width < package.width) {
                    image_width = package.width;
                    max_width_index = i;
                }
                if (image_height < package.height) {
                    image_height = package.height;
                    max_height_index = i;
                }
            }

            try Validator.validate(max_image_width, image_width, BrutePackError.InsufficentWidth);
            try Validator.validate(max_image_height, image_height, BrutePackError.InsufficentHeight);

            var solved = false;
            var add_width = true;
            var add_width_index: usize = if (max_width_index != packages.len - 1) max_width_index + 1 else 0;
            var add_height_index: usize = if (max_height_index != packages.len - 1) max_image_height + 1 else 0;
            while(!solved) {
                if (pixelScanPack(allocator, image_width, image_height, packages)) |_| {
                    solved = true;
                } else |err| {
                    switch (err) {
                        PackError.InsufficentSpace => {
                            if (add_width) {
                                image_width += packages[add_width_index].width; 
                                add_width_index = (add_width_index + 1) % packages.len;
                                try Validator.validate(max_image_width, image_width, BrutePackError.InsufficentWidth);
                            } else {
                                image_height += packages[add_height_index].height; 
                                add_height_index = (add_height_index + 1) % packages.len;
                                try Validator.validate(max_image_height, image_height, BrutePackError.InsufficentHeight);
                            }
                            add_width = !add_width;
                        },
                        PackError.OutOfMemory => return BrutePackError.OutOfMemory,
                    }
                }
            }
            return CalculatedImageSize{
                .width = image_width,
                .height = image_height,
            };
        }
    };

    if(use_restrictions) {
        return BruteForcer.bruteForceWidthHeight;
    } else {
        return struct {
            pub inline fn bruteForceWidthHeight(allocator: *Allocator, packages: []PackJob) BrutePackError!CalculatedImageSize {
                return BruteForcer.bruteForceWidthHeight(allocator, packages, 0, 0);
            }
        };
    }
}


pub const PackError = Allocator.Error || error {
    InsufficentSpace,
};
/// attempts to pack a slice of rectangles through brute force. This method is slower than others, but should have the best 
/// packing efficeny
/// !caller should note that parameter slice will mutate!
pub fn pixelScanPack(allocator: *Allocator, image_width: u32, image_height: u32, packjobs: []PackJob) PackError!void {

    // sort rectangles by height
    std.sort.sort(PackJob, packjobs, {}, sortByHeight);

    const image_size = image_width * image_height;

    var image_map = try allocator.alloc(bool, image_size);
    defer allocator.free(image_map);

    image_map.len = image_size;
    std.mem.set(bool, image_map, false);

    // loop rectangles
    for (packjobs) |*packjob| {
        var was_packed = false;

        // loop mega texture pixels
        im_loop: for (image_map) |pixel, i| {
            const x = i % image_width; 
            const y = i / image_width; 

            const x_bound = x + (packjob.width - 1);
            const y_bound = y + (packjob.height - 1);
            
            // Check if rectangle doesn't go over the edge of the boundary
            if (x_bound >= image_width or y_bound >= image_height) {
                continue :im_loop;
            }

            // For every coordinate, check top left and bottom right, if set, skip
            const end_index = y_bound * image_width + x_bound;
            if (pixel or image_map[end_index]) {
                continue :im_loop;
            }

            {   // Check all pixels inside rectangle if we have a valid slot
                var iy = y;  
                while (iy <= y_bound) : (iy += 1) {
                    const y_element = iy * image_width;

                    var ix = x;
                    while (ix <= x_bound) : (ix += 1) {
                        const index = y_element + ix;
                        if (image_map[index]) {
                            continue :im_loop; // skip, occupied 
                        }
                    }
                }
            }

            // All pixels were cleared so we can place current rectangle
            packjob.x = @intCast(u32, x);
            packjob.y = @intCast(u32, y);
            was_packed = true;

            // update image map to mark pixels as occupied
            var iy = y;
            while (iy <= y_bound) : (iy += 1) {
                const y_element = iy * image_width;

                var ix = x;
                while (ix <= x_bound) : (ix += 1) {
                    const index = y_element + ix;
                    image_map[index] = true;
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
    const rectangles = try allocator.alloc(PackJob, 4);
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
    const rectangles = try allocator.alloc(PackJob, 2);
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
    const rectangles = try allocator.alloc(PackJob, 3);
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
    const rectangles = try allocator.alloc(PackJob, 2);
    defer allocator.free(rectangles);

    rectangles[0].width = 1;
    rectangles[0].height = 1;
    rectangles[1].width = 1;
    rectangles[1].height = 1;

    try std.testing.expectError(PackError.InsufficentSpace, pixelScanPack(allocator, 1, 1, rectangles));
}
