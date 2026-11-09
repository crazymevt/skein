//! Hashing, the same as Phase 0's (host/src/runtime/data.lisp and equality.lisp, D-046),
//! so that hash maps iterate in the same order natively and on the host.

const std = @import("std");

/// Murmur3's 32-bit finalizer.
pub fn mix32(x: u32) u32 {
    var h = x;
    h = (h ^ (h >> 16)) *% 0x85EBCA6B;
    h = (h ^ (h >> 13)) *% 0xC2B2AE35;
    return h ^ (h >> 16);
}

/// Fold an integer's magnitude to 32 bits by XORing its 32-bit chunks (Phase 0's
/// fold32); complemented if negative. `limbs` is the magnitude, least significant first.
pub fn fold32Limbs(limbs: []const u64, negative: bool) u32 {
    var h: u32 = 0;
    for (limbs) |limb| h ^= @as(u32, @truncate(limb)) ^ @as(u32, @truncate(limb >> 32));
    return if (negative) ~h else h;
}

pub fn fold32(n: i64) u32 {
    const mag: u64 = @abs(n);
    return fold32Limbs(&.{mag}, n < 0);
}

pub fn hashInt(n: i64) u32 {
    return mix32(fold32(n));
}

/// Floats: 0 for both zeros, else the folded bits of the value as an f64.
pub fn hashFloat(x: f64) u32 {
    if (x == 0) return 0;
    const bits: u64 = @bitCast(x);
    return mix32(fold32Limbs(&.{bits}, false));
}

/// Strings: FNV-1a over the code points, then mix32.
pub fn hashString(utf8: []const u8) u32 {
    var h: u32 = 0x811C9DC5;
    var it = std.unicode.Utf8View.initUnchecked(utf8).iterator();
    while (it.nextCodepoint()) |cp| h = (h ^ @as(u32, cp)) *% 0x01000193;
    return mix32(h);
}

pub fn mixCollection(h: u32, count: usize) u32 {
    return mix32(h ^ @as(u32, @truncate(count *% 0x9E3779B9)));
}

pub const nil_hash: u32 = 0;
pub const true_hash: u32 = 1231;
pub const false_hash: u32 = 1237;
/// Added to a keyword's name hash, so :a and 'a differ.
pub const keyword_salt: u32 = 0x9E3779B9;

const testing = std.testing;

test "hashes match Phase 0's" {
    // Values computed by the host (host/src/runtime): (hash-of x).
    try testing.expectEqual(@as(u32, 0), fold32(0));
    try testing.expectEqual(fold32(5), 5);
    try testing.expectEqual(~@as(u32, 5), fold32(-5));
    try testing.expectEqual(@as(u32, 0x00000001 ^ 0x00000002), fold32Limbs(&.{0x0000000200000001}, false));
    try testing.expectEqual(@as(u32, 7), fold32Limbs(&.{ 7, 0 }, false));
}
