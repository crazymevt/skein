//! Skein values as 64-bit tagged words (DESIGN §17.1, D-043). The low three bits are
//! the tag:
//!
//!   x00  fixnum: a 62-bit signed integer in the upper bits (both 000 and 100)
//!   001  pointer to a heap object, 8-byte aligned (the tag is added to the address)
//!   011  immediate: bits 3-7 say which (nil, false, true, unbound, char); a char keeps
//!        its code point in bits 32-52
//!   101  f32, its bits in the upper 32 bits
//!   010, 110, 111  reserved
//!
//! Fixnums keep their low two bits zero, so adding or subtracting two of them needs no
//! untagging. f64s and every other value live on the heap (object.zig).

const std = @import("std");
const object = @import("object.zig");

pub const Value = enum(u64) {
    _,

    pub const tag_mask: u64 = 0b111;
    pub const fixnum_mask: u64 = 0b11;
    pub const tag_object: u64 = 0b001;
    pub const tag_immediate: u64 = 0b011;
    pub const tag_f32: u64 = 0b101;

    pub const fixnum_bits = 62;
    pub const fixnum_min: i64 = -(1 << (fixnum_bits - 1));
    pub const fixnum_max: i64 = (1 << (fixnum_bits - 1)) - 1;

    /// The kinds of immediate (tag 011), in bits 3-7.
    pub const Immediate = enum(u5) { nil = 0, false = 1, true = 2, unbound = 3, char = 4 };

    pub const nil: Value = immediate(.nil);
    pub const @"false": Value = immediate(.false);
    pub const @"true": Value = immediate(.true);
    /// The value of a var that is declared but not defined.
    pub const unbound: Value = immediate(.unbound);

    fn immediate(kind: Immediate) Value {
        return @enumFromInt(tag_immediate | (@as(u64, @intFromEnum(kind)) << 3));
    }

    pub inline fn bits(v: Value) u64 {
        return @intFromEnum(v);
    }

    pub inline fn tag(v: Value) u64 {
        return v.bits() & tag_mask;
    }

    // Fixnums

    pub inline fn isFixnum(v: Value) bool {
        return v.bits() & fixnum_mask == 0;
    }

    /// True if `n` fits in a fixnum.
    pub inline fn fitsFixnum(n: i64) bool {
        return n >= fixnum_min and n <= fixnum_max;
    }

    /// The fixnum `n`, which must fit (see `fitsFixnum`).
    pub inline fn fromFixnum(n: i64) Value {
        std.debug.assert(fitsFixnum(n));
        return @enumFromInt(@as(u64, @bitCast(n << 2)));
    }

    pub inline fn toFixnum(v: Value) i64 {
        std.debug.assert(v.isFixnum());
        return @as(i64, @bitCast(v.bits())) >> 2;
    }

    // Immediates

    pub inline fn isImmediate(v: Value) bool {
        return v.tag() == tag_immediate;
    }

    pub inline fn immediateKind(v: Value) Immediate {
        std.debug.assert(v.isImmediate());
        return @enumFromInt(@as(u5, @truncate(v.bits() >> 3)));
    }

    pub inline fn fromBool(b: bool) Value {
        return if (b) Value.true else Value.false;
    }

    /// Everything is true except nil and false.
    pub inline fn isTruthy(v: Value) bool {
        return v != Value.nil and v != Value.false;
    }

    pub inline fn isChar(v: Value) bool {
        return v.isImmediate() and v.immediateKind() == .char;
    }

    /// The char with Unicode scalar value `code`.
    pub inline fn fromChar(code: u21) Value {
        return @enumFromInt(@intFromEnum(immediate(.char)) | (@as(u64, code) << 32));
    }

    pub inline fn toChar(v: Value) u21 {
        std.debug.assert(v.isChar());
        return @truncate(v.bits() >> 32);
    }

    // f32

    pub inline fn isF32(v: Value) bool {
        return v.tag() == tag_f32;
    }

    pub inline fn fromF32(x: f32) Value {
        return @enumFromInt(tag_f32 | (@as(u64, @as(u32, @bitCast(x))) << 32));
    }

    pub inline fn toF32(v: Value) f32 {
        std.debug.assert(v.isF32());
        return @bitCast(@as(u32, @truncate(v.bits() >> 32)));
    }

    // Heap objects

    pub inline fn isObject(v: Value) bool {
        return v.tag() == tag_object;
    }

    pub inline fn fromObject(h: *object.Header) Value {
        const address = @intFromPtr(h);
        std.debug.assert(address & tag_mask == 0);
        return @enumFromInt(address | tag_object);
    }

    pub inline fn toObject(v: Value) *object.Header {
        std.debug.assert(v.isObject());
        return @ptrFromInt(v.bits() & ~tag_mask);
    }

    /// True if `v` is a heap object of type `t`.
    pub inline fn isObjectOf(v: Value, t: object.TypeId) bool {
        return v.isObject() and v.toObject().type_id == t;
    }
};

