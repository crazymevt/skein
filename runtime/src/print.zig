//! Printing values as Phase 0 does (host/src/runtime/print.lisp): `print`/`println` show
//! values for people (strings and chars raw), `pr`/`prn` readably.

const std = @import("std");
const object = @import("object.zig");
const rt = @import("rt.zig");
const num = @import("num.zig");
const string = @import("string.zig");
const func = @import("func.zig");
const names = @import("names.zig");
const coll = @import("coll.zig");
const equal = @import("equal.zig");
const platform = @import("platform");
const Value = @import("value.zig").Value;

pub fn put(out: *std.ArrayList(u8), bytes: []const u8) void {
    out.appendSlice(rt.scratch, bytes) catch rt.fatal("out of memory", .{});
}

/// Append the printed form of `v` to `out`; `readably` as `pr` does, else as `print`.
pub fn write(v: Value, out: *std.ArrayList(u8), readably: bool) void {
    if (num.isInteger(v)) return num.writeInteger(v, out);
    if (v.isF32()) return writeFloat(f32, v.toF32(), out);
    if (v.isObjectOf(.f64)) return writeFloat(f64, num.unboxF64(v), out);
    if (v.isChar()) return writeChar(v.toChar(), out, readably);
    if (v.isImmediate()) return put(out, switch (v.immediateKind()) {
        .nil => "nil",
        .false => "false",
        .true => "true",
        .unbound => "#<unbound>",
        .char => unreachable,
    });
    if (string.isString(v)) {
        if (readably) writeStringLiteral(string.bytes(v), out) else put(out, string.bytes(v));
        return;
    }
    if (!v.isObject()) return put(out, "#<object>");
    switch (v.toObject().type_id) {
        .function => {
            put(out, "#<fn ");
            put(out, func.name(v));
            put(out, ">");
        },
        .symbol, .keyword => {
            if (names.isKeyword(v)) put(out, ":");
            if (names.nsOf(v)) |ns| {
                put(out, ns);
                put(out, "/");
            }
            put(out, names.nameOf(v));
        },
        .@"var" => {
            put(out, "#'");
            put(out, names.varNamespaceName(v));
            put(out, "/");
            put(out, names.varName(v));
        },
        .namespace => {
            put(out, "#<namespace ");
            put(out, string.bytes(coll.get(v, 0)));
            put(out, ">");
        },
        .list, .empty_list, .cons, .lazy_seq, .vseq, .sseq, .eduction => writeSequential(v, out, readably, "(", ")"),
        .reduced => {
            put(out, "#<reduced ");
            write(coll.get(v, 0), out, true);
            put(out, ">");
        },
        .vector => writeSequential(v, out, readably, "[", "]"),
        .array_map, .hash_map => {
            put(out, "{");
            var ctx: Entries = .{ .out = out, .readably = readably };
            coll.mapEach(v, &ctx, Entries.mapEntry);
            put(out, "}");
        },
        .hash_set => {
            put(out, "#{");
            var ctx: Entries = .{ .out = out, .readably = readably };
            coll.mapEach(coll.get(v, 0), &ctx, Entries.setElement);
            put(out, "}");
        },
        .atom => {
            put(out, "#<atom ");
            write(coll.atomGet(v), out, true);
            put(out, ">");
        },
        .transient_vector => put(out, "#<transient vector>"),
        .transient_map => put(out, "#<transient map>"),
        .transient_set => put(out, "#<transient set>"),
        .condition, .condition_type, .restart => @import("cond.zig").write(v, out),
        else => put(out, "#<object>"),
    }
}

const Elements = struct {
    out: *std.ArrayList(u8),
    readably: bool,
    first: bool = true,

    fn add(c: *Elements, x: Value) bool {
        if (!c.first) put(c.out, " ");
        c.first = false;
        write(x, c.out, c.readably);
        return true;
    }
};

fn writeSequential(v: Value, out: *std.ArrayList(u8), readably: bool, open: []const u8, close: []const u8) void {
    put(out, open);
    var ctx: Elements = .{ .out = out, .readably = readably };
    equal.eachElement(v, &ctx, Elements.add);
    put(out, close);
}

const Entries = struct {
    out: *std.ArrayList(u8),
    readably: bool,
    first: bool = true,

    fn mapEntry(c: *Entries, k: Value, x: Value) bool {
        if (!c.first) put(c.out, ", ");
        c.first = false;
        write(k, c.out, c.readably);
        put(c.out, " ");
        write(x, c.out, c.readably);
        return true;
    }

    fn setElement(c: *Entries, k: Value, _: Value) bool {
        if (!c.first) put(c.out, " ");
        c.first = false;
        write(k, c.out, c.readably);
        return true;
    }
};

fn writeStringLiteral(s: []const u8, out: *std.ArrayList(u8)) void {
    put(out, "\"");
    for (s) |b| switch (b) {
        '"' => put(out, "\\\""),
        '\\' => put(out, "\\\\"),
        '\n' => put(out, "\\n"),
        '\t' => put(out, "\\t"),
        '\r' => put(out, "\\r"),
        8 => put(out, "\\b"),
        12 => put(out, "\\f"),
        0...7, 11, 14...31, 127 => {
            var buf: [8]u8 = undefined;
            put(out, std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{b}) catch unreachable);
        },
        else => put(out, &.{b}),
    };
    put(out, "\"");
}

