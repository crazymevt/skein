//! Strings: immutable UTF-8 (DESIGN §6.5). M1.2 needs only literals and printing; the
//! rest of the string operations arrive with the core data structures (M1.4).

const std = @import("std");
const object = @import("object.zig");
const rt = @import("rt.zig");
const Value = @import("value.zig").Value;

/// A new string holding a copy of `bytes` (which must be valid UTF-8).
pub fn make(text: []const u8) Value {
    const words = 1 + (text.len + 7) / 8;
    const h = rt.alloc(.string, words);
    h.payload()[0] = text.len;
    const dest: [*]u8 = @ptrCast(h.payload()[1..].ptr);
    @memcpy(dest[0..text.len], text);
    return Value.fromObject(h);
}

/// The bytes of a string value.
pub fn bytes(v: Value) []const u8 {
    std.debug.assert(v.isObjectOf(.string));
    const p = v.toObject().payload();
    const start: [*]const u8 = @ptrCast(p[1..].ptr);
    return start[0..p[0]];
}

pub fn isString(v: Value) bool {
    return v.isObjectOf(.string);
}

test "strings hold their bytes" {
    const s = make("héllo, wörld");
    try std.testing.expect(isString(s));
    try std.testing.expectEqualStrings("héllo, wörld", bytes(s));
    try std.testing.expectEqualStrings("", bytes(make("")));
    var long: [1000]u8 = undefined;
    for (&long, 0..) |*b, i| b.* = @intCast('a' + i % 26);
    try std.testing.expectEqualStrings(&long, bytes(make(&long)));
}
