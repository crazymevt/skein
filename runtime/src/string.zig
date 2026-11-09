//! Strings: immutable UTF-8 (DESIGN §6.5, D-019). The payload is [byte length, number
//! of characters (code points), bytes...], so `count` is O(1), and indexing is O(1) when
//! every character is ASCII.

const std = @import("std");
const object = @import("object.zig");
const rt = @import("rt.zig");
const Value = @import("value.zig").Value;

fn countChars(text: []const u8) usize {
    var n: usize = 0;
    for (text) |b| {
        // Count the bytes that start a character (not continuation bytes 10xxxxxx).
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// A new string holding a copy of `text` (which must be valid UTF-8).
pub fn make(text: []const u8) Value {
    const words = 2 + (text.len + 7) / 8;
    const h = rt.alloc(.string, words);
    h.payload()[0] = text.len;
    h.payload()[1] = countChars(text);
    const dest: [*]u8 = @ptrCast(h.payload()[2..].ptr);
    @memcpy(dest[0..text.len], text);
    return Value.fromObject(h);
}

/// The bytes of a string value. Valid until the next allocation only if the string may
/// move; callers that allocate keep the Value on the stack, which pins it.
pub fn bytes(v: Value) []const u8 {
    std.debug.assert(v.isObjectOf(.string));
    const p = v.toObject().payload();
    const start: [*]const u8 = @ptrCast(p[2..].ptr);
    return start[0..p[0]];
}

pub fn isString(v: Value) bool {
    return v.isObjectOf(.string);
}

/// The number of characters (code points).
pub fn count(v: Value) usize {
    return v.toObject().payload()[1];
}

pub fn isAscii(v: Value) bool {
    const p = v.toObject().payload();
    return p[0] == p[1];
}

/// The byte offset of character `i` (0 <= i <= count).
pub fn byteOffset(v: Value, i: usize) usize {
    if (isAscii(v)) return i;
    const b = bytes(v);
    var seen: usize = 0;
    for (b, 0..) |c, k| {
        if (c & 0xC0 != 0x80) {
            if (seen == i) return k;
            seen += 1;
        }
    }
    return b.len;
}

/// Character `i` of the string.
pub fn charAt(v: Value, i: usize) u21 {
    const b = bytes(v);
    const start = byteOffset(v, i);
    const len = std.unicode.utf8ByteSequenceLength(b[start]) catch 1;
    return std.unicode.utf8Decode(b[start .. start + len]) catch 0xFFFD;
}

/// The characters from `start` up to `end`.
pub fn substring(v: Value, start: usize, end: usize) Value {
    const a = byteOffset(v, start);
    const z = byteOffset(v, end);
    // Copy first: making the new string may move nothing that `v`'s bytes live in (the
    // caller holds `v`, which pins it), but be safe and copy out.
    var buf: [256]u8 = undefined;
    if (z - a <= buf.len) {
        @memcpy(buf[0 .. z - a], bytes(v)[a..z]);
        return make(buf[0 .. z - a]);
    }
    const copy = rt.scratch.dupe(u8, bytes(v)[a..z]) catch rt.fatal("out of memory", .{});
    defer rt.scratch.free(copy);
    return make(copy);
}

test "strings hold their bytes and count characters" {
    const s = make("héllo, wörld");
    try std.testing.expect(isString(s));
    try std.testing.expectEqualStrings("héllo, wörld", bytes(s));
    try std.testing.expectEqual(@as(usize, 12), count(s));
    try std.testing.expect(!isAscii(s));
    try std.testing.expectEqual(@as(u21, 'é'), charAt(s, 1));
    try std.testing.expectEqualStrings("wörld", bytes(substring(s, 7, 12)));
    try std.testing.expectEqualStrings("", bytes(make("")));
    var long: [1000]u8 = undefined;
    for (&long, 0..) |*b, i| b.* = @intCast('a' + i % 26);
    const l = make(&long);
    try std.testing.expectEqualStrings(&long, bytes(l));
    try std.testing.expect(isAscii(l));
    try std.testing.expectEqual(@as(u21, 'b'), charAt(l, 27));
}
