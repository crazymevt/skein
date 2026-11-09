//! Equality, hashing and ordering (DESIGN §7), as in Phase 0's equality.lisp (D-046):
//! value equality for numbers, strings, chars, symbols, keywords and persistent
//! collections; identity for everything else. Integers never equal floats; sequential
//! collections (lists and vectors) are equal when their elements are.

const std = @import("std");
const num = @import("num.zig");
const string = @import("string.zig");
const names = @import("names.zig");
const coll = @import("coll.zig");
const hash = @import("hash.zig");
const rt = @import("rt.zig");
const Value = @import("value.zig").Value;
const Limb = std.math.big.Limb;

fn isSequential(v: Value) bool {
    return coll.isList(v) or coll.isVector(v);
}

/// Calls f(ctx, x) for each element of a list or vector, in order, until f returns false.
pub fn eachElement(v: Value, ctx: anytype, comptime f: fn (@TypeOf(ctx), Value) bool) void {
    if (coll.isVector(v)) {
        for (0..coll.vectorCount(v)) |i| if (!f(ctx, coll.vectorNth(v, i).?)) return;
        return;
    }
    var it = v;
    while (it.isObjectOf(.list)) : (it = coll.get(it, 1)) {
        if (!f(ctx, coll.get(it, 0))) return;
    }
}

fn sequentialCount(v: Value) usize {
    if (coll.isVector(v)) return coll.vectorCount(v);
    return if (v.isObjectOf(.list)) coll.ux(coll.get(v, 2)) else 0;
}

/// The element at position `i` of a list or vector.
fn sequentialNth(v: Value, i: usize) Value {
    if (coll.isVector(v)) return coll.vectorNth(v, i).?;
    var it = v;
    for (0..i) |_| it = coll.get(it, 1);
    return coll.get(it, 0);
}

pub fn equiv(a: Value, b: Value) bool {
    if (num.isNumber(a)) return num.isNumber(b) and num.numbersEqual(a, b);
    if (a == b) return true;
    if (string.isString(a))
        return string.isString(b) and std.mem.eql(u8, string.bytes(a), string.bytes(b));
    if (names.isSymbol(a)) {
        // Interned, so equal symbols are identical (checked above).
        return false;
    }
    if (isSequential(a)) {
        if (!isSequential(b)) return false;
        const n = sequentialCount(a);
        if (n != sequentialCount(b)) return false;
        if (coll.isVector(a) and coll.isVector(b)) {
            for (0..n) |i| if (!equiv(coll.vectorNth(a, i).?, coll.vectorNth(b, i).?)) return false;
            return true;
        }
        // Walk both; lists are linked, so step them rather than index.
        var ia = a;
        var ib = b;
        for (0..n) |i| {
            const xa = if (coll.isVector(a)) coll.vectorNth(a, i).? else blk: {
                const x = coll.get(ia, 0);
                ia = coll.get(ia, 1);
                break :blk x;
            };
            const xb = if (coll.isVector(b)) coll.vectorNth(b, i).? else blk: {
                const x = coll.get(ib, 0);
                ib = coll.get(ib, 1);
                break :blk x;
            };
            if (!equiv(xa, xb)) return false;
        }
        return true;
    }
    if (coll.isMap(a)) {
        if (!coll.isMap(b) or coll.mapCount(a) != coll.mapCount(b)) return false;
        var ctx: MapEq = .{ .other = b };
        coll.mapEach(a, &ctx, MapEq.check);
        return ctx.equal;
    }
    if (coll.isSet(a)) {
        if (!coll.isSet(b) or coll.setCount(a) != coll.setCount(b)) return false;
        var ctx: SetEq = .{ .other = b };
        coll.mapEach(coll.get(a, 0), &ctx, SetEq.check);
        return ctx.equal;
    }
    return false;
}

const MapEq = struct {
    other: Value,
    equal: bool = true,

    fn check(c: *MapEq, k: Value, v: Value) bool {
        const w = coll.mapGet(c.other, k) orelse {
            c.equal = false;
            return false;
        };
        if (!equiv(v, w)) c.equal = false;
        return c.equal;
    }
};

const SetEq = struct {
    other: Value,
    equal: bool = true,

    fn check(c: *SetEq, k: Value, _: Value) bool {
        if (!coll.setContains(c.other, k)) c.equal = false;
        return c.equal;
    }
};

// ---------------------------------------------------------------------------------------
// Hashing

/// A cached hash in slot `i` of a collection: nil until computed.
fn cached(v: Value, i: usize, comptime compute: fn (Value) u32) u32 {
    const slot = coll.get(v, i);
    if (slot != Value.nil) return @intCast(slot.toFixnum());
    const h = compute(v);
    // A fixnum, so no write barrier is needed, and racing writers write the same value.
    v.toObject().valueSlots()[i] = Value.fromFixnum(h);
    return h;
}

fn orderedHash(v: Value) u32 {
    var ctx: Ordered = .{};
    eachElement(v, &ctx, Ordered.add);
    return hash.mixCollection(ctx.h, ctx.n);
}

