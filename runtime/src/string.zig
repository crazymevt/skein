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

/// The character starting at byte `off` of the string.
pub fn charAtByte(v: Value, off: usize) u21 {
    const b = bytes(v);
    const len = std.unicode.utf8ByteSequenceLength(b[off]) catch 1;
    return std.unicode.utf8Decode(b[off..@min(b.len, off + len)]) catch 0xFFFD;
}

/// The byte offset of the character after the one starting at byte `off`.
pub fn nextByte(v: Value, off: usize) usize {
    const b = bytes(v);
    const len = std.unicode.utf8ByteSequenceLength(b[off]) catch 1;
    return @min(b.len, off + len);
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

/// A copy of bytes [a, z) of `v` as a new string.
fn sliceBytes(v: Value, a: usize, z: usize) Value {
    var buf: [256]u8 = undefined;
    if (z - a <= buf.len) {
        @memcpy(buf[0 .. z - a], bytes(v)[a..z]);
        return make(buf[0 .. z - a]);
    }
    const copy = rt.scratch.dupe(u8, bytes(v)[a..z]) catch rt.fatal("out of memory", .{});
    defer rt.scratch.free(copy);
    return make(copy);
}

// ---------------------------------------------------------------------------------------
// Cursors (D-019, M2.11): positions in a string as byte offsets, which skein.string walks
// non-ASCII text with in O(1) a step. Each cursor must be at the start of a character.

fn checkString(v: Value, what: []const u8) void {
    if (!isString(v)) rt.raise(.type_error, "{s} needs a string", .{what});
}

fn cursorOf(s: Value, c: Value, what: []const u8) usize {
    const b = bytes(s);
    if (!c.isFixnum() or c.toFixnum() < 0 or c.toFixnum() > b.len)
        rt.raise(.@"error", "{s}: not a cursor of the string", .{what});
    const i: usize = @intCast(c.toFixnum());
    if (i < b.len and b[i] & 0xC0 == 0x80) rt.raise(.@"error", "{s}: the cursor is inside a character", .{what});
    return i;
}

fn seqLen(b: u8) usize {
    return std.unicode.utf8ByteSequenceLength(b) catch 1;
}

const Args = []const Value;
const Entry = @import("compiler.zig").Entry;

pub const entries = [_]Entry{
    // (%string-end s): the cursor after the last character.
    .{ .name = "%string-end", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            checkString(a[0], "%string-end");
            return Value.fromFixnum(@intCast(bytes(a[0]).len));
        }
    }.f },
    // (%string-char-at s c): the character at cursor c, or nil at the end.
    .{ .name = "%string-char-at", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            checkString(a[0], "%string-char-at");
            const i = cursorOf(a[0], a[1], "%string-char-at");
            const b = bytes(a[0]);
            if (i == b.len) return Value.nil;
            const n = @min(seqLen(b[i]), b.len - i);
            return Value.fromChar(std.unicode.utf8Decode(b[i .. i + n]) catch 0xFFFD);
        }
    }.f },
    // (%string-next s c): the cursor after the character at c (c itself at the end).
    .{ .name = "%string-next", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            checkString(a[0], "%string-next");
            const i = cursorOf(a[0], a[1], "%string-next");
            const b = bytes(a[0]);
            if (i == b.len) return a[1];
            return Value.fromFixnum(@intCast(@min(i + seqLen(b[i]), b.len)));
        }
    }.f },
    // (%string-slice s from to): the characters from cursor from up to cursor to.
    .{ .name = "%string-slice", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            checkString(a[0], "%string-slice");
            const from = cursorOf(a[0], a[1], "%string-slice");
            const to = cursorOf(a[0], a[2], "%string-slice");
            if (to < from) rt.raise(.@"error", "%string-slice: the end is before the start", .{});
            return sliceBytes(a[0], from, to);
        }
    }.f },
    // (%string-find s part from): the cursor of the first part at or after cursor from, or
    // nil; (%string-find s part nil true): of the last.
    .{ .name = "%string-find", .min = 3, .max = 4, .impl = struct {
        fn f(a: Args) Value {
            checkString(a[0], "%string-find");
            checkString(a[1], "%string-find");
            const b = bytes(a[0]);
            const part = bytes(a[1]);
            const found = if (a.len == 4 and a[3] != Value.nil and a[3] != Value.false)
                std.mem.lastIndexOf(u8, b, part)
            else
                std.mem.indexOfPos(u8, b, cursorOf(a[0], a[2], "%string-find"), part);
            return if (found) |i| Value.fromFixnum(@intCast(i)) else Value.nil;
        }
    }.f },
    // (%string-cursor->index s c): the index (in characters) of cursor c.
    .{ .name = "%string-cursor->index", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            checkString(a[0], "%string-cursor->index");
            const i = cursorOf(a[0], a[1], "%string-cursor->index");
            if (isAscii(a[0])) return Value.fromFixnum(@intCast(i));
            var n: usize = 0;
            for (bytes(a[0])[0..i]) |byte| {
                if (byte & 0xC0 != 0x80) n += 1;
            }
            return Value.fromFixnum(@intCast(n));
        }
    }.f },
    // (%string-index->cursor s i): the cursor of the character at index i (or the end).
    .{ .name = "%string-index->cursor", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            checkString(a[0], "%string-index->cursor");
            if (!a[1].isFixnum() or a[1].toFixnum() < 0 or a[1].toFixnum() > count(a[0]))
                rt.raise(.@"error", "%string-index->cursor: no index {d} in the string", .{a[1].toFixnum()});
            return Value.fromFixnum(@intCast(byteOffset(a[0], @intCast(a[1].toFixnum()))));
        }
    }.f },
    // (%string-ascii-case s upper?): s with its ASCII letters upper- or lower-cased.
    .{ .name = "%string-ascii-case", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            checkString(a[0], "%string-ascii-case");
            const upper = a[1] != Value.nil and a[1] != Value.false;
            const copy = rt.scratch.dupe(u8, bytes(a[0])) catch rt.fatal("out of memory", .{});
            defer rt.scratch.free(copy);
            for (copy) |*byte| byte.* = if (upper) std.ascii.toUpper(byte.*) else std.ascii.toLower(byte.*);
            return make(copy);
        }
    }.f },
};

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
