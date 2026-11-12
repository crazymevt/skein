//! Seqs (DESIGN §7, M1.8, D-052), as Phase 0's seq.lisp: `seq` gives nil for an empty
//! collection, else a seq of its elements, which `first`, `next` and `rest` walk.
//!
//! Lists are their own seqs. Vectors and strings get a seq object that keeps an index, so
//! walking them allocates nothing per element but the seq cells. Maps and sets are walked
//! into a list of entries or keys, in the order Phase 0 uses. Cons cells and lazy seqs
//! carry what the library in Skein (lib/skein/core/native.skn) builds: a lazy seq runs
//! its thunk once, the first time it is seq'd.

const std = @import("std");
const rt = @import("rt.zig");
const gc = @import("gc.zig");
const coll = @import("coll.zig");
const string = @import("string.zig");
const func = @import("func.zig");
const print = @import("print.zig");
const structs = @import("structs.zig");
const Value = @import("value.zig").Value;

fn make(t: @import("object.zig").TypeId, slots: []const Value) Value {
    const h = rt.alloc(t, slots.len);
    @memcpy(h.valueSlots()[0..slots.len], slots);
    return Value.fromObject(h);
}

/// A cons cell: x followed by the elements of the seqable `more`.
pub fn cons(x: Value, more: Value) Value {
    return make(.cons, &.{ x, more });
}

pub fn lazySeq(thunk: Value) Value {
    return make(.lazy_seq, &.{ thunk, Value.nil });
}

pub fn reduced(x: Value) Value {
    return make(.reduced, &.{x});
}

pub fn isReduced(v: Value) bool {
    return v.isObjectOf(.reduced);
}

pub fn unreduced(v: Value) Value {
    return if (isReduced(v)) coll.get(v, 0) else v;
}

pub fn eduction(xform: Value, c: Value, seq_fn: Value, reduce_fn: Value) Value {
    return make(.eduction, &.{ xform, c, seq_fn, reduce_fn });
}

/// True for lists and the seq objects (seq? in Phase 0).
pub fn isSeq(v: Value) bool {
    if (!v.isObject()) return false;
    return switch (v.toObject().type_id) {
        .list, .empty_list, .cons, .lazy_seq, .vseq, .sseq, .arrseq, .tseq => true,
        else => false,
    };
}

/// Lists, vectors and seqs: equal when their elements are, whatever their type.
pub fn isSequential(v: Value) bool {
    return isSeq(v) or coll.isVector(v);
}

fn readable(v: Value) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    print.write(v, &out, true);
    return out.items;
}

/// Realize the lazy seq `ls` (once) and return its seq: nil or a seq.
fn realize(ls: Value) Value {
    const h = ls.toObject();
    const thunk = h.valueSlots()[0];
    if (thunk != Value.nil) {
        var v = func.call(thunk, 0, &.{});
        // A lazy seq whose body gives another lazy seq takes that one's elements.
        while (v.isObjectOf(.lazy_seq)) v = realize(v);
        gc.store(h, &h.valueSlots()[1], seq(v));
        gc.store(h, &h.valueSlots()[0], Value.nil);
    }
    return h.valueSlots()[1];
}

pub fn isRealized(v: Value) bool {
    return v.isObjectOf(.lazy_seq) and coll.get(v, 0) == Value.nil;
}

/// nil if `x` is empty, else a seq of its elements.
pub fn seq(x: Value) Value {
    if (x == Value.nil) return Value.nil;
    // A string's seq: [string, character index, byte offset], so each step decodes one
    // character where it is (by index alone, text outside ASCII took quadratic time).
    if (string.isString(x)) return if (string.count(x) == 0) Value.nil else make(.sseq, &.{ x, Value.fromFixnum(0), Value.fromFixnum(0) });
    if (!x.isObject()) unseqable(x);
    return switch (x.toObject().type_id) {
        .list, .cons, .vseq, .sseq, .arrseq, .tseq => x,
        .empty_list => Value.nil,
        .lazy_seq => realize(x),
        .vector => if (coll.vectorCount(x) == 0) Value.nil else make(.vseq, &.{ x, Value.fromFixnum(0) }),
        .array_map, .hash_map => mapSeq(x, false),
        .hash_set => mapSeq(coll.get(x, 0), true),
        .sorted_map, .sorted_set => @import("sorted.zig").seq(x, false),
        .eduction => seq(func.call(coll.get(x, 2), 0, &.{})),
        .prim_array, .any_array, .struct_array, .array_view => if (structs.count(x) == 0) Value.nil else make(.arrseq, &.{ x, Value.fromFixnum(0) }),
        else => unseqable(x),
    };
}

