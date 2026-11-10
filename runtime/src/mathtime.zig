//! skein.math's and skein.time's host functions (M1.12): what Phase 0 defines in Lisp
//! (host/src/runtime/math.lisp), with its results. The scalar functions call the system's
//! libm, as SBCL does, so floats come out the same; an f32 is computed as an f64 and
//! rounded, as SBCL does. core.zig's table includes these, named skein.math/<name> and
//! skein.time/<name>.

const std = @import("std");
const platform = @import("platform");
const rt = @import("rt.zig");
const num = @import("num.zig");
const ffi = @import("ffi.zig");
const Value = @import("value.zig").Value;

const Args = []const Value;
const Entry = struct { name: []const u8, min: u32, max: ?u32, impl: *const fn (Args) Value };

// ---------------------------------------------------------------------------------------
// libm

const Fn1 = *const fn (f64) callconv(.c) f64;
const Fn2 = *const fn (f64, f64) callconv(.c) f64;

/// The system libm's function `name`, looked up once. (Zig's own copies can differ from
/// libm in the last bit, and Phase 0 uses libm.)
fn libm(comptime T: type, comptime name: [:0]const u8, comptime fallback: T) T {
    // One cache per function: the struct depends on name, so each call site's differs.
    const S = struct {
        const function_name = name;
        var cached = std.atomic.Value(usize).init(0);
    };
    var a = S.cached.load(.acquire);
    if (a == 0) {
        a = ffi.symbol(name);
        if (a == 0) a = @intFromPtr(fallback);
        S.cached.store(a, .release);
    }
    return @ptrFromInt(a);
}

fn zigSin(x: f64) callconv(.c) f64 {
    return @sin(x);
}
fn zigCos(x: f64) callconv(.c) f64 {
    return @cos(x);
}
fn zigTan(x: f64) callconv(.c) f64 {
    return @tan(x);
}
fn zigAsin(x: f64) callconv(.c) f64 {
    return std.math.asin(x);
}
fn zigAcos(x: f64) callconv(.c) f64 {
    return std.math.acos(x);
}
fn zigAtan(x: f64) callconv(.c) f64 {
    return std.math.atan(x);
}
fn zigAtan2(y: f64, x: f64) callconv(.c) f64 {
    return std.math.atan2(y, x);
}
fn zigExp(x: f64) callconv(.c) f64 {
    return @exp(x);
}
fn zigLog(x: f64) callconv(.c) f64 {
    return @log(x);
}
fn zigPow(x: f64, y: f64) callconv(.c) f64 {
    return std.math.pow(f64, x, y);
}

// ---------------------------------------------------------------------------------------
// Scalars

/// x as a float (Phase 0's float-arg): floats stay as they are, integers become f64.
fn floatArg(name: []const u8, x: Value) Value {
    return switch (num.kind(x)) {
        .f32, .f64 => x,
        .int => num.boxF64(num.toF64(x)),
        .other => num.notANumber(name, x),
    };
}

/// `r`, computed as an f64, in the type of the float `like`.
fn asTypeOf(like: Value, r: f64) Value {
    return if (like.isF32()) Value.fromF32(@floatCast(r)) else num.boxF64(r);
}

fn unary(comptime name: []const u8, comptime f: fn () Fn1) fn (Args) Value {
    return struct {
        fn impl(a: Args) Value {
            const x = floatArg(name, a[0]);
            return asTypeOf(x, f()(num.toF64(x)));
        }
    }.impl;
}

fn sinFn() Fn1 {
    return libm(Fn1, "sin", zigSin);
}
fn cosFn() Fn1 {
    return libm(Fn1, "cos", zigCos);
}
fn tanFn() Fn1 {
    return libm(Fn1, "tan", zigTan);
}
fn asinFn() Fn1 {
    return libm(Fn1, "asin", zigAsin);
}
fn acosFn() Fn1 {
    return libm(Fn1, "acos", zigAcos);
}
fn atanFn() Fn1 {
    return libm(Fn1, "atan", zigAtan);
}
fn expFn() Fn1 {
    return libm(Fn1, "exp", zigExp);
}
fn logFn() Fn1 {
    return libm(Fn1, "log", zigLog);
}

/// Two floats' common type: f32 if both are, else f64 (CL's contagion).
fn bothF32(a: Value, b: Value) bool {
    return a.isF32() and b.isF32();
}

