//! skein.core functions in the native runtime (M1.4, D-046): collections, strings,
//! names, atoms, transients and predicates, matching Phase 0's behavior. Each is also a
//! function object (`function`), so compiled code can pass it around: `(swap! a inc)`.
//! Seqs over maps and sets, laziness and the rest of skein.core come in M1.8.

const std = @import("std");
const rt = @import("rt.zig");
const num = @import("num.zig");
const string = @import("string.zig");
const names = @import("names.zig");
const coll = @import("coll.zig");
const equal = @import("equal.zig");
const func = @import("func.zig");
const print = @import("print.zig");
const gc = @import("gc.zig");
const platform = @import("platform");
const cond = @import("cond.zig");
const seqs = @import("seq.zig");
const objs = @import("objects.zig");
const structs = @import("structs.zig");
const tasks = @import("tasks.zig");
const watch = @import("watch.zig");
const sorted = @import("sorted.zig");
const io = @import("io.zig");
const compiler = @import("compiler.zig");
const ffi = @import("ffi.zig");
const mathtime = @import("mathtime.zig");
const evaluate = @import("evaluate.zig");
const devio = @import("devio.zig");
const Value = @import("value.zig").Value;

const Args = []const Value;

fn typeName(v: Value) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    print.write(v, &buf, true);
    return buf.items;
}

fn bitArg(v: Value, comptime name: []const u8) i64 {
    if (!v.isFixnum()) rt.raise(.@"error", name ++ " needs fixnums, not {s}", .{typeName(v)});
    return v.toFixnum();
}

fn shiftArg(v: Value, comptime name: []const u8) u64 {
    if (!v.isFixnum() or v.toFixnum() < 0) rt.raise(.@"error", name ++ " needs a non-negative shift, not {s}", .{typeName(v)});
    return @intCast(@min(v.toFixnum(), 127));
}

const BitOp = enum { @"and", @"or", xor, and_not };

fn bitFold(comptime op: BitOp) fn (Args) Value {
    return struct {
        fn f(a: Args) Value {
            var x = bitArg(a[0], "bit operation");
            for (a[1..]) |v| {
                const y = bitArg(v, "bit operation");
                x = switch (op) {
                    .@"and" => x & y,
                    .@"or" => x | y,
                    .xor => x ^ y,
                    .and_not => x & ~y,
                };
            }
            return Value.fromFixnum(x);
        }
    }.f;
}

const BitAt = enum { set, clear, flip };

fn bitAt(comptime op: BitAt) fn (Args) Value {
    return struct {
        fn f(a: Args) Value {
            const x: i128 = bitArg(a[0], "bit-set, bit-clear or bit-flip");
            const n = shiftArg(a[1], "bit-set, bit-clear or bit-flip");
            const mask = @as(i128, 1) << @intCast(@min(n, 126));
            return num.fromI128(switch (op) {
                .set => x | mask,
                .clear => x & ~mask,
                .flip => x ^ mask,
            });
        }
    }.f;
}

fn badArg(comptime name: []const u8, v: Value) noreturn {
    rt.raise(.type_error, name ++ " can't use {s}", .{typeName(v)});
}

fn index(comptime name: []const u8, v: Value) usize {
    if (!v.isFixnum() or v.toFixnum() < 0) rt.raise(.type_error, name ++ " needs a non-negative integer index, not {s}", .{typeName(v)});
    return @intCast(v.toFixnum());
}

fn int(n: i64) Value {
    return num.fromI128(n);
}

// ---------------------------------------------------------------------------------------
// Collections

pub fn count(v: Value) usize {
    if (v == Value.nil) return 0;
    if (string.isString(v)) return string.count(v);
    if (!v.isObject()) badArg("count", v);
    return switch (v.toObject().type_id) {
        .empty_list => 0,
        .list => coll.ux(coll.get(v, 2)),
        .vector => coll.vectorCount(v),
        .array_map, .hash_map, .sorted_map => coll.mapCount(v),
        .hash_set, .sorted_set => coll.setCount(v),
        .transient_vector, .transient_map => coll.ux(coll.get(v, 0)),
        .transient_set => coll.ux(coll.get(coll.get(v, 0), 0)),
        .vseq => coll.vectorCount(coll.get(v, 0)) - coll.ux(coll.get(v, 1)),
        .prim_array, .any_array, .struct_array, .array_view, .byte_view => structs.count(v),
        .arrseq => structs.count(coll.get(v, 0)) - coll.ux(coll.get(v, 1)),
        .sseq => string.count(coll.get(v, 0)) - coll.ux(coll.get(v, 1)),
        .cons, .lazy_seq, .eduction, .tseq => seqs.countSeq(v),
        else => badArg("count", v),
    };
}

fn conj1(c: Value, x: Value) Value {
    if (c == Value.nil or coll.isList(c)) return coll.cons(x, c);
    if (seqs.isSeq(c)) return seqs.cons(x, c);
    if (coll.isVector(c)) return coll.vectorConj(c, x);
    if (coll.isSet(c)) return coll.setConj(c, x);
    if (coll.isMap(c)) {
        if (coll.isVector(x) and coll.vectorCount(x) == 2)
            return coll.mapAssoc(c, coll.vectorNth(x, 0).?, coll.vectorNth(x, 1).?);
        if (coll.isMap(x)) {
            var ctx: Into = .{ .to = c };
            coll.mapEach(x, &ctx, Into.entry);
            return ctx.to;
        }
        rt.raise(.type_error, "conj on a map needs a [key value] vector or a map, not {s}", .{typeName(x)});
    }
    badArg("conj", c);
}

const Into = struct {
    to: Value,

    fn entry(c: *Into, k: Value, v: Value) bool {
        c.to = coll.mapAssoc(c.to, k, v);
        return true;
    }
};

/// Call f(ctx, x) for each element of a seqable value (maps give [k v] vectors).
fn each(c: Value, ctx: anytype, comptime f: fn (@TypeOf(ctx), Value) void) void {
    const Wrap = struct {
        fn el(w: @TypeOf(ctx), x: Value) bool {
            f(w, x);
            return true;
        }
    };
    seqs.each(c, ctx, Wrap.el);
}

fn get(c: Value, k: Value, not_found: Value) Value {
    if (c == Value.nil) return not_found;
    if (coll.isMap(c)) return coll.mapGet(c, k) orelse not_found;
    if (coll.isSet(c)) return if (coll.setContains(c, k)) coll.mapGet(coll.get(c, 0), k).? else not_found;
    if (coll.isVector(c)) {
        if (!k.isFixnum() or k.toFixnum() < 0) return not_found;
        return coll.vectorNth(c, @intCast(k.toFixnum())) orelse not_found;
    }
    if (string.isString(c)) {
        if (!k.isFixnum() or k.toFixnum() < 0 or k.toFixnum() >= string.count(c)) return not_found;
        return Value.fromChar(string.charAt(c, @intCast(k.toFixnum())));
    }
    if (c.isObjectOf(.transient_map)) return coll.tmapGet(c, k) orelse not_found;
    // A struct's fields, by keyword.
    if (c.isObjectOf(.@"struct")) return structs.get(c, k) orelse not_found;
    // An instance's slots, by keyword (DESIGN §8.2).
    if (c.isObjectOf(.instance)) return objs.get(c, k) orelse not_found;
    // A condition's slots, by keyword: (:path c) (DESIGN §10).
    if (cond.isCondition(c) and (names.isKeyword(k) or names.isSymbol(k)))
        return cond.slotValue(c, names.nameOf(k)) orelse not_found;
    if (c.isObjectOf(.transient_vector)) {
        if (!k.isFixnum() or k.toFixnum() < 0) return not_found;
        return coll.tvectorNth(c, @intCast(k.toFixnum())) orelse not_found;
    }
    return not_found;
}

fn nth(c: Value, i_value: Value, not_found: ?Value) Value {
    const i = index("nth", i_value);
    if (c == Value.nil) return not_found orelse Value.nil;
    if (coll.isMap(c) or coll.isSet(c)) rt.raise(.unsupported_operation_error, "nth is not supported on {s}", .{typeName(c)});
    if (coll.isVector(c) or string.isString(c)) {
        const n = count(c);
        if (i >= n) {
            if (not_found) |nf| return nf;
            coll.indexError(i_value, n);
        }
        if (coll.isVector(c)) return coll.vectorNth(c, i).?;
        return Value.fromChar(string.charAt(c, i));
    }
    // Walk a seq without counting it first: it may be infinite.
    var sq = seqs.seq(c);
    var k: usize = 0;
    while (sq != Value.nil) : ({
        sq = seqs.seqNext(sq);
        k += 1;
    }) {
        if (k == i) return seqs.seqFirst(sq);
    }
    if (not_found) |nf| return nf;
    rt.raise(.index_error, "index {d} is out of bounds", .{i});
}