const Ordered = struct {
    h: u32 = 1,
    n: usize = 0,

    fn add(c: *Ordered, x: Value) bool {
        c.h = c.h *% 31 +% hashOf(x);
        c.n += 1;
        return true;
    }
};

const Unordered = struct {
    h: u32 = 0,

    fn addEntry(c: *Unordered, k: Value, v: Value) bool {
        c.h +%= hashOf(k) ^ hashOf(v);
        return true;
    }

    fn addKey(c: *Unordered, k: Value, _: Value) bool {
        c.h +%= hashOf(k);
        return true;
    }
};

fn mapHash(m: Value) u32 {
    var ctx: Unordered = .{};
    coll.mapEach(m, &ctx, Unordered.addEntry);
    return hash.mixCollection(ctx.h, coll.mapCount(m));
}

fn setHash(s: Value) u32 {
    var ctx: Unordered = .{};
    coll.mapEach(coll.get(s, 0), &ctx, Unordered.addKey);
    return hash.mixCollection(ctx.h, coll.setCount(s));
}

fn integerHash(v: Value) u32 {
    if (v.isFixnum()) return hash.hashInt(v.toFixnum());
    const p = v.toObject().payload();
    const limbs: [*]const Limb = @ptrCast(p[1..].ptr);
    return hash.mix32(hash.fold32Limbs(limbs[0 .. p.len - 1], p[0] != 0));
}

/// A 32-bit hash consistent with `equiv`.
pub fn hashOf(v: Value) u32 {
    if (v == Value.nil) return hash.nil_hash;
    if (v == Value.true) return hash.true_hash;
    if (v == Value.false) return hash.false_hash;
    if (v.isChar()) return hash.mix32(v.toChar());
    switch (num.kind(v)) {
        .int => return integerHash(v),
        .f32, .f64 => return hash.hashFloat(num.toF64(v)),
        .other => {},
    }
    if (!v.isObject()) return hash.mix32(@truncate(v.bits()));
    return switch (v.toObject().type_id) {
        .string => hash.hashString(string.bytes(v)),
        .symbol, .keyword => names.nameHash(v),
        .vector => cached(v, 4, orderedHash),
        .list => cached(v, 3, orderedHash),
        .empty_list => hash.mixCollection(1, 0),
        .array_map => cached(v, 1, mapHash),
        .hash_map => cached(v, 2, mapHash),
        .hash_set => cached(v, 1, setHash),
        .atom => @intCast(coll.get(v, 1).toFixnum()),
        // Identity: a function's code pointer, or for other objects... (permanent ones
        // never move, so their address will do).
        .function => hash.mix32(@truncate(v.toObject().payload()[0] >> 3)),
        else => hash.mix32(@truncate(@intFromPtr(v.toObject()) >> 3)),
    };
}

// ---------------------------------------------------------------------------------------
// Ordering (compare)

pub fn compare(a: Value, b: Value) i32 {
    if (a == Value.nil and b == Value.nil) return 0;
    if (a == Value.nil) return -1;
    if (b == Value.nil) return 1;
    if (num.isNumber(a) and num.isNumber(b)) {
        const o = num.compare("compare", a, b) orelse return 1;
        return switch (o) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }
    if (string.isString(a) and string.isString(b)) return order(std.mem.order(u8, string.bytes(a), string.bytes(b)));
    if (a.isChar() and b.isChar()) return order(std.math.order(a.toChar(), b.toChar()));
    if ((a == Value.true or a == Value.false) and (b == Value.true or b == Value.false)) {
        if (a == b) return 0;
        return if (a == Value.false) -1 else 1;
    }
    if ((names.isSymbol(a) and names.isSymbol(b)) or (names.isKeyword(a) and names.isKeyword(b))) {
        const na = names.nsOf(a);
        const nb = names.nsOf(b);
        if (na != null and nb != null and !std.mem.eql(u8, na.?, nb.?)) return order(std.mem.order(u8, na.?, nb.?));
        if (na == null and nb != null) return -1;
        if (na != null and nb == null) return 1;
        return order(std.mem.order(u8, names.nameOf(a), names.nameOf(b)));
    }
    if (coll.isVector(a) and coll.isVector(b)) {
        const n = coll.vectorCount(a);
        const m = coll.vectorCount(b);
        if (n != m) return if (n < m) -1 else 1;
        for (0..n) |i| {
            const c = compare(coll.vectorNth(a, i).?, coll.vectorNth(b, i).?);
            if (c != 0) return c;
        }
        return 0;
    }
    const print = @import("print.zig");
    var ba: std.ArrayList(u8) = .empty;
    var bb: std.ArrayList(u8) = .empty;
    print.write(a, &ba, true);
    print.write(b, &bb, true);
    rt.fatal("cannot compare {s} with {s}", .{ ba.items, bb.items });
}

fn order(o: std.math.Order) i32 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

pub fn nthSequential(v: Value, i: usize) Value {
    return sequentialNth(v, i);
}

pub fn countSequential(v: Value) usize {
    return sequentialCount(v);
}
