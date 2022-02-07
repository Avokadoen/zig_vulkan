// This code is directly taken from ray tracing the next week
//  - https://raytracing.github.io/books/RayTracingTheNextWeek.html#perlinnoise
// The original source is c++ and changes have been made to accomodate Zig

const std = @import("std");

// TODO: point_count might have to be locked to exp of 2 i.e 2^8
pub fn PerlinNoiseGenerator(comptime point_count: u32) type {
    // TODO: argument and input validation on PermInt & NoiseFloat
    const PermInt: type = i32;
    const NoiseFloat: type = f64;

    return struct {
        const Perlin = @This();

        rand_float: [point_count]NoiseFloat,
        perm_x: [point_count]PermInt,
        perm_y: [point_count]PermInt,
        perm_z: [point_count]PermInt,
        rng: std.rand.Random,

        pub fn init(seed: u64) Perlin {
            const rng = std.rand.DefaultPrng.init(seed).random();
            const generate_perm_fn = struct {
                inline fn generate_perm(random: std.rand.Random) [point_count]PermInt {
                    var perm: [point_count]PermInt = undefined;
                    // TODO: replace for with while to avoid casting in loop
                    for (perm) |*p, i| {
                        p.* = @intCast(PermInt, i);
                    }

                    {
                        var i: usize = point_count - 1;
                        while (i > 0) : (i -= 1) {
                            const target = random.intRangeLessThan(usize, 0, i);
                            const tmp = perm[i];
                            perm[i] = perm[target];
                            perm[target] = tmp;
                        }
                    }
                    return perm;
                }
            }.generate_perm;

            var rand_float: [point_count]NoiseFloat = undefined;
            for (rand_float) |*float| {
                float.* = rng.float(NoiseFloat);
            }
            const perm_x = generate_perm_fn(rng);
            const perm_y = generate_perm_fn(rng);
            const perm_z = generate_perm_fn(rng);

            return Perlin{
                .rand_float = rand_float,
                .perm_x = perm_x,
                .perm_y = perm_y,
                .perm_z = perm_z,
                .rng = rng,
            };
        }

        pub fn noise(self: Perlin, comptime PointType: type, point: [3]PointType) NoiseFloat {
            comptime {
                const info = @typeInfo(PointType);
                switch (info) {
                    .Float => {},
                    else => @compileError("PointType must be a float type"),
                }
            }

            const and_value = point_count - 1;
            const i = @floatToInt(usize, 4 * point[0]) & and_value;
            const j = @floatToInt(usize, 4 * point[2]) & and_value;
            const k = @floatToInt(usize, 4 * point[1]) & and_value;

            return self.rand_float[@intCast(usize, self.perm_x[i] ^ self.perm_y[j] ^ self.perm_z[k])];
        }

        pub fn smoothNoise(self: Perlin, comptime PointType: type, point: [3]PointType) NoiseFloat {
            comptime {
                const info = @typeInfo(PointType);
                switch (info) {
                    .Float => {},
                    else => @compileError("PointType must be a float type"),
                }
            }

            var c: [2][2][2]NoiseFloat = undefined;
            {
                const and_value = point_count - 1;

                const i = @floatToInt(usize, @floor(point[0]));
                const j = @floatToInt(usize, @floor(point[1]));
                const k = @floatToInt(usize, @floor(point[2]));
                var di: usize = 0;
                while (di < 2) : (di += 1) {
                    var dj: usize = 0;
                    while (dj < 2) : (dj += 1) {
                        var dk: usize = 0;
                        while (dk < 2) : (dk += 1) {
                            c[di][dj][dk] = self.rand_float[
                                // zig fmt: off
                                @intCast(usize, 
                                    self.perm_x[(i + di) & and_value] ^ 
                                    self.perm_y[(j + dj) & and_value] ^ 
                                    self.perm_z[(k + dk) & and_value]
                                )
                                // zig fmt: on
                            ];
                        }
                    }
                }
            }

            const u = blk: {
                const tmp = point[0] - @floor(point[0]);
                break :blk tmp * tmp * (3 - 2 * tmp);
            };
            const v = blk: {
                const tmp = point[1] - @floor(point[1]);
                break :blk tmp * tmp * (3 - 2 * tmp);
            };
            const w = blk: {
                const tmp = point[2] - @floor(point[2]);
                break :blk tmp * tmp * (3 - 2 * tmp);
            };

            // perform trilinear filtering
            var accum: NoiseFloat = 0;
            {
                var i: usize = 0;
                while (i < 2) : (i += 1) {
                    const fi = @intToFloat(NoiseFloat, i);
                    var j: usize = 0;
                    while (j < 2) : (j += 1) {
                        const fj = @intToFloat(NoiseFloat, j);
                        var k: usize = 0;
                        while (k < 2) : (k += 1) {
                            const fk = @intToFloat(NoiseFloat, k);
                            accum += (fi * u + (1 - fi) * (1 - u)) *
                                (fj * v + (1 - fj) * (1 - v)) *
                                (fk * w + (1 - fk) * (1 - w)) * c[i][j][k];
                        }
                    }
                }
            }
            return accum;
        }
    };
}