fn assoc1(c: Value, k: Value, v: Value) Value {
    if (c == Value.nil) return coll.mapAssoc(coll.empty_map, k, v);
    if (coll.isMap(c)) return coll.mapAssoc(c, k, v);
    if (coll.isVector(c)) return coll.vectorAssoc(c, index("assoc", k), v);
    badArg("assoc", c);
}

fn listFrom(c: Value) Value {
    // The elements of c as a list (for rest of a vector, cons onto a vector, ...).
    var buf: [64]Value = undefined;
    const n = count(c);
    if (n <= buf.len) {
        var ctx: Collect = .{ .buf = &buf };
        each(c, &ctx, Collect.add);
        return coll.listOf(buf[0..n]);
    }
    // Build from the back with cons, reading elements by index (vectors).
    var result = coll.empty_list;
    var i = n;
    while (i > 0) {
        i -= 1;
        result = coll.cons(coll.vectorNth(c, i).?, result);
    }
    return result;
}

const Collect = struct {
    buf: []Value,
    n: usize = 0,

    fn add(c: *Collect, x: Value) void {
        c.buf[c.n] = x;
        c.n += 1;
    }
};

fn first(c: Value) Value {
    return seqs.first(c);
}

fn rest(c: Value) Value {
    return seqs.rest(c);
}


// ---------------------------------------------------------------------------------------
// The table

const Impl = *const fn (Args) Value;
const Entry = struct { name: []const u8, min: u32, max: ?u32, impl: Impl };

fn e(comptime name: []const u8, min: u32, max: ?u32, comptime impl: fn (Args) Value) Entry {
    return .{ .name = name, .min = min, .max = max, .impl = impl };
}

fn printFn(comptime readably: bool, comptime newline: bool) fn (Args) Value {
    return struct {
        fn f(a: Args) Value {
            print.printValues(a, readably, newline);
            return Value.nil;
        }
    }.f;
}

fn foldArith(comptime op: num.Op, comptime identity: i64) fn (Args) Value {
    return struct {
        fn f(a: Args) Value {
            if (a.len == 0) return int(identity);
            if (a.len == 1) {
                if (op == .sub) return num.arith(.mul, int(-1), a[0]);
                if (op == .div) return num.arith(.div, int(1), a[0]);
                if (!num.isNumber(a[0])) num.notANumber(@tagName(op), a[0]);
                return a[0];
            }
            var acc = a[0];
            for (a[1..]) |x| acc = num.arith(op, acc, x);
            return acc;
        }
    }.f;
}

fn chainCompare(comptime name: []const u8, comptime ok: fn (std.math.Order) bool) fn (Args) Value {
    return struct {
        fn f(a: Args) Value {
            for (a[0 .. a.len - 1], a[1..]) |x, y| {
                const o = num.compare(name, x, y) orelse return Value.false;
                if (!ok(o)) return Value.false;
            }
            return Value.true;
        }
    }.f;
}

fn isLt(o: std.math.Order) bool {
    return o == .lt;
}
fn isGt(o: std.math.Order) bool {
    return o == .gt;
}
fn isLe(o: std.math.Order) bool {
    return o != .gt;
}
fn isGe(o: std.math.Order) bool {
    return o != .lt;
}
fn isEq(o: std.math.Order) bool {
    return o == .eq;
}

fn pred(comptime test_fn: fn (Value) bool) fn (Args) Value {
    return struct {
        fn f(a: Args) Value {
            return Value.fromBool(test_fn(a[0]));
        }
    }.f;
}

var gensym_counter = std.atomic.Value(u64).init(0);

var random_lock: platform.Mutex = .{};
var random_state: ?std.Random.DefaultPrng = null;

fn prng() *std.Random.DefaultPrng {
    if (random_state == null) random_state = std.Random.DefaultPrng.init(platform.monotonicNanos() ^ 0x5DEECE66D);
    return &random_state.?;
}

fn randomFloat() f64 {
    random_lock.lock();
    defer random_lock.unlock();
    return prng().random().float(f64);
}

fn randomBelow(n: i64) i64 {
    random_lock.lock();
    defer random_lock.unlock();
    return prng().random().intRangeLessThan(i64, 0, n);
}

fn parity(comptime odd: bool) fn (Args) Value {
    return struct {
        fn f(a: Args) Value {
            if (!num.isInteger(a[0])) rt.raise(.type_error, (if (odd) "odd?" else "even?") ++ " needs an integer, not {s}", .{typeName(a[0])});
            return Value.fromBool(num.isOdd(a[0]) == odd);
        }
    }.f;
}

fn isColl(v: Value) bool {
    return seqs.isSequential(v) or coll.isMap(v) or coll.isSet(v);
}

fn strFn(a: Args) Value {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.scratch);
    for (a) |x| {
        if (x == Value.nil) continue;
        // Strings and chars as they are; everything else as pr prints it.
        print.write(x, &out, !(string.isString(x) or x.isChar()));
    }
    return string.make(out.items);
}

fn nameString(comptime fname: []const u8, v: Value) []const u8 {
    if (string.isString(v)) return string.bytes(v);
    if (names.isKeyword(v) or names.isSymbol(v)) return names.nameOf(v);
    badArg(fname, v);
}

fn makeName(comptime keyword: bool) fn (Args) Value {
    return struct {
        fn f(a: Args) Value {
            const make = if (keyword) names.keyword else names.symbol;
            if (a.len == 1) {
                if (keyword and names.isKeyword(a[0])) return a[0];
                if (!keyword and names.isSymbol(a[0])) return a[0];
                const text = nameString(if (keyword) "keyword" else "symbol", a[0]);
                // "ns/name" splits at the first slash, unless the name is just "/".
                if (std.mem.indexOfScalar(u8, text, '/')) |slash| {
                    if (slash > 0 and slash + 1 < text.len) return make(text[0..slash], text[slash + 1 ..]);
                }
                return make(null, text);
            }
            const ns: ?[]const u8 = if (a[0] == Value.nil) null else nameString("keyword", a[0]);
            return make(ns, nameString("keyword", a[1]));
        }
    }.f;
}

/// reduce, stopping early at a reduced value (Phase 0's reduce-coll).
fn reduceFn(a: Args) Value {
    const f = a[0];
    if (a.len == 2) {
        const sq = seqs.seq(a[1]);
        if (sq == Value.nil) return func.call(f, 0, &.{});
        return reduceFrom(f, seqs.seqFirst(sq), seqs.seqRest(sq));
    }
    return reduceFrom(f, a[1], a[2]);
}

pub fn reduceFrom(f: Value, init: Value, c: Value) Value {
    if (c.isObjectOf(.eduction)) {
        const args = [_]Value{ f, init };
        return func.call(coll.get(c, 3), 2, &args);
    }
    var ctx: Reduce = .{ .f = f, .acc = init };
    seqs.each(c, &ctx, Reduce.step);
    return seqs.unreduced(ctx.acc);
}

const Reduce = struct {
    f: Value,
    acc: Value,

    fn step(c: *Reduce, x: Value) bool {
        const args = [_]Value{ c.acc, x };
        c.acc = func.call(c.f, 2, &args);
        return !seqs.isReduced(c.acc);
    }
};

fn applyFn(a: Args) Value {
    const last = a[a.len - 1];
    const fixed = a[1 .. a.len - 1];
    var buf: [256]Value = undefined;
    const n = if (last == Value.nil) 0 else count(last);
    if (fixed.len + n <= buf.len) {
        @memcpy(buf[0..fixed.len], fixed);
        var ctx: Collect = .{ .buf = buf[fixed.len..] };
        each(last, &ctx, Collect.add);
        return func.call(a[0], @intCast(fixed.len + n), &buf);
    }
    // More arguments than fit on the stack: a tuple, which this frame's reference keeps
    // pinned (the stack is scanned conservatively) while the function runs.
    const tuple = coll.tupleN(fixed.len + n, Value.nil);
    const slots = coll.slots(tuple);
    @memcpy(slots[0..fixed.len], fixed);
    var ctx: Collect = .{ .buf = slots[fixed.len..] };
    each(last, &ctx, Collect.add);
    const result = func.call(a[0], @intCast(fixed.len + n), slots.ptr);
    std.mem.doNotOptimizeAway(tuple);
    return result;
}