// ---------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "constants are distinct immediates" {
    const all = [_]Value{ Value.nil, Value.false, Value.true, Value.unbound };
    for (all, 0..) |a, i| {
        try testing.expect(a.isImmediate());
        try testing.expect(!a.isFixnum() and !a.isF32() and !a.isObject() and !a.isChar());
        for (all[i + 1 ..]) |b| try testing.expect(a != b);
    }
    try testing.expectEqual(Value.Immediate.unbound, Value.unbound.immediateKind());
}

test "truthiness: only nil and false are false" {
    try testing.expect(!Value.nil.isTruthy());
    try testing.expect(!Value.false.isTruthy());
    try testing.expect(Value.true.isTruthy());
    try testing.expect(Value.fromFixnum(0).isTruthy());
    try testing.expect(Value.fromF32(0.0).isTruthy());
    try testing.expect(Value.fromChar(0).isTruthy());
    try testing.expectEqual(Value.true, Value.fromBool(true));
}

test "fixnums round trip, at the limits and at random" {
    const edges = [_]i64{ 0, 1, -1, 42, -42, Value.fixnum_max, Value.fixnum_min };
    for (edges) |n| {
        const v = Value.fromFixnum(n);
        try testing.expect(v.isFixnum());
        try testing.expect(!v.isObject() and !v.isImmediate() and !v.isF32());
        try testing.expectEqual(n, v.toFixnum());
    }
    try testing.expect(!Value.fitsFixnum(Value.fixnum_max + 1));
    try testing.expect(!Value.fitsFixnum(Value.fixnum_min - 1));

    var prng = std.Random.DefaultPrng.init(0x5ce1);
    const random = prng.random();
    for (0..100_000) |_| {
        const n = random.intRangeAtMost(i64, Value.fixnum_min, Value.fixnum_max);
        try testing.expectEqual(n, Value.fromFixnum(n).toFixnum());
    }
}

test "fixnum addition works on the tagged words" {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (0..10_000) |_| {
        const a = random.intRangeAtMost(i64, -(1 << 59), 1 << 59);
        const b = random.intRangeAtMost(i64, -(1 << 59), 1 << 59);
        const sum: Value = @enumFromInt(Value.fromFixnum(a).bits() +% Value.fromFixnum(b).bits());
        try testing.expectEqual(a + b, sum.toFixnum());
    }
}

test "chars round trip" {
    const codes = [_]u21{ 0, 'a', 0xE9, 0x1F600, 0x10FFFF };
    for (codes) |code| {
        const v = Value.fromChar(code);
        try testing.expect(v.isChar() and v.isImmediate() and !v.isFixnum());
        try testing.expectEqual(code, v.toChar());
        try testing.expect(v != Value.nil);
    }
}

test "f32s round trip, including the special values" {
    const xs = [_]f32{ 0.0, -0.0, 1.5, -3.25, std.math.floatMax(f32), std.math.floatMin(f32), std.math.inf(f32), -std.math.inf(f32) };
    for (xs) |x| {
        const v = Value.fromF32(x);
        try testing.expect(v.isF32() and !v.isFixnum() and !v.isObject());
        try testing.expectEqual(@as(u32, @bitCast(x)), @as(u32, @bitCast(v.toF32())));
    }
    try testing.expect(std.math.isNan(Value.fromF32(std.math.nan(f32)).toF32()));

    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    for (0..100_000) |_| {
        const raw = random.int(u32);
        const x: f32 = @bitCast(raw);
        try testing.expectEqual(raw, @as(u32, @bitCast(Value.fromF32(x).toF32())));
    }
}

test "object pointers round trip" {
    var words: [4]u64 align(8) = .{ 0, 0, 0, 0 };
    const h: *object.Header = @ptrCast(&words);
    h.* = object.Header.init(.f64, 1);
    const v = Value.fromObject(h);
    try testing.expect(v.isObject() and !v.isFixnum() and !v.isImmediate());
    try testing.expectEqual(h, v.toObject());
    try testing.expect(v.isObjectOf(.f64));
}

test "random words decode to exactly one kind" {
    var prng = std.Random.DefaultPrng.init(11);
    const random = prng.random();
    for (0..100_000) |_| {
        const v: Value = @enumFromInt(random.int(u64));
        var kinds: u32 = 0;
        if (v.isFixnum()) kinds += 1;
        if (v.isObject()) kinds += 1;
        if (v.isImmediate()) kinds += 1;
        if (v.isF32()) kinds += 1;
        const reserved = switch (v.tag()) {
            0b010, 0b110, 0b111 => true,
            else => false,
        };
        try testing.expectEqual(@as(u32, if (reserved) 0 else 1), kinds);
    }
}
