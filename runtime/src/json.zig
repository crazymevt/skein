//! skein.json's primitives natively (M3.2, D-104): reading JSON text into Skein data, and
//! (step 3) writing and reformatting it. lib/skein/json.skn wraps these.
//!
//! Reading is recursive descent over the text's bytes, copied out of the heap: objects
//! become maps (keys strings, or what :key-fn makes them), arrays vectors, numbers integers
//! (bignums if they need) or f64s, true, false and null themselves.

const std = @import("std");
const rt = @import("rt.zig");
const coll = @import("coll.zig");
const func = @import("func.zig");
const names = @import("names.zig");
const num = @import("num.zig");
const print = @import("print.zig");
const string = @import("string.zig");
const io = @import("io.zig");
const Value = @import("value.zig").Value;

const alloc = std.heap.c_allocator;

fn readable(v: Value) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    print.write(v, &buf, true);
    return buf.items;
}

// ---------------------------------------------------------------------------------------
// Reading

/// Deeper nesting is an error rather than a fiber's stack overflow.
const max_depth = 512;

const Parser = struct {
    text: []const u8,
    i: usize = 0,
    key_fn: Value,
    value_fn: Value,
    depth: u32 = 0,
    message: []const u8 = "",
    /// The text ended inside a value (json/read reads another line then).
    incomplete: bool = false,
    buf: std.ArrayList(u8) = .empty,
};

const Bad = error{Bad};

fn fail(p: *Parser, message: []const u8) Bad {
    p.message = message;
    return error.Bad;
}

fn failEnd(p: *Parser) Bad {
    p.incomplete = true;
    return fail(p, "the text ends inside a value");
}

fn skipSpace(p: *Parser) void {
    while (p.i < p.text.len) : (p.i += 1) {
        switch (p.text[p.i]) {
            ' ', '\t', '\n', '\r' => {},
            else => return,
        }
    }
}

fn parseValue(p: *Parser) Bad!Value {
    skipSpace(p);
    if (p.i >= p.text.len) return failEnd(p);
    return switch (p.text[p.i]) {
        '{' => parseObject(p),
        '[' => parseArray(p),
        '"' => string.make(try parseString(p)),
        't' => parseLiteral(p, "true", Value.true),
        'f' => parseLiteral(p, "false", Value.false),
        'n' => parseLiteral(p, "null", Value.nil),
        '-', '0'...'9' => parseNumber(p),
        else => fail(p, "unexpected character"),
    };
}

fn parseLiteral(p: *Parser, word: []const u8, v: Value) Bad!Value {
    const rest = p.text[p.i..];
    const n = @min(rest.len, word.len);
    if (!std.mem.eql(u8, rest[0..n], word[0..n])) return fail(p, "unexpected word");
    if (n < word.len) return failEnd(p);
    p.i += word.len;
    return v;
}

fn enter(p: *Parser) Bad!void {
    p.depth += 1;
    if (p.depth > max_depth) return fail(p, "the value is nested too deeply");
}

fn parseArray(p: *Parser) Bad!Value {
    try enter(p);
    p.i += 1;
    var v = coll.vectorOf(&.{});
    skipSpace(p);
    if (p.i < p.text.len and p.text[p.i] == ']') {
        p.i += 1;
        p.depth -= 1;
        return v;
    }
    while (true) {
        v = coll.vectorConj(v, try parseValue(p));
        skipSpace(p);
        if (p.i >= p.text.len) return failEnd(p);
        switch (p.text[p.i]) {
            ',' => p.i += 1,
            ']' => {
                p.i += 1;
                p.depth -= 1;
                return v;
            },
            else => return fail(p, "expected , or ] in an array"),
        }
    }
}

fn parseObject(p: *Parser) Bad!Value {
    try enter(p);
    p.i += 1;
    var m = coll.mapOf(&.{});
    skipSpace(p);
    if (p.i < p.text.len and p.text[p.i] == '}') {
        p.i += 1;
        p.depth -= 1;
        return m;
    }
    while (true) {
        skipSpace(p);
        if (p.i >= p.text.len) return failEnd(p);
        if (p.text[p.i] != '"') return fail(p, "expected a key (a string) in an object");
        var key = string.make(try parseString(p));
        if (p.key_fn != Value.nil) key = func.call(p.key_fn, 1, &.{key});
        skipSpace(p);
        if (p.i >= p.text.len) return failEnd(p);
        if (p.text[p.i] != ':') return fail(p, "expected : after a key");
        p.i += 1;
        var val = try parseValue(p);
        var keep = true;
        if (p.value_fn != Value.nil) {
            // data.json's :value-fn: returning itself leaves the entry out.
            val = func.call(p.value_fn, 2, &.{ key, val });
            keep = val != p.value_fn;
        }
        if (keep) m = coll.mapAssoc(m, key, val);
        skipSpace(p);
        if (p.i >= p.text.len) return failEnd(p);
        switch (p.text[p.i]) {
            ',' => p.i += 1,
            '}' => {
                p.i += 1;
                p.depth -= 1;
                return m;
            },
            else => return fail(p, "expected , or } in an object"),
        }
    }
}

fn hex4(p: *Parser) Bad!u21 {
    if (p.i + 4 > p.text.len) return failEnd(p);
    const n = std.fmt.parseInt(u16, p.text[p.i .. p.i + 4], 16) catch return fail(p, "a \\u escape needs 4 hex digits");
    p.i += 4;
    return n;
}