fn unseqable(x: Value) noreturn {
    rt.raise(.unsupported_operation_error, "{s} is not seqable", .{readable(x)});
}

/// A list of a map's entries ([k v] vectors), or of a set's elements, in iteration order.
fn mapSeq(m: Value, keys_only: bool) Value {
    if (coll.mapCount(m) == 0) return Value.nil;
    const Gather = struct {
        t: Value,
        keys_only: bool,
        fn add(c: *@This(), k: Value, v: Value) bool {
            c.t = coll.tvectorConj(c.t, if (c.keys_only) k else coll.vectorOf(&.{ k, v }));
            return true;
        }
    };
    var ctx: Gather = .{ .t = coll.vectorTransient(coll.empty_vector), .keys_only = keys_only };
    coll.mapEach(m, &ctx, Gather.add);
    const v = coll.tvectorPersistent(ctx.t);
    var result = coll.empty_list;
    var i = coll.vectorCount(v);
    while (i > 0) {
        i -= 1;
        result = coll.cons(coll.vectorNth(v, i).?, result);
    }
    return result;
}

/// The first element of a seq (as seq returns).
pub fn seqFirst(s: Value) Value {
    return switch (s.toObject().type_id) {
        .list, .cons => coll.get(s, 0),
        .vseq => coll.vectorNth(coll.get(s, 0), coll.ux(coll.get(s, 1))).?,
        .sseq => Value.fromChar(string.charAtByte(coll.get(s, 0), coll.ux(coll.get(s, 2)))),
        .arrseq => structs.aget(coll.get(s, 0), coll.get(s, 1)),
        .tseq => @import("sorted.zig").seqFirst(s),
        else => unreachable,
    };
}

/// The seq after the first element of a seq, or nil.
pub fn seqNext(s: Value) Value {
    switch (s.toObject().type_id) {
        .list => {
            const r = coll.get(s, 1);
            return if (r.isObjectOf(.list)) r else Value.nil;
        },
        .cons => return seq(coll.get(s, 1)),
        .vseq => {
            const v = coll.get(s, 0);
            const i = coll.ux(coll.get(s, 1)) + 1;
            return if (i < coll.vectorCount(v)) make(.vseq, &.{ v, Value.fromFixnum(@intCast(i)) }) else Value.nil;
        },
        .arrseq => {
            const a = coll.get(s, 0);
            const i = coll.ux(coll.get(s, 1)) + 1;
            return if (i < structs.count(a)) make(.arrseq, &.{ a, Value.fromFixnum(@intCast(i)) }) else Value.nil;
        },
        .sseq => {
            const str = coll.get(s, 0);
            const i = coll.ux(coll.get(s, 1)) + 1;
            if (i >= string.count(str)) return Value.nil;
            const off = string.nextByte(str, coll.ux(coll.get(s, 2)));
            return make(.sseq, &.{ str, Value.fromFixnum(@intCast(i)), Value.fromFixnum(@intCast(off)) });
        },
        .tseq => return @import("sorted.zig").seqNext(s),
        else => unreachable,
    }
}

/// What follows the first element of a seq, without realizing a lazy rest.
pub fn seqRest(s: Value) Value {
    return switch (s.toObject().type_id) {
        .list => coll.get(s, 1),
        .cons => {
            const more = coll.get(s, 1);
            return if (more == Value.nil) coll.empty_list else more;
        },
        else => {
            const n = seqNext(s);
            return if (n == Value.nil) coll.empty_list else n;
        },
    };
}

pub fn first(x: Value) Value {
    const s = seq(x);
    return if (s == Value.nil) Value.nil else seqFirst(s);
}

pub fn rest(x: Value) Value {
    const s = seq(x);
    return if (s == Value.nil) coll.empty_list else seqRest(s);
}