fn vecFn(a: Args) Value {
    if (coll.isVector(a[0])) return a[0];
    var t = coll.vectorTransient(coll.empty_vector);
    var ctx: VecEach = .{ .t = t };
    each(a[0], &ctx, VecEach.add);
    t = ctx.t;
    return coll.tvectorPersistent(t);
}

const VecEach = struct {
    t: Value,
    fn add(c: *VecEach, x: Value) void {
        c.t = coll.tvectorConj(c.t, x);
    }
};

fn keysOrVals(comptime keys: bool) fn (Args) Value {
    return struct {
        fn f(a: Args) Value {
            const m = a[0];
            if (m == Value.nil) return Value.nil;
            if (keys and m.isObjectOf(.instance)) return objs.keys(m);
            if (keys and m.isObjectOf(.@"struct")) return structs.keys(m);
            if (!coll.isMap(m)) badArg(if (keys) "keys" else "vals", m);
            const n = coll.mapCount(m);
            if (n == 0) return Value.nil;
            var t = coll.vectorTransient(coll.empty_vector);
            var ctx: KV = .{ .t = t };
            coll.mapEach(m, &ctx, KV.add);
            t = ctx.t;
            return listFrom(coll.tvectorPersistent(t));
        }
        const KV = struct {
            t: Value,
            fn add(c: *KV, k: Value, v: Value) bool {
                c.t = coll.tvectorConj(c.t, if (keys) k else v);
                return true;
            }
        };
    }.f;
}

fn comparatorArg(f: Value, comptime what: []const u8) Value {
    if (!f.isObjectOf(.function)) rt.raise(.type_error, what ++ " needs a comparator function, not {s}", .{typeName(f)});
    return f;
}

fn sortedMapOf(comparator: Value, kvs: Args, comptime what: []const u8) Value {
    if (kvs.len % 2 != 0) rt.raise(.@"error", what ++ " needs keys and values in pairs", .{});
    var m = sorted.makeMap(comparator);
    var i: usize = 0;
    while (i < kvs.len) : (i += 2) m = sorted.assoc(m, kvs[i], kvs[i + 1]);
    return m;
}

fn sortedSetOf(comparator: Value, xs: Args) Value {
    var s = sorted.makeSet(comparator);
    for (xs) |x| s = sorted.setConj(s, x);
    return s;
}

var volatile_counter = std.atomic.Value(u32).init(0);

fn volatileCount() u32 {
    return volatile_counter.fetchAdd(1, .monotonic);
}

/// swap! and swap-vals!: [old new].
fn swapVals(a: Args, comptime name: []const u8) Value {
    const at = a[0];
    if (!at.isObjectOf(.atom)) badArg(name, at);
    var buf: [16]Value = undefined;
    if (a.len - 1 > buf.len) rt.raise(.unsupported_operation_error, name ++ " with that many arguments is not supported natively yet", .{});
    while (true) {
        const old = coll.atomGet(at);
        buf[0] = old;
        @memcpy(buf[1 .. a.len - 1], a[2..]);
        const new = func.call(a[1], @intCast(a.len - 1), &buf);
        watch.validate(at, new);
        if (coll.atomCompareAndSet(at, old, new)) {
            watch.notify(at, old, new);
            return coll.vectorOf(&.{ old, new });
        }
    }
}

fn resetVals(at: Value, new: Value) Value {
    watch.validate(at, new);
    while (true) {
        const old = coll.atomGet(at);
        if (coll.atomCompareAndSet(at, old, new)) {
            watch.notify(at, old, new);
            return coll.vectorOf(&.{ old, new });
        }
    }
}

/// The validator of (atom x opts...) or (ref x opts...), or null: the options are
/// :validator f (and :meta, which step 6 of M2.11 gives a meaning).
pub fn referenceOptions(opts: Args, comptime what: []const u8) ?Value {
    if (opts.len % 2 != 0) rt.raise(.@"error", what ++ " takes options in pairs: :validator f", .{});
    var validator: ?Value = null;
    var i: usize = 0;
    while (i < opts.len) : (i += 2) {
        if (opts[i] == names.keyword(null, "validator")) {
            if (opts[i + 1] != Value.nil) validator = opts[i + 1];
        } else {
            var out: std.ArrayList(u8) = .empty;
            print.write(opts[i], &out, true);
            rt.raise(.@"error", what ++ " has no option {s} (it takes :validator)", .{out.items});
        }
    }
    return validator;
}

/// An error unless the validator f accepts x.
pub fn validatorCheck(f: Value, x: Value) void {
    if (!f.isObjectOf(.function)) rt.raise(.type_error, "a validator must be a function", .{});
    const ok = func.call(f, 1, &.{x});
    if (ok == Value.nil or ok == Value.false) rt.raise(.@"error", "the validator rejects the initial value", .{});
}

fn constantlyCode(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    _ = argv;
    return self.toObject().valueSlots()[0];
}

fn transientFn(a: Args) Value {
    const c = a[0];
    if (coll.isVector(c)) return coll.vectorTransient(c);
    if (coll.isMap(c)) return coll.mapTransient(c);
    if (coll.isSet(c)) return coll.setTransient(c);
    badArg("transient", c);
}

fn persistentFn(a: Args) Value {
    const t = a[0];
    if (t.isObjectOf(.transient_vector)) return coll.tvectorPersistent(t);
    if (t.isObjectOf(.transient_map)) return coll.tmapPersistent(t);
    if (t.isObjectOf(.transient_set)) return coll.tsetPersistent(t);
    badArg("persistent!", t);
}

fn modFn(a: Args) Value {
    return intDivision("mod", a[0], a[1], .floor);
}

fn remFn(a: Args) Value {
    return intDivision("rem", a[0], a[1], .trunc);
}

fn quotFn(a: Args) Value {
    if (num.isInteger(a[0]) and num.isInteger(a[1])) {
        if (a[1] == Value.fromFixnum(0)) rt.raise(.arithmetic_error, "division by zero", .{});
        return num.intDivide(.quot, a[0], a[1]);
    }
    const x = num.toF64(a[0]);
    const y = num.toF64(a[1]);
    if (y == 0) rt.raise(.arithmetic_error, "division by zero", .{});
    return num.boxF64(@trunc(x / y));
}

fn intDivision(comptime name: []const u8, x: Value, y: Value, comptime mode: enum { floor, trunc }) Value {
    if (num.isInteger(x) and num.isInteger(y)) {
        if (y == Value.fromFixnum(0)) rt.raise(.arithmetic_error, "division by zero", .{});
        return num.intDivide(if (mode == .floor) .mod else .rem, x, y);
    }
    if (!num.isNumber(x)) num.notANumber(name, x);
    if (!num.isNumber(y)) num.notANumber(name, y);
    const fx = num.toF64(x);
    const fy = num.toF64(y);
    if (fy == 0) rt.raise(.arithmetic_error, "division by zero", .{});
    return num.boxF64(if (mode == .floor) @mod(fx, fy) else @rem(fx, fy));
}