/// The text of the string at p.i (its quotes and escapes resolved), in p.buf.
fn parseString(p: *Parser) Bad![]const u8 {
    p.i += 1;
    p.buf.clearRetainingCapacity();
    while (true) {
        if (p.i >= p.text.len) return failEnd(p);
        const c = p.text[p.i];
        switch (c) {
            '"' => {
                p.i += 1;
                return p.buf.items;
            },
            '\\' => {
                p.i += 1;
                if (p.i >= p.text.len) return failEnd(p);
                const e = p.text[p.i];
                p.i += 1;
                const out: u8 = switch (e) {
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    'b' => 8,
                    'f' => 12,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'u' => {
                        var cp = try hex4(p);
                        if (cp >= 0xD800 and cp <= 0xDBFF) {
                            // A high surrogate: its low one follows as \uXXXX.
                            if (p.i >= p.text.len) return failEnd(p);
                            if (p.text[p.i] != '\\') return fail(p, "a lone surrogate in a \\u escape");
                            if (p.i + 1 >= p.text.len) return failEnd(p);
                            if (p.text[p.i + 1] != 'u') return fail(p, "a lone surrogate in a \\u escape");
                            p.i += 2;
                            const low = try hex4(p);
                            if (low < 0xDC00 or low > 0xDFFF) return fail(p, "a lone surrogate in a \\u escape");
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                        } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                            return fail(p, "a lone surrogate in a \\u escape");
                        }
                        var enc: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &enc) catch unreachable;
                        p.buf.appendSlice(alloc, enc[0..n]) catch rt.fatal("out of memory", .{});
                        continue;
                    },
                    else => {
                        p.i -= 1;
                        return fail(p, "an unknown escape");
                    },
                };
                p.buf.append(alloc, out) catch rt.fatal("out of memory", .{});
            },
            else => {
                if (c < 0x20) return fail(p, "a control character in a string");
                p.buf.append(alloc, c) catch rt.fatal("out of memory", .{});
                p.i += 1;
            },
        }
    }
}

fn digits(p: *Parser) usize {
    const start = p.i;
    while (p.i < p.text.len and std.ascii.isDigit(p.text[p.i])) p.i += 1;
    return p.i - start;
}

/// -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?: an integer without a fraction or an
/// exponent, else an f64.
fn parseNumber(p: *Parser) Bad!Value {
    const start = p.i;
    if (p.text[p.i] == '-') p.i += 1;
    if (p.i >= p.text.len) return failEnd(p);
    if (p.text[p.i] == '0') {
        p.i += 1;
    } else if (digits(p) == 0) {
        return fail(p, "a number needs digits");
    }
    var float = false;
    if (p.i < p.text.len and p.text[p.i] == '.') {
        float = true;
        p.i += 1;
        if (digits(p) == 0) return if (p.i >= p.text.len) failEnd(p) else fail(p, "a number needs digits after its .");
    }
    if (p.i < p.text.len and (p.text[p.i] == 'e' or p.text[p.i] == 'E')) {
        float = true;
        p.i += 1;
        if (p.i < p.text.len and (p.text[p.i] == '+' or p.text[p.i] == '-')) p.i += 1;
        if (digits(p) == 0) return if (p.i >= p.text.len) failEnd(p) else fail(p, "a number needs digits in its exponent");
    }
    const text = p.text[start..p.i];
    if (float) return num.boxF64(std.fmt.parseFloat(f64, text) catch return fail(p, "a number out of range"));
    return num.parseInteger(text);
}

/// The line and column (counting characters) of byte `i` of `text`, from 1.
fn place(text: []const u8, i: usize) [2]i64 {
    var line: i64 = 1;
    var col: i64 = 1;
    for (text[0..@min(i, text.len)]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else if (c & 0xC0 != 0x80) {
            col += 1;
        }
    }
    return .{ line, col };
}

/// (%json-read s key-fn value-fn): [:ok value], [:error message line column], or
/// [:incomplete] if the text ends inside its value.
fn read(s: Value, key_fn: Value, value_fn: Value) Value {
    if (!string.isString(s)) rt.raise(.type_error, "reading JSON needs a string, not {s}", .{readable(s)});
    const text = alloc.dupe(u8, string.bytes(s)) catch rt.fatal("out of memory", .{});
    defer alloc.free(text);
    var p: Parser = .{ .text = text, .key_fn = key_fn, .value_fn = value_fn };
    defer p.buf.deinit(alloc);
    const v = parseValue(&p) catch return outcome(&p);
    skipSpace(&p);
    if (p.i < p.text.len) {
        p.message = "text after the value";
        return outcome(&p);
    }
    return coll.vectorOf(&.{ names.keyword(null, "ok"), v });
}

fn outcome(p: *Parser) Value {
    if (p.incomplete) return coll.vectorOf(&.{names.keyword(null, "incomplete")});
    const at = place(p.text, p.i);
    return coll.vectorOf(&.{
        names.keyword(null, "error"),  string.make(p.message),
        Value.fromFixnum(at[0]), Value.fromFixnum(at[1]),
    });
}

// ---------------------------------------------------------------------------------------
// skein.core functions (core.zig's table includes these)

const Args = []const Value;

pub const entries = [_]io.Entry{
    .{ .name = "%json-read", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            return read(a[0], a[1], a[2]);
        }
    }.f },
};