pub fn next(x: Value) Value {
    const s = seq(x);
    return if (s == Value.nil) Value.nil else seqNext(s);
}

/// Call f(ctx, x) for each element of the seqable `x`, in order, until f returns false.
/// Maps give [key value] vectors.
pub fn each(x: Value, ctx: anytype, comptime f: fn (@TypeOf(ctx), Value) bool) void {
    if (x == Value.nil) return;
    if (coll.isVector(x)) {
        for (0..coll.vectorCount(x)) |i| if (!f(ctx, coll.vectorNth(x, i).?)) return;
        return;
    }
    if (coll.isMap(x) or coll.isSet(x)) {
        const Wrap = struct {
            fn entry(w: @TypeOf(ctx), k: Value, v: Value) bool {
                return f(w, coll.vectorOf(&.{ k, v }));
            }
            fn key(w: @TypeOf(ctx), k: Value, _: Value) bool {
                return f(w, k);
            }
        };
        if (coll.isSet(x)) return coll.mapEach(coll.get(x, 0), ctx, Wrap.key);
        return coll.mapEach(x, ctx, Wrap.entry);
    }
    var s = seq(x);
    while (s != Value.nil) : (s = seqNext(s)) {
        if (!f(ctx, seqFirst(s))) return;
    }
}

/// The number of elements of a seq, walking it (realizing a lazy one).
pub fn countSeq(x: Value) usize {
    var n: usize = 0;
    var s = seq(x);
    while (s != Value.nil) : (s = seqNext(s)) n += 1;
    return n;
}

// ---------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn setup() void {
    coll.ensureConstants();
}

test "seq walks vectors, strings, lists, maps and sets" {
    setup();
    const v = coll.vectorOf(&.{ Value.fromFixnum(1), Value.fromFixnum(2) });
    try testing.expectEqual(Value.nil, seq(coll.vectorOf(&.{})));
    try testing.expectEqual(@as(i64, 1), first(v).toFixnum());
    try testing.expectEqual(@as(i64, 2), first(next(v)).toFixnum());
    try testing.expectEqual(Value.nil, next(next(v)));
    try testing.expect(rest(next(v)).isObjectOf(.empty_list));
    const s = string.make("ab");
    try testing.expectEqual(@as(u21, 'b'), first(next(s)).toChar());
    try testing.expectEqual(@as(usize, 2), countSeq(s));
    const m = coll.mapOf(&.{ Value.fromFixnum(1), Value.fromFixnum(10) });
    try testing.expect(coll.isVector(first(m)));
    try testing.expectEqual(@as(usize, 1), countSeq(coll.setOf(&.{Value.true})));
}

var thunk_calls: usize = 0;

fn testThunk(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = self;
    _ = argc;
    _ = argv;
    thunk_calls += 1;
    return cons(Value.fromFixnum(7), coll.vectorOf(&.{Value.fromFixnum(8)}));
}

test "a lazy seq runs its thunk once, when first seq'd" {
    setup();
    thunk_calls = 0;
    const ls = lazySeq(func.make(testThunk, "thunk"));
    try testing.expect(!isRealized(ls));
    try testing.expect(isSeq(ls) and isSequential(ls));
    try testing.expectEqual(@as(i64, 7), first(ls).toFixnum());
    try testing.expect(isRealized(ls));
    try testing.expectEqual(@as(i64, 8), first(next(ls)).toFixnum());
    try testing.expectEqual(@as(usize, 2), countSeq(ls));
    try testing.expectEqual(@as(usize, 1), thunk_calls);
    // A lazy seq whose thunk gives another lazy seq takes its elements.
    const outer = lazySeq(func.make(struct {
        fn f(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
            _ = self;
            _ = argc;
            _ = argv;
            return lazySeq(func.make(testThunk, "inner"));
        }
    }.f, "outer"));
    try testing.expectEqual(@as(i64, 7), first(outer).toFixnum());
}

test "reduced wraps and unwraps" {
    setup();
    const r = reduced(Value.fromFixnum(3));
    try testing.expect(isReduced(r));
    try testing.expectEqual(@as(i64, 3), unreduced(r).toFixnum());
    try testing.expectEqual(@as(i64, 4), unreduced(Value.fromFixnum(4)).toFixnum());
}
