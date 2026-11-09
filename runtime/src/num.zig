//! Numbers (DESIGN §6.1): fixnums that promote to bignums on overflow (D-023), boxed
//! f64 and immediate f32, with Phase 0's contagion rules. An integer combined with an
//! f32 gives an f32; anything with an f64 gives an f64; integers divided give an f64.

const std = @import("std");
const big = std.math.big.int;
const Limb = std.math.big.Limb;
const object = @import("object.zig");
const rt = @import("rt.zig");
const Value = @import("value.zig").Value;

// ---------------------------------------------------------------------------------------
// Boxed f64

pub fn boxF64(x: f64) Value {
    const h = rt.alloc(.f64, 1);
    h.payload()[0] = @bitCast(x);
    return Value.fromObject(h);
}

pub fn unboxF64(v: Value) f64 {
    std.debug.assert(v.isObjectOf(.f64));
    return @bitCast(v.toObject().payload()[0]);
}

// ---------------------------------------------------------------------------------------
// Integers

pub fn isBignum(v: Value) bool {
    return v.isObjectOf(.bignum);
}

pub fn isInteger(v: Value) bool {
    return v.isFixnum() or isBignum(v);
}

/// True if the integer `v` is odd (the lowest bit of its magnitude).
pub fn isOdd(v: Value) bool {
    if (v.isFixnum()) return @mod(v.toFixnum(), 2) != 0;
    const p = v.toObject().payload();
    return p[1] & 1 != 0;
}

/// A big-integer view of the integer `v`; a fixnum uses `buf` for its one limb.
fn toConst(v: Value, buf: *[1]Limb) big.Const {
    if (v.isFixnum()) {
        const n = v.toFixnum();
        buf[0] = @abs(n);
        return .{ .limbs = buf[0..1], .positive = n >= 0 };
    }
    const p = v.toObject().payload();
    const limbs: [*]const Limb = @ptrCast(p[1..].ptr);
    return .{ .limbs = limbs[0 .. p.len - 1], .positive = p[0] == 0 };
}

/// A fresh bignum object with room for `limbs` limbs, and a Mutable over them.
fn newBig(limbs: usize) struct { *object.Header, big.Mutable } {
    const h = rt.alloc(.bignum, 1 + limbs);
    const ls: [*]Limb = @ptrCast(h.payload()[1..].ptr);
    return .{ h, .{ .limbs = ls[0..limbs], .len = 1, .positive = true } };
}

/// Finish a bignum computed into `h`: a fixnum if it fits, else `h` trimmed to size.
fn finishBig(h: *object.Header, m: big.Mutable) Value {
    const c = m.toConst();
    if (c.toInt(i64)) |n| {
        if (Value.fitsFixnum(n)) return Value.fromFixnum(n);
    } else |_| {}
    h.payload()[0] = if (c.positive or c.eqlZero()) 0 else 1;
    h.len = @intCast(1 + m.len);
    return Value.fromObject(h);
}

/// The integer `n` as a fixnum or bignum.
pub fn fromI128(n: i128) Value {
    if (n >= Value.fixnum_min and n <= Value.fixnum_max) return Value.fromFixnum(@intCast(n));
    const h, var m = newBig(big.calcLimbLen(n));
    m.set(n);
    return finishBig(h, m);
}

/// An integer from decimal text, for literals too big for a fixnum.
pub fn parseInteger(text: []const u8) Value {
    const digits = if (text.len > 0 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
    const limbs = big.calcSetStringLimbCount(10, digits.len);
    const h, var m = newBig(limbs);
    m.setString(10, digits) catch rt.fatal("invalid integer literal {s}", .{text});
    if (text.len > 0 and text[0] == '-') m.positive = false;
    return finishBig(h, m);
}

const IntOp = enum { add, sub, mul };

fn intArith(op: IntOp, a: Value, b: Value) Value {
    if (a.isFixnum() and b.isFixnum()) {
        const x: i128 = a.toFixnum();
        const y: i128 = b.toFixnum();
        return fromI128(switch (op) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
        });
    }
    var ba: [1]Limb = undefined;
    var bb: [1]Limb = undefined;
    const ca = toConst(a, &ba);
    const cb = toConst(b, &bb);
    switch (op) {
        .add, .sub => {
            const h, var m = newBig(@max(ca.limbs.len, cb.limbs.len) + 1);
            if (op == .add) m.add(ca, cb) else m.sub(ca, cb);
            return finishBig(h, m);
        },
        .mul => {
            const h, var m = newBig(ca.limbs.len + cb.limbs.len);
            m.mul(ca, cb, &.{}, null);
            return finishBig(h, m);
        },
    }
}