fn atan2Impl(a: Args) Value {
    const y = floatArg("atan2", a[0]);
    const x = floatArg("atan2", a[1]);
    const r = libm(Fn2, "atan2", zigAtan2)(num.toF64(y), num.toF64(x));
    return if (bothF32(y, x)) Value.fromF32(@floatCast(r)) else num.boxF64(r);
}

/// x to the integer power n by repeated squaring, in x's float type (as SBCL's expt).
fn floatIntPow(comptime T: type, x: T, n: Value) T {
    if (!n.isFixnum()) rt.raise(.unsupported_operation_error, "pow's exponent is too large", .{});
    var e: u64 = @abs(n.toFixnum());
    const negative = n.toFixnum() < 0;
    var base = x;
    var r: T = 1;
    while (e != 0) : (e >>= 1) {
        if (e & 1 != 0) r *= base;
        if (e > 1) base *= base;
    }
    return if (negative) 1 / r else r;
}

/// An integer to a non-negative integer power, exactly.
fn intPow(x: Value, n: Value) Value {
    if (!n.isFixnum()) rt.raise(.unsupported_operation_error, "pow's exponent is too large", .{});
    var e: u64 = @intCast(n.toFixnum());
    var base = x;
    var r = Value.fromFixnum(1);
    while (e != 0) : (e >>= 1) {
        if (e & 1 != 0) r = num.arith(.mul, r, base);
        if (e > 1) base = num.arith(.mul, base, base);
    }
    return r;
}

fn powImpl(a: Args) Value {
    const x = a[0];
    const y = a[1];
    const kx = num.kind(x);
    const ky = num.kind(y);
    if (kx == .other) num.notANumber("pow", x);
    if (ky == .other) num.notANumber("pow", y);
    if (kx == .int and ky == .int and (!y.isFixnum() or y.toFixnum() >= 0)) return intPow(x, y);
    const fx = floatArg("pow", x);
    if (ky == .int) {
        // A float to an integer power multiplies, as SBCL's expt does.
        return if (fx.isF32())
            Value.fromF32(floatIntPow(f32, fx.toF32(), y))
        else
            num.boxF64(floatIntPow(f64, num.toF64(fx), y));
    }
    const r = libm(Fn2, "pow", zigPow)(num.toF64(fx), num.toF64(y));
    return if (bothF32(fx, y)) Value.fromF32(@floatCast(r)) else num.boxF64(r);
}

const Rounding = enum { floor, ceil, trunc, round };

fn roundIn(comptime T: type, mode: Rounding, x: T) T {
    return switch (mode) {
        .floor => @floor(x),
        .ceil => @ceil(x),
        .trunc => @trunc(x),
        // Halves away from zero, as Phase 0's (ffloor (+ x 0.5)).
        .round => if (x < 0) -@floor(-x + 0.5) else @floor(x + 0.5),
    };
}

fn rounding(comptime name: []const u8, comptime mode: Rounding) fn (Args) Value {
    return struct {
        fn impl(a: Args) Value {
            const x = a[0];
            return switch (num.kind(x)) {
                .int => x,
                .f32 => Value.fromF32(roundIn(f32, mode, x.toF32())),
                .f64 => num.boxF64(roundIn(f64, mode, num.unboxF64(x))),
                .other => num.notANumber(name, x),
            };
        }
    }.impl;
}

// ---------------------------------------------------------------------------------------
// Improved Perlin noise (Ken Perlin, 2002), as Phase 0's perlin-noise

const permutation = [256]u8{
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225, 140, 36,  103, 30,  69,  142,
    8,   99,  37,  240, 21,  10,  23,  190, 6,   148, 247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203,
    117, 35,  11,  32,  57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175, 74,  165,
    71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122, 60,  211, 133, 230, 220, 105, 92,  41,
    55,  46,  245, 40,  244, 102, 143, 54,  65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,
    18,  169, 200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,  52,  217, 226, 250,
    124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212, 207, 206, 59,  227, 47,  16,  58,  17,  182, 189,
    28,  42,  223, 183, 170, 213, 119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
    129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104, 218, 246, 97,  228, 251, 34,
    242, 193, 238, 210, 144, 12,  191, 179, 162, 241, 81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,
    181, 199, 106, 157, 184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,  222, 114,
    67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
};

fn p(i: usize) usize {
    return permutation[i % 256];
}

fn fade(u: f64) f64 {
    return u * u * u * (u * (u * 6 - 15) + 10);
}

fn lerp(u: f64, a: f64, b: f64) f64 {
    return a + u * (b - a);
}