const base_table = [_]Entry{
    // Arithmetic and comparison (compiled code inlines most of these; these are for
    // passing them as values).
    e("+", 0, null, foldArith(.add, 0)),
    e("-", 1, null, foldArith(.sub, 0)),
    e("*", 0, null, foldArith(.mul, 1)),
    e("/", 2, 2, foldArith(.div, 1)),
    e("<", 1, null, chainCompare("<", isLt)),
    e(">", 1, null, chainCompare(">", isGt)),
    e("<=", 1, null, chainCompare("<=", isLe)),
    e(">=", 1, null, chainCompare(">=", isGe)),
    e("==", 1, null, chainCompare("==", isEq)),
    e("=", 1, null, struct {
        fn f(a: Args) Value {
            for (a[1..]) |x| if (!equal.equiv(a[0], x)) return Value.false;
            return Value.true;
        }
    }.f),
    e("not=", 1, null, struct {
        fn f(a: Args) Value {
            for (a[1..]) |x| if (!equal.equiv(a[0], x)) return Value.true;
            return Value.false;
        }
    }.f),
    e("inc", 1, 1, struct {
        fn f(a: Args) Value {
            return num.arith(.add, a[0], int(1));
        }
    }.f),
    e("dec", 1, 1, struct {
        fn f(a: Args) Value {
            return num.arith(.sub, a[0], int(1));
        }
    }.f),
    e("max", 1, null, struct {
        fn f(a: Args) Value {
            var best = a[0];
            for (a[1..]) |x| if ((num.compare("max", x, best) orelse .lt) == .gt) {
                best = x;
            };
            return best;
        }
    }.f),
    e("min", 1, null, struct {
        fn f(a: Args) Value {
            var best = a[0];
            for (a[1..]) |x| if ((num.compare("min", x, best) orelse .gt) == .lt) {
                best = x;
            };
            return best;
        }
    }.f),
    e("abs", 1, 1, struct {
        fn f(a: Args) Value {
            return if ((num.compare("abs", a[0], int(0)) orelse .gt) == .lt) num.arith(.mul, int(-1), a[0]) else a[0];
        }
    }.f),
    e("mod", 2, 2, modFn),
    e("rem", 2, 2, remFn),
    e("quot", 2, 2, quotFn),
    e("compare", 2, 2, struct {
        fn f(a: Args) Value {
            return int(equal.compare(a[0], a[1]));
        }
    }.f),
    e("zero?", 1, 1, struct {
        fn f(a: Args) Value {
            return Value.fromBool((num.compare("zero?", a[0], int(0)) orelse .lt) == .eq);
        }
    }.f),
    e("pos?", 1, 1, struct {
        fn f(a: Args) Value {
            return Value.fromBool((num.compare("pos?", a[0], int(0)) orelse .lt) == .gt);
        }
    }.f),
    e("neg?", 1, 1, struct {
        fn f(a: Args) Value {
            return Value.fromBool((num.compare("neg?", a[0], int(0)) orelse .gt) == .lt);
        }
    }.f),
    e("not", 1, 1, struct {
        fn f(a: Args) Value {
            return Value.fromBool(!a[0].isTruthy());
        }
    }.f),
    e("identical?", 2, 2, struct {
        fn f(a: Args) Value {
            return Value.fromBool(a[0] == a[1]);
        }
    }.f),
    e("identity", 1, 1, struct {
        fn f(a: Args) Value {
            return a[0];
        }
    }.f),
    e("constantly", 1, 1, struct {
        fn f(a: Args) Value {
            const h = rt.alloc(.function, 3);
            h.payload()[0] = @intFromPtr(&constantlyCode);
            h.payload()[1] = @intFromPtr("fn");
            h.valueSlots()[0] = a[0];
            return Value.fromObject(h);
        }
    }.f),
    // Printing
    e("println", 0, null, printFn(false, true)),
    // (%set-print-length-fn! f): the printer calls f for *print-length* (M2.11).
    e("%set-print-length-fn!", 1, 1, struct {
        fn f(a: Args) Value {
            @import("print.zig").setPrintLengthFn(a[0]);
            return Value.nil;
        }
    }.f),
    // (%with-out-str f): what (f) prints, as a string (with-out-str, M2.11).
    e("%with-out-str", 1, 1, struct {
        fn f(a: Args) Value {
            return print.withOutStr(a[0]);
        }
    }.f),
    e("print", 0, null, printFn(false, false)),
    e("prn", 0, null, printFn(true, true)),
    e("pr", 0, null, printFn(true, false)),
    // Constructors
    e("list", 0, null, struct {
        fn f(a: Args) Value {
            return coll.listOf(a);
        }
    }.f),
    e("vector", 0, null, struct {
        fn f(a: Args) Value {
            return coll.vectorOf(a);
        }
    }.f),
    e("hash-map", 0, null, struct {
        fn f(a: Args) Value {
            if (a.len % 2 != 0) rt.raise(.@"error", "hash-map needs keys and values in pairs", .{});
            return coll.mapOf(a);
        }
    }.f),
    e("%map-literal", 0, null, struct {
        fn f(a: Args) Value {
            const m = coll.mapOf(a);
            // As Phase 0: equal keys computed at run time are an error.
            if (coll.mapCount(m) * 2 != a.len) {
                var i: usize = 2;
                while (i < a.len) : (i += 2) {
                    var j: usize = 0;
                    while (j < i) : (j += 2) {
                        if (equal.equiv(a[i], a[j])) rt.raise(.unsupported_operation_error, "duplicate key {s} in a map literal", .{typeName(a[i])});
                    }
                }
            }
            return m;
        }
    }.f),
    e("hash-set", 0, null, struct {
        fn f(a: Args) Value {
            return coll.setOf(a);
        }
    }.f),
    e("%set-literal", 0, null, struct {
        fn f(a: Args) Value {
            const set = coll.setOf(a);
            if (coll.setCount(set) != a.len) {
                for (a, 0..) |x, i| {
                    for (a[i + 1 ..]) |y| {
                        if (equal.equiv(x, y)) rt.raise(.unsupported_operation_error, "duplicate element {s} in a set literal", .{typeName(x)});
                    }
                }
            }
            return set;
        }
    }.f),
    e("vec", 1, 1, vecFn),
    // Collection operations
    e("count", 1, 1, struct {
        fn f(a: Args) Value {
            return int(@intCast(count(a[0])));
        }
    }.f),
    e("conj", 0, null, struct {
        fn f(a: Args) Value {
            if (a.len == 0) return coll.empty_vector;
            var c = a[0];
            for (a[1..]) |x| c = conj1(c, x);
            return c;
        }
    }.f),
    e("assoc", 3, null, struct {
        fn f(a: Args) Value {
            if ((a.len - 1) % 2 != 0) rt.raise(.@"error", "assoc needs keys and values in pairs", .{});
            var c = a[0];
            var i: usize = 1;
            while (i < a.len) : (i += 2) c = assoc1(c, a[i], a[i + 1]);
            return c;
        }
    }.f),
    e("dissoc", 1, null, struct {
        fn f(a: Args) Value {
            var c = a[0];
            if (c == Value.nil) return c;
            if (!coll.isMap(c)) badArg("dissoc", c);
            for (a[1..]) |k| c = coll.mapDissoc(c, k);
            return c;
        }
    }.f),
    e("disj", 1, null, struct {
        fn f(a: Args) Value {
            var c = a[0];
            if (c == Value.nil) return c;
            if (!coll.isSet(c)) badArg("disj", c);
            for (a[1..]) |x| c = coll.setDisj(c, x);
            return c;
        }
    }.f),
    e("get", 2, 3, struct {
        fn f(a: Args) Value {
            return get(a[0], a[1], if (a.len == 3) a[2] else Value.nil);
        }
    }.f),
    e("nth", 2, 3, struct {
        fn f(a: Args) Value {
            return nth(a[0], a[1], if (a.len == 3) a[2] else null);
        }
    }.f),
    e("contains?", 2, 2, struct {
        fn f(a: Args) Value {
            const c = a[0];
            const k = a[1];
            if (c == Value.nil) return Value.false;
            if (coll.isMap(c)) return Value.fromBool(coll.mapGet(c, k) != null);
            if (coll.isSet(c)) return Value.fromBool(coll.setContains(c, k));
            if (coll.isVector(c)) return Value.fromBool(k.isFixnum() and k.toFixnum() >= 0 and k.toFixnum() < coll.vectorCount(c));
            badArg("contains?", c);
        }
    }.f),
    e("empty?", 1, 1, struct {
        fn f(a: Args) Value {
            return Value.fromBool(seqs.seq(a[0]) == Value.nil);
        }
    }.f),
    e("first", 1, 1, struct {
        fn f(a: Args) Value {
            return first(a[0]);
        }
    }.f),
    e("rest", 1, 1, struct {
        fn f(a: Args) Value {
            return rest(a[0]);
        }
    }.f),
    e("next", 1, 1, struct {
        fn f(a: Args) Value {
            return seqs.next(a[0]);
        }
    }.f),
    e("cons", 2, 2, struct {
        fn f(a: Args) Value {
            const c = a[1];
            if (c == Value.nil or coll.isList(c)) return coll.cons(a[0], c);
            return seqs.cons(a[0], c);
        }
    }.f),
    // Seqs (M1.8, D-052)
    e("seq", 1, 1, struct {
        fn f(a: Args) Value {
            return seqs.seq(a[0]);
        }
    }.f),
    e("%lazy-seq", 1, 1, struct {
        fn f(a: Args) Value {
            return seqs.lazySeq(a[0]);
        }
    }.f),
    e("realized?", 1, 1, struct {
        fn f(a: Args) Value {
            if (tasks.isPromiseLike(a[0])) return Value.fromBool(tasks.promiseRealized(a[0]));
            return Value.fromBool(seqs.isRealized(a[0]));
        }
    }.f),
    e("sequential?", 1, 1, pred(seqs.isSequential)),
    e("reduced", 1, 1, struct {
        fn f(a: Args) Value {
            return seqs.reduced(a[0]);
        }
    }.f),
    e("reduced?", 1, 1, pred(seqs.isReduced)),
    e("unreduced", 1, 1, struct {
        fn f(a: Args) Value {
            return seqs.unreduced(a[0]);
        }
    }.f),
    e("ensure-reduced", 1, 1, struct {
        fn f(a: Args) Value {
            return if (seqs.isReduced(a[0])) a[0] else seqs.reduced(a[0]);
        }
    }.f),
    e("%eduction", 4, 4, struct {
        fn f(a: Args) Value {
            return seqs.eduction(a[0], a[1], a[2], a[3]);
        }
    }.f),
    e("peek", 1, 1, struct {
        fn f(a: Args) Value {
            const c = a[0];
            if (c == Value.nil) return Value.nil;
            if (coll.isVector(c)) return if (coll.vectorCount(c) == 0) Value.nil else coll.vectorNth(c, coll.vectorCount(c) - 1).?;
            if (coll.isList(c)) return first(c);
            badArg("peek", c);
        }
    }.f),
    e("pop", 1, 1, struct {
        fn f(a: Args) Value {
            const c = a[0];
            if (coll.isVector(c)) return coll.vectorPop(c);
            if (c.isObjectOf(.list)) return coll.get(c, 1);
            if (c == Value.nil) return Value.nil;
            if (c.isObjectOf(.empty_list)) rt.raise(.@"error", "cannot pop an empty list", .{});
            badArg("pop", c);
        }
    }.f),
    e("keys", 1, 1, keysOrVals(true)),
    e("vals", 1, 1, keysOrVals(false)),
    e("reduce", 2, 3, reduceFn),
    e("apply", 2, null, applyFn),
    // Strings and names
    e("str", 0, null, strFn),
    // Step 3 of M1.8 (D-053): conversions, random numbers, names and predicates
    e("f64", 1, 1, struct {
        fn f(a: Args) Value {
            if (!num.isNumber(a[0])) rt.raise(.type_error, "f64 needs a number, not {s}", .{typeName(a[0])});
            return if (a[0].isObjectOf(.f64)) a[0] else num.boxF64(num.toF64(a[0]));
        }
    }.f),
    e("f32", 1, 1, struct {
        fn f(a: Args) Value {
            if (!num.isNumber(a[0])) rt.raise(.type_error, "f32 needs a number, not {s}", .{typeName(a[0])});
            return if (a[0].isF32()) a[0] else Value.fromF32(@floatCast(num.toF64(a[0])));
        }
    }.f),
    e("sqrt", 1, 1, struct {
        fn f(a: Args) Value {
            const x = a[0];
            if (!num.isNumber(x)) rt.raise(.type_error, "sqrt needs a number, not {s}", .{typeName(x)});
            const d = num.toF64(x);
            // As Phase 0: a negative number gives NaN, not a complex number.
            if (d < 0) return num.boxF64(std.math.nan(f64));
            if (x.isF32()) return Value.fromF32(@sqrt(x.toF32()));
            return num.boxF64(@sqrt(d));
        }
    }.f),
    e("rand", 0, 1, struct {
        fn f(a: Args) Value {
            var limit: f64 = 1.0;
            if (a.len == 1) {
                if (!num.isNumber(a[0]) or !(num.toF64(a[0]) > 0))
                    rt.raise(.@"error", "rand needs a positive number, not {s}", .{typeName(a[0])});
                limit = num.toF64(a[0]);
            }
            return num.boxF64(randomFloat() * limit);
        }
    }.f),
    e("rand-int", 1, 1, struct {
        fn f(a: Args) Value {
            const n = a[0];
            if (!num.isInteger(n) or !(num.toF64(n) > 0))
                rt.raise(.@"error", "rand-int needs a positive integer, not {s}", .{typeName(n)});
            if (!n.isFixnum()) rt.raise(.unsupported_operation_error, "rand-int of a bignum is not supported natively yet", .{});
            return Value.fromFixnum(randomBelow(n.toFixnum()));
        }
    }.f),
    e("gensym", 0, 1, struct {
        fn f(a: Args) Value {
            const prefix = if (a.len == 0) "G__" else nameString("gensym", a[0]);
            const n = gensym_counter.fetchAdd(1, .monotonic) + 1;
            var buf: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, n }) catch
                rt.raise(.@"error", "gensym prefix is too long", .{});
            return names.symbol(null, text);
        }
    }.f),
    // Bit operations on fixnums (M2.11, D-093); a result outside the fixnum range is a
    // bignum, as integer arithmetic gives one.
    e("bit-and", 2, null, bitFold(.@"and")),
    e("bit-or", 2, null, bitFold(.@"or")),
    e("bit-xor", 2, null, bitFold(.xor)),
    e("bit-and-not", 2, null, bitFold(.and_not)),
    e("bit-not", 1, 1, struct {
        fn f(a: Args) Value {
            return Value.fromFixnum(~bitArg(a[0], "bit-not"));
        }
    }.f),
    e("bit-shift-left", 2, 2, struct {
        fn f(a: Args) Value {
            const x = bitArg(a[0], "bit-shift-left");
            const n = shiftArg(a[1], "bit-shift-left");
            return num.fromI128(@as(i128, x) << @intCast(n));
        }
    }.f),
    e("bit-shift-right", 2, 2, struct {
        fn f(a: Args) Value {
            const x = bitArg(a[0], "bit-shift-right");
            return Value.fromFixnum(x >> @intCast(@min(shiftArg(a[1], "bit-shift-right"), 63)));
        }
    }.f),
    e("unsigned-bit-shift-right", 2, 2, struct {
        fn f(a: Args) Value {
            const x: u64 = @bitCast(bitArg(a[0], "unsigned-bit-shift-right"));
            const n = shiftArg(a[1], "unsigned-bit-shift-right");
            return num.fromI128(if (n >= 64) 0 else @as(i128, x >> @intCast(n)));
        }
    }.f),
    e("bit-test", 2, 2, struct {
        fn f(a: Args) Value {
            const x = bitArg(a[0], "bit-test");
            return Value.fromBool((x >> @intCast(@min(shiftArg(a[1], "bit-test"), 63))) & 1 == 1);
        }
    }.f),
    e("bit-set", 2, 2, bitAt(.set)),
    e("bit-clear", 2, 2, bitAt(.clear)),
    e("bit-flip", 2, 2, bitAt(.flip)),
    e("double?", 1, 1, struct {
        fn f(a: Args) Value {
            return Value.fromBool(a[0].isObjectOf(.f64));
        }
    }.f),
    // (parse-double s): the f64 that s writes (as Clojure's: digits, a point, an exponent,
    // Infinity or NaN), or nil.
    e("parse-double", 1, 1, struct {
        fn f(a: Args) Value {
            if (!string.isString(a[0])) rt.raise(.@"error", "parse-double needs a string, not {s}", .{typeName(a[0])});
            const text = string.bytes(a[0]);
            const body = if (text.len > 0 and (text[0] == '+' or text[0] == '-')) text[1..] else text;
            if (std.mem.eql(u8, body, "Infinity") or std.mem.eql(u8, body, "NaN")) {
                const v: f64 = if (body[0] == 'N') std.math.nan(f64) else std.math.inf(f64);
                return num.boxF64(if (text[0] == '-') -v else v);
            }
            for (body) |ch| switch (ch) {
                '0'...'9', '.', 'e', 'E', '+', '-' => {},
                else => return Value.nil,
            };
            return num.boxF64(std.fmt.parseFloat(f64, text) catch return Value.nil);
        }
    }.f),
    // (%format-number x kind precision): x as format's %f (kind 0) or %e (kind 1) writes it,
    // with precision digits after the point (M2.11, D-093).
    e("%format-number", 3, 3, struct {
        fn f(a: Args) Value {
            if (!num.isNumber(a[0]) or !a[1].isFixnum() or !a[2].isFixnum())
                rt.raise(.@"error", "%format-number needs a number, a kind and a precision", .{});
            const x = num.toF64(a[0]);
            const p: usize = @intCast(@min(@max(a[2].toFixnum(), 0), 30));
            var buf: [400]u8 = undefined;
            const text = if (a[1].toFixnum() == 1)
                std.fmt.bufPrint(&buf, "{e:.[1]}", .{ x, p }) catch "?"
            else
                std.fmt.bufPrint(&buf, "{d:.[1]}", .{ x, p }) catch "?";
            return string.make(text);
        }
    }.f),
    e("parse-long", 1, 1, struct {
        fn f(a: Args) Value {
            if (!string.isString(a[0])) rt.raise(.@"error", "parse-long needs a string, not {s}", .{typeName(a[0])});
            // As Clojure's: an optional sign and decimal digits, else nil.
            const text = string.bytes(a[0]);
            const start: usize = if (text.len > 0 and (text[0] == '+' or text[0] == '-')) 1 else 0;
            if (text.len <= start) return Value.nil;
            for (text[start..]) |ch| if (ch < '0' or ch > '9') return Value.nil;
            return num.parseInteger(text);
        }
    }.f),
    e("boolean", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return v != Value.nil and v != Value.false;
        }
    }.t)),
    e("associative?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return coll.isMap(v) or coll.isVector(v);
        }
    }.t)),
    e("counted?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            if (string.isString(v)) return true;
            if (!v.isObject()) return false;
            return switch (v.toObject().type_id) {
                .list, .empty_list, .vector, .array_map, .hash_map, .hash_set, .vseq,
                .sorted_map, .sorted_set,
                .transient_vector, .transient_map, .transient_set => true,
                else => false,
            };
        }
    }.t)),
    e("ifn?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return v.isObjectOf(.function) or names.isKeyword(v) or coll.isMap(v) or
                coll.isSet(v) or coll.isVector(v);
        }
    }.t)),
    // The object system (M1.8 step 4, D-054)
    e("make", 1, null, struct {
        fn f(a: Args) Value {
            return objs.make(a[0], a[1..]);
        }
    }.f),
    e("with", 1, null, struct {
        fn f(a: Args) Value {
            return objs.with(a[0], a[1..]);
        }
    }.f),
    e("slot", 2, 3, struct {
        fn f(a: Args) Value {
            if (!a[0].isObjectOf(.instance)) rt.raise(.@"error", "slot needs an instance, not {s}", .{typeName(a[0])});
            if (objs.get(a[0], a[1])) |v| return v;
            if (a.len == 3) return a[2];
            rt.raise(.@"error", "{s} has no slot {s}", .{ objs.className(objs.classOf(a[0])), typeName(a[1]) });
        }
    }.f),
    e("set-slot!", 3, 3, struct {
        fn f(a: Args) Value {
            return objs.setSlotValue(a[0], a[1], a[2]);
        }
    }.f),
    e("%set-slot!", 3, 3, struct {
        fn f(a: Args) Value {
            return objs.setBang(a[0], a[1], a[2]);
        }
    }.f),
    e("update-slot!", 3, null, struct {
        fn f(a: Args) Value {
            return objs.updateSlot(a[0], a[1], a[2], a[3..]);
        }
    }.f),
    e("cell", 2, 2, struct {
        fn f(a: Args) Value {
            return objs.cellOf(a[0], a[1]);
        }
    }.f),
    e("instance?", 2, 2, struct {
        fn f(a: Args) Value {
            return Value.fromBool(objs.isInstance(objs.findClass(a[0]), a[1]));
        }
    }.f),
    e("class-of", 1, 1, struct {
        fn f(a: Args) Value {
            return objs.classOf(a[0]);
        }
    }.f),
    e("class-name", 1, 1, struct {
        fn f(a: Args) Value {
            return objs.classNameSymbol(objs.findClass(a[0]));
        }
    }.f),
    e("class-slots", 1, 1, struct {
        fn f(a: Args) Value {
            return objs.classSlots(objs.findClass(a[0]));
        }
    }.f),
    e("class-precedence-list", 1, 1, struct {
        fn f(a: Args) Value {
            return objs.precedenceList(objs.findClass(a[0]));
        }
    }.f),
    e("generic-methods", 1, 1, struct {
        fn f(a: Args) Value {
            return objs.genericMethods(a[0]);
        }
    }.f),
    e("%define-class", 3, 3, struct {
        fn f(a: Args) Value {
            return objs.defineClass(a[0], a[1], a[2]);
        }
    }.f),
    e("%class", 2, 2, struct {
        fn f(a: Args) Value {
            return objs.findClass(a[0]);
        }
    }.f),
    e("%eql-specializer", 1, 1, struct {
        fn f(a: Args) Value {
            return objs.eqlSpecializer(a[0]);
        }
    }.f),
    e("%define-generic", 3, 3, struct {
        fn f(a: Args) Value {
            return objs.defineGeneric(a[0], nameString("%define-generic", a[1]), a[2]);
        }
    }.f),
    // Structs and typed arrays (M1.8 step 5, D-055)
    e("%make-array", 2, 2, struct {
        fn f(a: Args) Value {
            return structs.makeArray(a[0], a[1]);
        }
    }.f),
    e("aget", 2, 2, struct {
        fn f(a: Args) Value {
            return structs.aget(a[0], a[1]);
        }
    }.f),
    e("aset!", 3, 3, struct {
        fn f(a: Args) Value {
            return structs.aset(a[0], a[1], a[2]);
        }
    }.f),
    e("array?", 1, 1, pred(structs.isArray)),
    e("struct?", 1, 1, pred(structs.isStruct)),
    e("view", 2, 3, struct {
        fn f(a: Args) Value {
            return structs.view(a[0], a[1], if (a.len == 3) a[2] else null);
        }
    }.f),
    e("as-bytes", 1, 1, struct {
        fn f(a: Args) Value {
            return structs.asBytes(a[0]);
        }
    }.f),
    e("update!", 3, null, struct {
        fn f(a: Args) Value {
            return structs.update(a[0], a[1], a[2..]);
        }
    }.f),
    e("odd?", 1, 1, parity(true)),
    e("even?", 1, 1, parity(false)),
    e("pr-str", 0, null, struct {
        fn f(a: Args) Value {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(rt.scratch);
            for (a, 0..) |x, i| {
                if (i > 0) print.put(&out, " ");
                print.write(x, &out, true);
            }
            return string.make(out.items);
        }
    }.f),
    e("subs", 2, 3, struct {
        fn f(a: Args) Value {
            const s = a[0];
            if (!string.isString(s)) badArg("subs", s);
            const n = string.count(s);
            const start = index("subs", a[1]);
            const end = if (a.len == 3) index("subs", a[2]) else n;
            if (start > end or end > n) rt.raise(.index_error, "subs range {d} to {d} is outside a string of {d} characters", .{ start, end, n });
            return string.substring(s, start, end);
        }
    }.f),
    e("keyword", 1, 2, makeName(true)),
    e("symbol", 1, 2, makeName(false)),
    e("name", 1, 1, struct {
        fn f(a: Args) Value {
            if (string.isString(a[0])) return a[0];
            return string.make(nameString("name", a[0]));
        }
    }.f),
    e("namespace", 1, 1, struct {
        fn f(a: Args) Value {
            if (!(names.isKeyword(a[0]) or names.isSymbol(a[0]))) badArg("namespace", a[0]);
            const ns = names.nsOf(a[0]) orelse return Value.nil;
            return string.make(ns);
        }
    }.f),
    // Atoms
    // (atom x) or (atom x :validator f)
    e("atom", 1, null, struct {
        fn f(a: Args) Value {
            const at = coll.makeAtom(a[0]);
            if (referenceOptions(a[1..], "atom")) |v| {
                validatorCheck(v, a[0]);
                coll.set(at, 3, v);
            }
            return at;
        }
    }.f),
    e("deref", 1, 3, struct {
        fn f(a: Args) Value {
            // Atoms give their value; tasks (futures, spawned tasks) wait for theirs. With
            // a timeout in seconds, a task that is not done by then gives the timeout value.
            if (tasks.isTask(a[0])) return tasks.deref(a);
            if (tasks.isPromiseLike(a[0])) return tasks.derefPromise(a);
            if (a[0].isObjectOf(.ref)) return @import("stm.zig").deref(a[0]);
            if (a[0].isObjectOf(.@"volatile")) return coll.get(a[0], 0);
            if (!a[0].isObjectOf(.atom)) rt.raise(.type_error, "deref (@) needs an atom, a ref, a volatile, a promise, a delay or a task, not {s}", .{typeName(a[0])});
            return coll.atomGet(a[0]);
        }
    }.f),
    e("reset!", 2, 2, struct {
        fn f(a: Args) Value {
            if (!a[0].isObjectOf(.atom)) badArg("reset!", a[0]);
            if (!watch.watched(a[0])) return coll.atomReset(a[0], a[1]);
            return coll.vectorNth(resetVals(a[0], a[1]), 1).?;
        }
    }.f),
    // (reset-vals! a x): [old new].
    e("reset-vals!", 2, 2, struct {
        fn f(a: Args) Value {
            if (!a[0].isObjectOf(.atom)) badArg("reset-vals!", a[0]);
            return resetVals(a[0], a[1]);
        }
    }.f),
    e("swap!", 2, null, struct {
        fn f(a: Args) Value {
            return coll.vectorNth(swapVals(a, "swap!"), 1).?;
        }
    }.f),
    // (swap-vals! a f args...): [old new].
    e("swap-vals!", 2, null, struct {
        fn f(a: Args) Value {
            return swapVals(a, "swap-vals!");
        }
    }.f),
    // Sorted maps and sets (M2.11, D-093; sorted.zig)
    e("sorted-map", 0, null, struct {
        fn f(a: Args) Value {
            return sortedMapOf(Value.nil, a, "sorted-map");
        }
    }.f),
    e("sorted-map-by", 1, null, struct {
        fn f(a: Args) Value {
            return sortedMapOf(comparatorArg(a[0], "sorted-map-by"), a[1..], "sorted-map-by");
        }
    }.f),
    e("sorted-set", 0, null, struct {
        fn f(a: Args) Value {
            return sortedSetOf(Value.nil, a);
        }
    }.f),
    e("sorted-set-by", 1, null, struct {
        fn f(a: Args) Value {
            return sortedSetOf(comparatorArg(a[0], "sorted-set-by"), a[1..]);
        }
    }.f),
    e("sorted?", 1, 1, struct {
        fn f(a: Args) Value {
            return Value.fromBool(sorted.isSorted(a[0]));
        }
    }.f),
    // (%sorted-seq coll descending?) and (%sorted-seq-from coll key descending?): rseq,
    // subseq and rsubseq.
    e("%sorted-seq", 2, 2, struct {
        fn f(a: Args) Value {
            if (!sorted.isSorted(a[0])) badArg("rseq", a[0]);
            return sorted.seq(a[0], a[1] != Value.nil and a[1] != Value.false);
        }
    }.f),
    e("%sorted-seq-from", 3, 3, struct {
        fn f(a: Args) Value {
            if (!sorted.isSorted(a[0])) badArg("subseq", a[0]);
            return sorted.seqFrom(a[0], a[1], a[2] != Value.nil and a[2] != Value.false);
        }
    }.f),
    // (%sorted-compare coll a b): -1, 0 or 1, as coll's comparator orders a and b.
    e("%sorted-compare", 3, 3, struct {
        fn f(a: Args) Value {
            if (!sorted.isSorted(a[0])) badArg("subseq", a[0]);
            return Value.fromFixnum(sorted.compareWith(sorted.comparatorOf(a[0]), a[1], a[2]));
        }
    }.f),
    // (%sorted-empty coll): an empty sorted map or set with coll's comparator.
    e("%sorted-empty", 1, 1, struct {
        fn f(a: Args) Value {
            if (!sorted.isSorted(a[0])) badArg("empty", a[0]);
            return sorted.empty(a[0]);
        }
    }.f),
    // Volatiles (M2.11, D-093): a box with no synchronization, for one fiber.
    e("volatile!", 1, 1, struct {
        fn f(a: Args) Value {
            return coll.make(.@"volatile", &.{ a[0], Value.fromFixnum(@import("hash.zig").mix32(volatileCount() +% 1)) });
        }
    }.f),
    e("volatile?", 1, 1, struct {
        fn f(a: Args) Value {
            return Value.fromBool(a[0].isObjectOf(.@"volatile"));
        }
    }.f),
    e("vreset!", 2, 2, struct {
        fn f(a: Args) Value {
            if (!a[0].isObjectOf(.@"volatile")) badArg("vreset!", a[0]);
            coll.set(a[0], 0, a[1]);
            return a[1];
        }
    }.f),
    e("vswap!", 2, null, struct {
        fn f(a: Args) Value {
            if (!a[0].isObjectOf(.@"volatile")) badArg("vswap!", a[0]);
            var buf: [16]Value = undefined;
            if (a.len - 1 > buf.len) rt.raise(.unsupported_operation_error, "vswap! with that many arguments is not supported natively yet", .{});
            buf[0] = coll.get(a[0], 0);
            @memcpy(buf[1 .. a.len - 1], a[2..]);
            const new = func.call(a[1], @intCast(a.len - 1), &buf);
            coll.set(a[0], 0, new);
            return new;
        }
    }.f),
    e("compare-and-set!", 3, 3, struct {
        fn f(a: Args) Value {
            if (!a[0].isObjectOf(.atom)) badArg("compare-and-set!", a[0]);
            watch.validate(a[0], a[2]);
            if (!coll.atomCompareAndSet(a[0], a[1], a[2])) return Value.false;
            watch.notify(a[0], a[1], a[2]);
            return Value.true;
        }
    }.f),
    // Transients
    e("transient", 1, 1, transientFn),
    e("persistent!", 1, 1, persistentFn),
    e("conj!", 2, 2, struct {
        fn f(a: Args) Value {
            const t = a[0];
            if (t.isObjectOf(.transient_vector)) return coll.tvectorConj(t, a[1]);
            if (t.isObjectOf(.transient_set)) return coll.tsetConj(t, a[1]);
            if (t.isObjectOf(.transient_map)) {
                const x = a[1];
                if (!coll.isVector(x) or coll.vectorCount(x) != 2) rt.raise(.type_error, "conj! on a transient map needs a [key value] vector", .{});
                return coll.tmapAssoc(t, coll.vectorNth(x, 0).?, coll.vectorNth(x, 1).?);
            }
            badArg("conj!", t);
        }
    }.f),
    e("assoc!", 3, 3, struct {
        fn f(a: Args) Value {
            const t = a[0];
            if (t.isObjectOf(.transient_map)) return coll.tmapAssoc(t, a[1], a[2]);
            if (t.isObjectOf(.transient_vector)) return coll.tvectorAssoc(t, index("assoc!", a[1]), a[2]);
            badArg("assoc!", t);
        }
    }.f),
    e("dissoc!", 2, 2, struct {
        fn f(a: Args) Value {
            if (!a[0].isObjectOf(.transient_map)) badArg("dissoc!", a[0]);
            return coll.tmapDissoc(a[0], a[1]);
        }
    }.f),
    e("disj!", 2, 2, struct {
        fn f(a: Args) Value {
            if (!a[0].isObjectOf(.transient_set)) badArg("disj!", a[0]);
            return coll.tsetDisj(a[0], a[1]);
        }
    }.f),
    e("pop!", 1, 1, struct {
        fn f(a: Args) Value {
            if (!a[0].isObjectOf(.transient_vector)) badArg("pop!", a[0]);
            return coll.tvectorPop(a[0]);
        }
    }.f),
    // Predicates
    e("nil?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return v == Value.nil;
        }
    }.t)),
    e("some?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return v != Value.nil;
        }
    }.t)),
    e("true?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return v == Value.true;
        }
    }.t)),
    e("false?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return v == Value.false;
        }
    }.t)),
    e("vector?", 1, 1, pred(coll.isVector)),
    e("map?", 1, 1, pred(coll.isMap)),
    e("set?", 1, 1, pred(coll.isSet)),
    e("list?", 1, 1, pred(coll.isList)),
    e("seq?", 1, 1, pred(seqs.isSeq)),
    e("coll?", 1, 1, pred(isColl)),
    e("string?", 1, 1, pred(string.isString)),
    e("keyword?", 1, 1, pred(names.isKeyword)),
    e("symbol?", 1, 1, pred(names.isSymbol)),
    e("number?", 1, 1, pred(num.isNumber)),
    e("integer?", 1, 1, pred(num.isInteger)),
    e("float?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return num.kind(v) == .f32 or num.kind(v) == .f64;
        }
    }.t)),
    // int and char convert between numbers and characters, as in Clojure.
    e("int", 1, 1, struct {
        fn f(a: Args) Value {
            const x = a[0];
            if (x.isChar()) return Value.fromFixnum(x.toChar());
            switch (num.kind(x)) {
                .int => return x,
                .f32, .f64 => {
                    const d = num.toF64(x);
                    if (std.math.isNan(d) or @abs(d) >= 0x1p126)
                        rt.raise(.unsupported_operation_error, "int of {s} is not supported natively yet", .{typeName(x)});
                    return num.fromI128(@intFromFloat(@trunc(d)));
                },
                .other => rt.raise(.@"error", "int needs a number or a char, not {s}", .{typeName(x)}),
            }
        }
    }.f),
    e("char", 1, 1, struct {
        fn f(a: Args) Value {
            const x = a[0];
            if (x.isChar()) return x;
            if (x.isFixnum()) {
                const n = x.toFixnum();
                if (n >= 0 and n <= 0x10FFFF and !(n >= 0xD800 and n <= 0xDFFF))
                    return Value.fromChar(@intCast(n));
            }
            rt.raise(.@"error", "char needs a code point, not {s}", .{typeName(x)});
        }
    }.f),
    e("char?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return v.isChar();
        }
    }.t)),
    e("boolean?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return v == Value.true or v == Value.false;
        }
    }.t)),
    e("fn?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return v.isObjectOf(.function);
        }
    }.t)),
    e("atom?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return v.isObjectOf(.atom);
        }
    }.t)),
    e("%no-matching-case", 1, 1, struct {
        fn f(a: Args) Value {
            rt.raise(.@"error", "no case clause matches {s}", .{typeName(a[0])});
        }
    }.f),
    // Conditions and restarts (DESIGN §10, M1.5)
    e("error", 1, null, struct {
        fn f(a: Args) Value {
            cond.signalError(cond.toCondition(a[0], a[1..], .@"error"));
        }
    }.f),
    e("signal", 1, null, struct {
        fn f(a: Args) Value {
            cond.signal(cond.toCondition(a[0], a[1..], .condition));
            return Value.nil;
        }
    }.f),
    e("warn", 1, null, struct {
        fn f(a: Args) Value {
            cond.warn(cond.toCondition(a[0], a[1..], .warning));
            return Value.nil;
        }
    }.f),
    e("make-condition", 1, null, struct {
        fn f(a: Args) Value {
            return cond.makeCondition(a[0], a[1..]);
        }
    }.f),
    e("condition?", 1, 1, pred(cond.isCondition)),
    e("error?", 1, 1, pred(struct {
        fn t(v: Value) bool {
            return cond.isCondition(v) and cond.isA(v, cond.builtinType(.@"error"));
        }
    }.t)),
    e("condition-message", 1, 1, struct {
        fn f(a: Args) Value {
            if (!cond.isCondition(a[0])) badArg("condition-message", a[0]);
            return cond.messageOf(a[0]);
        }
    }.f),
    e("condition-type", 1, 1, struct {
        fn f(a: Args) Value {
            if (!cond.isCondition(a[0])) badArg("condition-type", a[0]);
            return cond.conditionType(a[0]);
        }
    }.f),
    e("condition-type-name", 1, 1, struct {
        fn f(a: Args) Value {
            return cond.typeNameSymbol(cond.findType(a[0], null));
        }
    }.f),
    e("invoke-restart", 1, null, struct {
        fn f(a: Args) Value {
            return cond.invokeRestart(a[0], a[1..]);
        }
    }.f),
    e("find-restart", 1, 2, struct {
        fn f(a: Args) Value {
            return cond.findRestart(a[0]);
        }
    }.f),
    e("compute-restarts", 0, 1, struct {
        fn f(_: Args) Value {
            return cond.computeRestarts();
        }
    }.f),
    e("restart-name", 1, 1, struct {
        fn f(a: Args) Value {
            return cond.restartName(a[0]);
        }
    }.f),
    e("restart-report", 1, 1, struct {
        fn f(a: Args) Value {
            return cond.restartReport(a[0]);
        }
    }.f),
    e("%condition-type", 1, 2, struct {
        fn f(a: Args) Value {
            const ns = if (a.len == 2 and string.isString(a[1])) string.bytes(a[1]) else null;
            return cond.findType(a[0], ns);
        }
    }.f),
    e("%define-condition", 4, 4, struct {
        fn f(a: Args) Value {
            return cond.defineType(a[0], a[1], a[2], a[3]);
        }
    }.f),
    e("%condition-slot", 2, 2, struct {
        fn f(a: Args) Value {
            return cond.slot(a[0], a[1]);
        }
    }.f),
};