fn writeChar(code: u21, out: *std.ArrayList(u8), readably: bool) void {
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(code, &utf8) catch 0;
    if (!readably) return put(out, utf8[0..n]);
    put(out, "\\");
    const name: ?[]const u8 = switch (code) {
        '\n' => "newline",
        ' ' => "space",
        '\t' => "tab",
        8 => "backspace",
        12 => "formfeed",
        '\r' => "return",
        else => null,
    };
    if (name) |s| return put(out, s);
    if (code < 32 or code == 127) {
        var buf: [8]u8 = undefined;
        return put(out, std.fmt.bufPrint(&buf, "u{X:0>4}", .{code}) catch unreachable);
    }
    put(out, utf8[0..n]);
}

/// Print a float as SBCL does: the shortest digits that read back to the same float, in
/// plain notation from 10^-3 up to 10^7 and with an exponent otherwise; f32s end in "f".
pub fn writeFloat(comptime T: type, x: T, out: *std.ArrayList(u8)) void {
    if (std.math.isNan(x)) return put(out, "##NaN");
    if (std.math.isInf(x)) return put(out, if (x > 0) "##Inf" else "##-Inf");
    var buf: [64]u8 = undefined;
    // Zig's {e} gives the shortest round-trip digits: "-1.2345e-7", "1e21", "-0e0".
    const sci = std.fmt.bufPrint(&buf, "{e}", .{x}) catch unreachable;
    var rest = sci;
    const negative = rest[0] == '-';
    if (negative) rest = rest[1..];
    const e_at = std.mem.indexOfScalar(u8, rest, 'e').?;
    const exponent = std.fmt.parseInt(i32, rest[e_at + 1 ..], 10) catch unreachable;
    var digits_buf: [32]u8 = undefined;
    var n: usize = 0;
    for (rest[0..e_at]) |ch| if (ch != '.') {
        digits_buf[n] = ch;
        n += 1;
    };
    const digits = digits_buf[0..n];

    if (negative) put(out, "-");
    const magnitude: f64 = @abs(@as(f64, x));
    if (magnitude == 0 or (magnitude >= 1e-3 and magnitude < 1e7)) {
        // Plain notation; `point` digits come before the decimal point.
        const point: i32 = exponent + 1;
        if (point <= 0) {
            put(out, "0.");
            for (0..@intCast(-point)) |_| put(out, "0");
            put(out, digits);
        } else if (point >= n) {
            put(out, digits);
            for (0..@as(usize, @intCast(point)) - n) |_| put(out, "0");
            put(out, ".0");
        } else {
            const p: usize = @intCast(point);
            put(out, digits[0..p]);
            put(out, ".");
            put(out, digits[p..]);
        }
    } else {
        put(out, digits[0..1]);
        put(out, ".");
        put(out, if (n > 1) digits[1..] else "0");
        var ebuf: [16]u8 = undefined;
        put(out, std.fmt.bufPrint(&ebuf, "e{d}", .{exponent}) catch unreachable);
    }
    if (T == f32) put(out, "f");
}

/// Print `values` separated by spaces, then a newline if `newline`, to standard output.
pub fn printValues(values: []const Value, readably: bool, newline: bool) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.scratch);
    for (values, 0..) |v, i| {
        if (i > 0) put(&out, " ");
        write(v, &out, readably);
    }
    if (newline) put(&out, "\n");
    platform.writeStdout(out.items);
}

// ---------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn printed(v: Value, readably: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    write(v, &out, readably);
    return out.toOwnedSlice(rt.scratch);
}

fn expectPrinted(expected: []const u8, v: Value, readably: bool) !void {
    const s = try printed(v, readably);
    defer rt.scratch.free(s);
    try testing.expectEqualStrings(expected, s);
}

test "floats print as Phase 0 prints them" {
    const cases = [_]struct { f64, []const u8 }{
        .{ 1.5, "1.5" },       .{ 0.1, "0.1" },         .{ 1e21, "1.0e21" },
        .{ 1e-7, "1.0e-7" },   .{ 100.0, "100.0" },     .{ -0.0, "-0.0" },
        .{ 0.0, "0.0" },       .{ 1e16, "1.0e16" },     .{ 123456789.0, "1.23456789e8" },
        .{ 1e7, "1.0e7" },     .{ 1234567.0, "1234567.0" }, .{ 9999999.0, "9999999.0" },
        .{ 2.0e-5, "2.0e-5" }, .{ 0.001, "0.001" },     .{ 9.9e-4, "9.9e-4" },
        .{ 1e100, "1.0e100" }, .{ 0.3333333333333333, "0.3333333333333333" },
        .{ -2.5, "-2.5" },
    };
    for (cases) |c| try expectPrinted(c[1], num.boxF64(c[0]), false);
    try expectPrinted("2.5f", Value.fromF32(2.5), false);
    try expectPrinted("0.1f", Value.fromF32(0.1), false);
    try expectPrinted("3.4e38f", Value.fromF32(3.4e38), false);
    try expectPrinted("##NaN", num.boxF64(std.math.nan(f64)), false);
    try expectPrinted("##-Inf", num.boxF64(-std.math.inf(f64)), false);
}

test "strings, chars and constants" {
    try expectPrinted("a\"b\n", string.make("a\"b\n"), false);
    try expectPrinted("\"a\\\"b\\n\\u0001\"", string.make("a\"b\n\x01"), true);
    try expectPrinted("c", Value.fromChar('c'), false);
    try expectPrinted("\\c", Value.fromChar('c'), true);
    try expectPrinted("\\newline", Value.fromChar('\n'), true);
    try expectPrinted("\\é", Value.fromChar(0xE9), true);
    try expectPrinted("nil", Value.nil, true);
    try expectPrinted("false", Value.false, false);
    try expectPrinted("-42", Value.fromFixnum(-42), false);
}