fn intOrder(a: Value, b: Value) std.math.Order {
    if (a.isFixnum() and b.isFixnum()) return std.math.order(a.toFixnum(), b.toFixnum());
    var ba: [1]Limb = undefined;
    var bb: [1]Limb = undefined;
    return toConst(a, &ba).order(toConst(b, &bb));
}

/// Print the integer `v` in decimal.
pub fn writeInteger(v: Value, out: *std.ArrayList(u8)) void {
    if (v.isFixnum()) {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{v.toFixnum()}) catch unreachable;
        appendBytes(out, s);
        return;
    }
    var bl: [1]Limb = undefined;
    const c = toConst(v, &bl);
    const text = rt.scratch.alloc(u8, c.sizeInBaseUpperBound(10)) catch rt.fatal("out of memory", .{});
    defer rt.scratch.free(text);
    const limbs = rt.scratch.alloc(Limb, big.calcToStringLimbsBufferLen(c.limbs.len, 10)) catch
        rt.fatal("out of memory", .{});
    defer rt.scratch.free(limbs);
    const n = c.toString(text, 10, .lower, limbs);
    appendBytes(out, text[0..n]);
}

fn appendBytes(out: *std.ArrayList(u8), bytes: []const u8) void {
    out.appendSlice(rt.scratch, bytes) catch rt.fatal("out of memory", .{});
}

// ---------------------------------------------------------------------------------------
// The number tower

pub const Kind = enum { int, f32, f64, other };

pub fn kind(v: Value) Kind {
    if (v.isFixnum()) return .int;
    if (v.isF32()) return .f32;
    if (v.isObject()) return switch (v.toObject().type_id) {
        .bignum => .int,
        .f64 => .f64,
        else => .other,
    };
    return .other;
}

pub fn isNumber(v: Value) bool {
    return kind(v) != .other;
}

pub fn toF64(v: Value) f64 {
    return switch (kind(v)) {
        .f64 => unboxF64(v),
        .f32 => v.toF32(),
        .int => if (v.isFixnum())
            @floatFromInt(v.toFixnum())
        else blk: {
            var bl: [1]Limb = undefined;
            break :blk toConst(v, &bl).toFloat(f64, .nearest_even)[0];
        },
        .other => unreachable,
    };
}

fn toF32(v: Value) f32 {
    return if (v.isF32()) v.toF32() else @floatCast(toF64(v));
}

/// Signal that `name` needs a number but got `v`.
pub fn notANumber(name: []const u8, v: Value) noreturn {
    const print = @import("print.zig");
    var buf: std.ArrayList(u8) = .empty;
    print.write(v, &buf, true);
    rt.raise(.type_error, "{s} needs numbers, not {s}", .{ name, buf.items });
}

fn checkNumbers(name: []const u8, a: Value, b: Value) struct { Kind, Kind } {
    const ka = kind(a);
    const kb = kind(b);
    if (ka == .other) notANumber(name, a);
    if (kb == .other) notANumber(name, b);
    return .{ ka, kb };
}

pub const Op = enum { add, sub, mul, div };

/// a op b with Skein's contagion and overflow rules.
pub fn arith(op: Op, a: Value, b: Value) Value {
    const name = switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
    };
    const ka, const kb = checkNumbers(name, a, b);
    if (op == .div) {
        if (isZero(b)) rt.raise(.arithmetic_error, "division by zero", .{});
        if (ka == .int and kb == .int) return boxF64(toF64(a) / toF64(b));
    } else if (ka == .int and kb == .int) {
        return intArith(switch (op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => unreachable,
        }, a, b);
    }
    if (ka == .f64 or kb == .f64) {
        const x = toF64(a);
        const y = toF64(b);
        return boxF64(switch (op) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
            .div => x / y,
        });
    }
    const x = toF32(a);
    const y = toF32(b);
    return Value.fromF32(switch (op) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
    });
}