/// The core table: the entries above, the concurrency functions (tasks.zig), skein.io's
/// primitives (io.zig), what the compiler written in Skein needs (compiler.zig),
/// skein.ffi's functions (ffi.zig, named skein.ffi/<name>), and skein.math's and
/// skein.time's (mathtime.zig, named skein.math/<name> and skein.time/<name>), and eval
/// and its relatives (evaluate.zig), and what the REPL and skein dev need (devio.zig).
const table = base_table ++ entriesOf(tasks.entries) ++ entriesOf(watch.entries) ++ entriesOf(io.entries) ++
    entriesOf(compiler.entries) ++ entriesOf(ffi.entries) ++ entriesOf(mathtime.entries) ++
    entriesOf(evaluate.entries) ++ entriesOf(devio.entries) ++
    entriesOf(@import("stm.zig").entries) ++ entriesOf(string.entries);

fn entriesOf(comptime from: anytype) [from.len]Entry {
    var t: [from.len]Entry = undefined;
    for (from, 0..) |x, i| t[i] = .{ .name = x.name, .min = x.min, .max = x.max, .impl = x.impl };
    return t;
}

/// The code pointer that runs table entry `i`, checking the argument count.
fn entryCode(comptime i: usize) func.Code {
    return struct {
        fn code(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
            const entry = table[i];
            if (argc < entry.min or (entry.max != null and argc > entry.max.?))
                compiler.raiseArity(self, argc, "wrong number of arguments ({d}) passed to skein.core/{s}", .{ argc, entry.name });
            return entry.impl(argv[0..argc]);
        }
    }.code;
}