fn grad(hash: usize, x: f64, y: f64, z: f64) f64 {
    const h = hash & 15;
    const u = if (h < 8) x else y;
    const v = if (h < 4) y else if (h == 12 or h == 14) x else z;
    return (if (h & 1 == 0) u else -u) + (if (h & 2 == 0) v else -v);
}

/// The low 8 bits of the whole number f (0 if it doesn't fit an integer).
fn low8(f: f64) usize {
    if (!(@abs(f) < 9.0e18)) return 0;
    return @intCast(@as(i64, @intFromFloat(f)) & 255);
}

fn perlin(x0: f64, y0: f64, z0: f64) f64 {
    const fx = @floor(x0);
    const fy = @floor(y0);
    const fz = @floor(z0);
    const xi = low8(fx);
    const yi = low8(fy);
    const zi = low8(fz);
    const x = x0 - fx;
    const y = y0 - fy;
    const z = z0 - fz;
    const u = fade(x);
    const v = fade(y);
    const w = fade(z);
    const a = p(xi) + yi;
    const aa = p(a) + zi;
    const ab = p(a + 1) + zi;
    const b = p(xi + 1) + yi;
    const ba = p(b) + zi;
    const bb = p(b + 1) + zi;
    return lerp(w, lerp(v, lerp(u, grad(p(aa), x, y, z), grad(p(ba), x - 1, y, z)),
        lerp(u, grad(p(ab), x, y - 1, z), grad(p(bb), x - 1, y - 1, z))),
        lerp(v, lerp(u, grad(p(aa + 1), x, y, z - 1), grad(p(ba + 1), x - 1, y, z - 1)),
            lerp(u, grad(p(ab + 1), x, y - 1, z - 1), grad(p(bb + 1), x - 1, y - 1, z - 1))));
}

fn toF64Arg(x: Value) f64 {
    if (!num.isNumber(x)) num.notANumber("noise", x);
    return num.toF64(x);
}

fn noiseImpl(a: Args) Value {
    const z = if (a.len > 2) toF64Arg(a[2]) else 0.0;
    return num.boxF64(perlin(toF64Arg(a[0]), toF64Arg(a[1]), z));
}

// ---------------------------------------------------------------------------------------
// skein.time: a monotonic clock from the program's start

var start_ns: u64 = 0;

/// Remember when the program started (sk_init).
pub fn init() void {
    start_ns = platform.monotonicNanos();
}

fn nowImpl(a: Args) Value {
    _ = a;
    return num.boxF64(@as(f64, @floatFromInt(platform.monotonicNanos() - start_ns)) / 1e9);
}

fn nowNsImpl(a: Args) Value {
    _ = a;
    return num.fromI128(@intCast(platform.monotonicNanos() - start_ns));
}

pub const entries = [_]Entry{
    .{ .name = "skein.math/sin", .min = 1, .max = 1, .impl = unary("sin", sinFn) },
    .{ .name = "skein.math/cos", .min = 1, .max = 1, .impl = unary("cos", cosFn) },
    .{ .name = "skein.math/tan", .min = 1, .max = 1, .impl = unary("tan", tanFn) },
    .{ .name = "skein.math/asin", .min = 1, .max = 1, .impl = unary("asin", asinFn) },
    .{ .name = "skein.math/acos", .min = 1, .max = 1, .impl = unary("acos", acosFn) },
    .{ .name = "skein.math/atan", .min = 1, .max = 1, .impl = unary("atan", atanFn) },
    .{ .name = "skein.math/atan2", .min = 2, .max = 2, .impl = atan2Impl },
    .{ .name = "skein.math/exp", .min = 1, .max = 1, .impl = unary("exp", expFn) },
    .{ .name = "skein.math/log", .min = 1, .max = 1, .impl = unary("log", logFn) },
    .{ .name = "skein.math/pow", .min = 2, .max = 2, .impl = powImpl },
    .{ .name = "skein.math/floor", .min = 1, .max = 1, .impl = rounding("floor", .floor) },
    .{ .name = "skein.math/ceil", .min = 1, .max = 1, .impl = rounding("ceil", .ceil) },
    .{ .name = "skein.math/round", .min = 1, .max = 1, .impl = rounding("round", .round) },
    .{ .name = "skein.math/trunc", .min = 1, .max = 1, .impl = rounding("trunc", .trunc) },
    .{ .name = "skein.math/noise", .min = 2, .max = 3, .impl = noiseImpl },
    .{ .name = "skein.time/now", .min = 0, .max = 0, .impl = nowImpl },
    .{ .name = "skein.time/now-ns", .min = 0, .max = 0, .impl = nowNsImpl },
};