fn isZero(v: Value) bool {
    return switch (kind(v)) {
        .int => v.isFixnum() and v.toFixnum() == 0,
        .f32, .f64 => toF64(v) == 0.0,
        .other => false,
    };
}

/// How a and b compare as numbers, or null if either is NaN.
pub fn compare(name: []const u8, a: Value, b: Value) ?std.math.Order {
    const ka, const kb = checkNumbers(name, a, b);
    if (ka == .int and kb == .int) return intOrder(a, b);
    const x = toF64(a);
    const y = toF64(b);
    if (std.math.isNan(x) or std.math.isNan(y)) return null;
    return std.math.order(x, y);
}

/// Skein's = on two values that are numbers: integers equal integers by value, floats
/// equal floats by value, and an integer never equals a float.
pub fn numbersEqual(a: Value, b: Value) bool {
    const ka = kind(a);
    const kb = kind(b);
    if ((ka == .int) != (kb == .int)) return false;
    const order = compare("=", a, b) orelse return false;
    return order == .eq;
}

// ---------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn expectInt(expected: i128, v: Value) !void {
    try testing.expect(isInteger(v));
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(rt.scratch);
    writeInteger(v, &buf);
    var want: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{d}", .{expected}), buf.items);
}

test "fixnum arithmetic promotes to bignums and comes back" {
    const max = Value.fromFixnum(Value.fixnum_max);
    const one = Value.fromFixnum(1);
    const sum = arith(.add, max, one);
    try testing.expect(isBignum(sum));
    try expectInt(@as(i128, Value.fixnum_max) + 1, sum);
    const back = arith(.sub, sum, one);
    try testing.expect(back.isFixnum());
    try testing.expectEqual(Value.fixnum_max, back.toFixnum());
    try expectInt(@as(i128, Value.fixnum_min) - 1, arith(.sub, Value.fromFixnum(Value.fixnum_min), one));
}

test "integer arithmetic matches i128 at random (a reference model)" {
    var prng = std.Random.DefaultPrng.init(99);
    const random = prng.random();
    for (0..20_000) |_| {
        // Operands up to about 2^62 in magnitude, so products fit in i128.
        const x = random.intRangeAtMost(i128, -(1 << 62), 1 << 62);
        const y = random.intRangeAtMost(i128, -(1 << 62), 1 << 62);
        const a = fromI128(x);
        const b = fromI128(y);
        try expectInt(x + y, arith(.add, a, b));
        try expectInt(x - y, arith(.sub, a, b));
        try expectInt(x * y, arith(.mul, a, b));
        try testing.expectEqual(std.math.order(x, y), compare("<", a, b).?);
    }
}

test "big literals parse, and products of bignums are right" {
    const a = parseInteger("21267647932558653957237540927630737409");
    try testing.expect(isBignum(a));
    const b = parseInteger("-4611686018427387903");
    try expectInt(-4611686018427387903, b);
    // (2^62 - 1)^2 = 21267647932558653957237540927630737409
    const c = arith(.mul, fromI128(4611686018427387903), fromI128(4611686018427387903));
    try testing.expect(numbersEqual(a, c));
    try testing.expect(parseInteger("12").isFixnum());
}

test "float contagion and division follow Phase 0" {
    const i = Value.fromFixnum(1);
    const h = Value.fromF32(1.5);
    const d = boxF64(2.0);
    try testing.expect(arith(.add, i, h).isF32());
    try testing.expectEqual(@as(f32, 2.5), arith(.add, i, h).toF32());
    try testing.expectEqual(@as(f64, 3.5), unboxF64(arith(.add, h, d)));
    try testing.expectEqual(@as(f64, 2.0), unboxF64(arith(.div, Value.fromFixnum(6), Value.fromFixnum(3))));
    try testing.expect(!numbersEqual(i, boxF64(1.0)));
    try testing.expect(numbersEqual(boxF64(1.0), Value.fromF32(1.0)));
    try testing.expectEqual(std.math.Order.lt, compare("<", i, h).?);
    try testing.expectEqual(@as(?std.math.Order, null), compare("<", boxF64(std.math.nan(f64)), i));
}