const codes = blk: {
    var c: [table.len]func.Code = undefined;
    for (0..table.len) |i| c[i] = entryCode(i);
    break :blk c;
};

const display_names = blk: {
    var n: [table.len][:0]const u8 = undefined;
    for (table, 0..) |entry, i| n[i] = "skein.core/" ++ entry.name;
    break :blk n;
};

pub var objects: [table.len]Value = @splat(Value.nil);
var objects_lock: platform.Mutex = .{};

/// The function object for skein.core/`name`, or null if the runtime doesn't have it.
pub fn function(name: []const u8) ?Value {
    // equiv, hash-of, initialize and update-instance-for-redefined-class are generic.
    if (objs.coreGeneric(name)) |g| return g;
    inline for (table, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name)) {
            objects_lock.lock();
            defer objects_lock.unlock();
            if (objects[i] == Value.nil) {
                const h = gc.allocPermanent(.function, 2);
                h.payload()[0] = @intFromPtr(codes[i]);
                h.payload()[1] = @intFromPtr(display_names[i].ptr);
                objects[i] = Value.fromObject(h);
            }
            return objects[i];
        }
    }
    return null;
}

/// The names of every skein.core function the runtime has (for tests).
pub fn names_list() [table.len][]const u8 {
    var n: [table.len][]const u8 = undefined;
    for (table, 0..) |entry, i| n[i] = entry.name;
    return n;
}

test "every core function has an object and checks its arguments" {
    coll.ensureConstants();
    for (names_list()) |n| try std.testing.expect(function(n) != null);
    try std.testing.expect(function("no-such-function") == null);
    const args = [_]Value{ coll.vectorOf(&.{Value.fromFixnum(1)}), Value.fromFixnum(2) };
    const v = func.call(function("conj").?, 2, &args);
    try std.testing.expectEqual(@as(usize, 2), coll.vectorCount(v));
}

test "apply takes more arguments than fit on the stack" {
    coll.ensureConstants();
    var v = coll.vectorOf(&.{});
    for (0..1000) |i| v = coll.vectorConj(v, Value.fromFixnum(@intCast(i % 10)));
    const args = [_]Value{ function("str").?, v };
    const s = applyFn(&args);
    try std.testing.expectEqual(@as(usize, 1000), string.count(s));
    const plus = [_]Value{ function("+").?, Value.fromFixnum(1), v };
    try std.testing.expectEqual(@as(i64, 4501), applyFn(&plus).toFixnum());
}
