//! skein.bytes's primitives natively (M3.2, D-104): UTF-8, base64 and hex, and SHA-1,
//! SHA-256 and MD5, from Zig's standard library. lib/skein/bytes.skn wraps these. An input
//! is a string (its UTF-8) or a u8 array or byte view; a result that is bytes is a u8 array.
//!
//! Allocating a result can move heap objects, so an input is copied out of the heap (or its
//! result computed into a stack buffer) before the result is made.

const std = @import("std");
const rt = @import("rt.zig");
const print = @import("print.zig");
const string = @import("string.zig");
const structs = @import("structs.zig");
const io = @import("io.zig");
const Value = @import("value.zig").Value;

const alloc = std.heap.c_allocator;

fn readable(v: Value) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    print.write(v, &buf, true);
    return buf.items;
}

/// The bytes of x (a string's UTF-8, or a u8 array or byte view), as they are in the heap.
fn bytesIn(x: Value, comptime what: []const u8) []const u8 {
    if (string.isString(x)) return string.bytes(x);
    return structs.bytesOf(x) orelse
        rt.raise(.type_error, what ++ " needs a string or a u8 array, not {s}", .{readable(x)});
}

/// A copy of x's bytes outside the heap, which the caller frees.
fn copyIn(x: Value, comptime what: []const u8) []u8 {
    return alloc.dupe(u8, bytesIn(x, what)) catch rt.fatal("out of memory", .{});
}

/// A new u8 array of `bytes` (outside the heap).
fn u8Array(bytes: []const u8) Value {
    const a = structs.makePrim(.u8, bytes.len);
    @memcpy(structs.bytesOf(a).?, bytes);
    return a;
}

fn utf8(s: Value) Value {
    if (!string.isString(s)) rt.raise(.type_error, "utf8 needs a string, not {s}", .{readable(s)});
    const b = copyIn(s, "utf8");
    defer alloc.free(b);
    return u8Array(b);
}

fn utf8String(a: Value) Value {
    const b = copyIn(a, "utf8-string");
    defer alloc.free(b);
    if (!std.unicode.utf8ValidateSlice(b)) rt.raise(.@"error", "the bytes aren't UTF-8", .{});
    return string.make(b);
}

fn base64(x: Value) Value {
    const b = copyIn(x, "base64");
    defer alloc.free(b);
    const enc = std.base64.standard.Encoder;
    const out = alloc.alloc(u8, enc.calcSize(b.len)) catch rt.fatal("out of memory", .{});
    defer alloc.free(out);
    return string.make(enc.encode(out, b));
}

fn unbase64(s: Value) Value {
    if (!string.isString(s)) rt.raise(.type_error, "unbase64 needs a string, not {s}", .{readable(s)});
    const b = copyIn(s, "unbase64");
    defer alloc.free(b);
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b) catch rt.raise(.@"error", "not base64: {s}", .{readable(s)});
    const out = alloc.alloc(u8, n) catch rt.fatal("out of memory", .{});
    defer alloc.free(out);
    dec.decode(out, b) catch rt.raise(.@"error", "not base64: {s}", .{readable(s)});
    return u8Array(out);
}

fn hex(x: Value) Value {
    const b = copyIn(x, "hex");
    defer alloc.free(b);
    const out = alloc.alloc(u8, b.len * 2) catch rt.fatal("out of memory", .{});
    defer alloc.free(out);
    const digits = "0123456789abcdef";
    for (b, 0..) |byte, i| {
        out[2 * i] = digits[byte >> 4];
        out[2 * i + 1] = digits[byte & 15];
    }
    return string.make(out);
}

fn unhex(s: Value) Value {
    if (!string.isString(s)) rt.raise(.type_error, "unhex needs a string, not {s}", .{readable(s)});
    const b = copyIn(s, "unhex");
    defer alloc.free(b);
    if (b.len % 2 != 0) rt.raise(.@"error", "not hex (an odd number of digits): {s}", .{readable(s)});
    const out = alloc.alloc(u8, b.len / 2) catch rt.fatal("out of memory", .{});
    defer alloc.free(out);
    _ = std.fmt.hexToBytes(out, b) catch rt.raise(.@"error", "not hex: {s}", .{readable(s)});
    return u8Array(out);
}

fn digest(comptime H: type, x: Value, comptime what: []const u8) Value {
    var out: [H.digest_length]u8 = undefined;
    // Hashed in place: nothing allocates until the result.
    H.hash(bytesIn(x, what), &out, .{});
    return u8Array(&out);
}

// ---------------------------------------------------------------------------------------
// skein.core functions (core.zig's table includes these)

const Args = []const Value;

pub const entries = [_]io.Entry{
    .{ .name = "%utf8", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return utf8(a[0]);
        }
    }.f },
    .{ .name = "%utf8-string", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return utf8String(a[0]);
        }
    }.f },
    .{ .name = "%base64", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return base64(a[0]);
        }
    }.f },
    .{ .name = "%unbase64", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return unbase64(a[0]);
        }
    }.f },
    .{ .name = "%hex", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return hex(a[0]);
        }
    }.f },
    .{ .name = "%unhex", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return unhex(a[0]);
        }
    }.f },
    .{ .name = "%sha1", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return digest(std.crypto.hash.Sha1, a[0], "sha1");
        }
    }.f },
    .{ .name = "%sha256", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return digest(std.crypto.hash.sha2.Sha256, a[0], "sha256");
        }
    }.f },
    .{ .name = "%md5", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return digest(std.crypto.hash.Md5, a[0], "md5");
        }
    }.f },
};
