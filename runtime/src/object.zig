//! Heap objects (DESIGN §17.2, D-043). Every object starts with one header word; its
//! payload follows as 64-bit words.
//!
//!   bits  0-15  type id
//!   bits 16-23  GC bits (marked, forwarded, pinned, old)
//!   bits 24-31  size class (for the old generation's free lists; 0 = none yet)
//!   bits 32-39  flags (hash cached, ...)
//!   bits 40-63  payload length in words (objects of 32 KiB and more live in the large
//!               object space, so 24 bits is plenty)

const std = @import("std");
const Value = @import("value.zig").Value;

/// Object types. More arrive with the core data structures (M1.4).
pub const TypeId = enum(u16) {
    invalid = 0,
    /// A boxed f64: one payload word holding its bits.
    f64 = 1,
    /// An immutable UTF-8 string: payload word 0 is the byte length, the bytes follow.
    string = 2,
    /// An integer outside the fixnum range: payload word 0 is 1 if negative, then the
    /// magnitude's 64-bit limbs, least significant first, with no leading zero limb.
    bignum = 3,
    /// A function: payload word 0 is its code pointer, word 1 its name (a C string).
    /// Closures add their captured values after these (M1.4).
    function = 4,
    /// A fixed number of values: payload words are all Values. Used inside the runtime
    /// (closure environments from M1.4, the GC's tests).
    tuple = 5,
    _,
};

pub const GcBits = packed struct(u8) {
    /// Reached during a major collection's mark phase.
    marked: bool = false,
    /// Copied out of the nursery; payload word 0 holds the new address.
    forwarded: bool = false,
    /// Referenced from a stack during a minor collection, so it stays where it is.
    pinned: bool = false,
    /// In the old generation.
    old: bool = false,
    /// An old object in the remembered set (it may point to young objects).
    remembered: bool = false,
    _: u3 = 0,
};

pub const Flags = packed struct(u8) {
    hash_cached: bool = false,
    _: u7 = 0,
};

pub const max_len = std.math.maxInt(u24);

pub const Header = packed struct(u64) {
    type_id: TypeId,
    gc: GcBits = .{},
    size_class: u8 = 0,
    flags: Flags = .{},
    len: u24,

    pub fn init(type_id: TypeId, len: u24) Header {
        return .{ .type_id = type_id, .len = len };
    }

    /// The payload words that hold Values (the rest hold raw data).
    pub fn valueSlots(h: *Header) []Value {
        const p = h.payload();
        const values: [*]Value = @ptrCast(p.ptr);
        return switch (h.type_id) {
            .tuple => values[0..p.len],
            // Code pointer and name, then captured values.
            .function => values[@min(2, p.len)..p.len],
            else => values[0..0],
        };
    }

    /// The payload words that follow the header.
    pub fn payload(h: *Header) []u64 {
        const words: [*]u64 = @ptrCast(h);
        return words[1 .. 1 + @as(usize, h.len)];
    }

    /// The object's size in bytes, header included.
    pub fn size(h: *const Header) usize {
        return (1 + @as(usize, h.len)) * 8;
    }
};

comptime {
    std.debug.assert(@sizeOf(Header) == 8);
}

// ---------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "header fields pack into one word" {
    var h = Header.init(.f64, 1);
    h.gc.marked = true;
    h.size_class = 7;
    h.flags.hash_cached = true;
    const word: u64 = @bitCast(h);
    try testing.expectEqual(@as(u64, 1), word & 0xFFFF);
    try testing.expectEqual(@as(u64, 1), (word >> 16) & 1);
    try testing.expectEqual(@as(u64, 7), (word >> 24) & 0xFF);
    try testing.expectEqual(@as(u64, 1), (word >> 32) & 1);
    try testing.expectEqual(@as(u64, 1), word >> 40);
    const back: Header = @bitCast(word);
    try testing.expectEqual(TypeId.f64, back.type_id);
    try testing.expect(back.gc.marked and !back.gc.forwarded and back.flags.hash_cached);
}

test "payload follows the header" {
    var words: [3]u64 align(8) = .{ 0, 11, 22 };
    const h: *Header = @ptrCast(&words);
    h.* = Header.init(.f64, 2);
    try testing.expectEqual(@as(usize, 2), h.payload().len);
    try testing.expectEqual(@as(u64, 11), h.payload()[0]);
    try testing.expectEqual(@as(usize, 24), h.size());
}
