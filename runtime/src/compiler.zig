//! What the compiler written in Skein needs from the native runtime (M1.9 step 3, D-060):
//! symbol copies, identity tables, float bits and correctly rounded float construction,
//! details of arity errors, and the table of skein.core's functions and compiled macros
//! that skein.compiler.env (lib/skein/compiler/env.skn) builds its skein.core from.
//! Phase 0 has the same functions in host/src/runtime/compile-env.lisp and core.lisp.

const std = @import("std");
const rt = @import("rt.zig");
const gc = @import("gc.zig");
const coll = @import("coll.zig");
const cond = @import("cond.zig");
const core = @import("core.zig");
const func = @import("func.zig");
const hash = @import("hash.zig");
const names = @import("names.zig");
const num = @import("num.zig");
const objects = @import("objects.zig");
const print = @import("print.zig");
const Value = @import("value.zig").Value;

fn fx(n: usize) Value {
    return coll.fx(n);
}

fn ux(v: Value) usize {
    return coll.ux(v);
}

fn readable(v: Value) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    print.write(v, &buf, true);
    return buf.items;
}

// ---------------------------------------------------------------------------------------
// Symbol copies

/// A symbol = to `s` but not identical? to it, so the expander can track where it came
/// from (equal.zig compares symbols by name when they aren't identical).
fn copySymbol(s: Value) Value {
    if (!names.isSymbol(s)) rt.raise(.type_error, "%copy-symbol needs a symbol, not {s}", .{readable(s)});
    return coll.make(.symbol, coll.slots(s));
}

// ---------------------------------------------------------------------------------------
// Identity tables: maps keyed by identical?. Keys and values live in tuples; an
// open-addressing index of their positions is keyed by address, so it is rebuilt after
// any collection (objects may have moved). The expander makes one per macro call.

const i_keys = 0;
const i_vals = 1;
const i_count = 2;
const i_epoch = 3;
const i_index = 4;
const empty_slot = -1;

fn identityTable() Value {
    return coll.make(.identity_table, &.{ coll.tupleN(8, Value.nil), coll.tupleN(8, Value.nil), fx(0), Value.fromFixnum(-1), coll.tupleN(16, Value.fromFixnum(empty_slot)) });
}

fn checkTable(t: Value) void {
    if (!t.isObjectOf(.identity_table)) rt.raise(.type_error, "an identity table is needed, not {s}", .{readable(t)});
}

fn keyHash(k: Value) u32 {
    const bits: u64 = if (k.isObject()) @intFromPtr(k.toObject()) >> 3 else k.bits();
    return hash.mix32(@truncate(bits ^ (bits >> 32)));
}

/// Put position `i` of key `k` into the index (which has room).
fn indexInsert(index: Value, k: Value, i: usize) void {
    const slots = coll.slots(index);
    const mask = slots.len - 1;
    var p: usize = keyHash(k) & mask;
    while (slots[p].toFixnum() != empty_slot) p = (p + 1) & mask;
    slots[p] = fx(i);
}

/// Make the index match the keys' current addresses.
fn ensureIndex(t: Value) void {
    const now: i64 = @intCast(gc.epoch.load(.acquire));
    if (coll.get(t, i_epoch).toFixnum() == now) return;
    const index = coll.get(t, i_index);
    for (coll.slots(index)) |*s| s.* = Value.fromFixnum(empty_slot);
    const keys = coll.slots(coll.get(t, i_keys));
    for (0..ux(coll.get(t, i_count))) |i| indexInsert(index, keys[i], i);
    coll.slots(t)[i_epoch] = Value.fromFixnum(now);
}

fn find(t: Value, k: Value) ?usize {
    ensureIndex(t);
    const slots = coll.slots(coll.get(t, i_index));
    const keys = coll.slots(coll.get(t, i_keys));
    const mask = slots.len - 1;
    var p: usize = keyHash(k) & mask;
    while (true) : (p = (p + 1) & mask) {
        const i = slots[p].toFixnum();
        if (i == empty_slot) return null;
        if (keys[@intCast(i)] == k) return @intCast(i);
    }
}

fn identityGet(t: Value, k: Value) Value {
    checkTable(t);
    const i = find(t, k) orelse return Value.nil;
    return coll.slots(coll.get(t, i_vals))[i];
}

fn grown(old: Value, n: usize) Value {
    const new = coll.tupleN(n, Value.nil);
    const from = coll.slots(old);
    for (from, 0..) |x, i| coll.set(new, i, x);
    return new;
}

fn identityPut(t: Value, k: Value, v: Value) Value {
    checkTable(t);
    if (find(t, k)) |i| {
        coll.set(coll.get(t, i_vals), i, v);
        return v;
    }
    const n = ux(coll.get(t, i_count));
    // Allocate first: a collection meanwhile only makes the index stale.
    const cap = coll.slots(coll.get(t, i_keys)).len;
    if (n == cap) {
        coll.set(t, i_keys, grown(coll.get(t, i_keys), cap * 2));
        coll.set(t, i_vals, grown(coll.get(t, i_vals), cap * 2));
    }
    if ((n + 1) * 2 > coll.slots(coll.get(t, i_index)).len) {
        coll.set(t, i_index, coll.tupleN(coll.slots(coll.get(t, i_index)).len * 2, Value.fromFixnum(empty_slot)));
        coll.slots(t)[i_epoch] = Value.fromFixnum(-1);
    }
    coll.set(coll.get(t, i_keys), n, k);
    coll.set(coll.get(t, i_vals), n, v);
    coll.slots(t)[i_count] = fx(n + 1);
    const stale = coll.get(t, i_epoch).toFixnum() != @as(i64, @intCast(gc.epoch.load(.acquire)));
    if (stale) ensureIndex(t) else indexInsert(coll.get(t, i_index), k, n);
    return v;
}

// ---------------------------------------------------------------------------------------
// Floats

fn f64Bits(x: Value) Value {
    if (num.kind(x) != .f64) rt.raise(.type_error, "%f64-bits needs an f64, not {s}", .{readable(x)});
    const b: u64 = @bitCast(num.toF64(x));
    return num.fromI128(b);
}

fn f32Bits(x: Value) Value {
    if (!x.isF32()) rt.raise(.type_error, "%f32-bits needs an f32, not {s}", .{readable(x)});
    const b: u32 = @bitCast(x.toF32());
    return fx(b);
}

/// The float nearest to mantissa * 10^exponent, negated if `negative`; `type` is :f64 or
/// :f32. Nil when the value is too large for the type. Zig's parseFloat rounds correctly.
fn decimalToFloat(negative: Value, mantissa: Value, exponent: Value, type_kw: Value) Value {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(rt.scratch);
    if (negative.isTruthy()) print.put(&buf, "-");
    print.write(mantissa, &buf, false);
    print.put(&buf, "e");
    print.write(exponent, &buf, false);
    const f32_wanted = names.isKeyword(type_kw) and std.mem.eql(u8, names.nameOf(type_kw), "f32");
    if (f32_wanted) {
        const x = std.fmt.parseFloat(f32, buf.items) catch return Value.nil;
        return if (std.math.isInf(x)) Value.nil else Value.fromF32(x);
    }
    const x = std.fmt.parseFloat(f64, buf.items) catch return Value.nil;
    return if (std.math.isInf(x)) Value.nil else num.boxF64(x);
}

// ---------------------------------------------------------------------------------------
// Errors

/// Signal an arity error about `f`, called with `argc` arguments: its slots
/// function-name and argument-count let the expander report macro calls (%arity-error-
/// details), as Phase 0's arity-error does.
pub fn raiseArity(f: Value, argc: u32, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    const c = cond.makeBuiltin(.arity_error, text);
    const slots = coll.mapOf(&.{
        names.symbol(null, "function-name"),  if (f.isObjectOf(.function)) @import("string.zig").make(func.name(f)) else Value.nil,
        names.symbol(null, "argument-count"), fx(argc),
    });
    coll.set(c, 2, slots);
    cond.signalError(c);
}

fn arityErrorDetails(c: Value) Value {
    if (!cond.isCondition(c) or !cond.isA(c, cond.builtinType(.arity_error))) return Value.nil;
    const name = cond.slotValue(c, "function-name") orelse return Value.nil;
    const count = cond.slotValue(c, "argument-count") orelse return Value.nil;
    return coll.vectorOf(&.{ name, count });
}

// ---------------------------------------------------------------------------------------
// skein.core's functions and the macros compiled into the program

var registered: [1]Value = .{Value.nil};
var registered_ready = false;

/// Called by a program that includes skein.compiler.env, at startup, for each var of
/// skein.core it compiled from lib/skein/core.skn (macro: 1 for a macro) and each var of
/// skein.core.native (D-060).
export fn sk_register_core_var(v: Value, macro: c_int) void {
    if (!registered_ready) {
        registered[0] = coll.vectorOf(&.{});
        gc.addRoots(&registered);
        registered_ready = true;
    }
    registered[0] = coll.vectorConj(registered[0], coll.vectorOf(&.{ v, Value.fromBool(macro != 0) }));
}

/// [[ns name value macro? var]...] for the registered vars, with their current values; var
/// is the var itself if it's dynamic (a binding of it must bind this var), else nil.
fn registeredCoreVars() Value {
    var out = coll.vectorOf(&.{});
    if (!registered_ready) return out;
    const all = registered[0];
    for (0..coll.vectorCount(all)) |i| {
        const entry = coll.vectorNth(all, i).?;
        const v = coll.vectorNth(entry, 0).?;
        const name = @import("string.zig").make(names.varName(v));
        const ns = @import("string.zig").make(names.varNamespaceName(v));
        const dynamic = if (names.isDynamic(v)) v else Value.nil;
        out = coll.vectorConj(out, coll.vectorOf(&.{ ns, name, names.varValue(v), coll.vectorNth(entry, 1).?, dynamic }));
    }
    return out;
}

fn coreFunctionNames() Value {
    var out = coll.vectorOf(&.{});
    for (core.names_list()) |n| out = coll.vectorConj(out, @import("string.zig").make(n));
    inline for (comptime std.enums.values(objects.CoreGeneric)) |g|
        out = coll.vectorConj(out, @import("string.zig").make(@tagName(g)));
    return out;
}

// ---------------------------------------------------------------------------------------
// For the interpreter of phase-1 code (lib/skein/compiler/interp.skn, M1.9 step 4,
// D-061): handlers and restarts given as data, multiple values, named functions and
// arity errors.

extern fn sk_mv_set(count: u32, values: [*]const Value) Value;
extern fn sk_mv_buffer() [*]Value;
extern fn sk_mv_count_get() i32;
extern fn sk_mv_clear() void;

const max_cluster = 64;

fn vectorItems(v: Value, buf: []Value, comptime what: []const u8) []Value {
    if (!coll.isVector(v)) rt.raise(.type_error, what ++ " needs a vector, not {s}", .{readable(v)});
    const n = coll.vectorCount(v);
    if (n > buf.len) rt.raise(.unsupported_operation_error, what ++ " with more than {d} items", .{buf.len});
    for (0..n) |i| buf[i] = coll.vectorNth(v, i).?;
    return buf[0..n];
}

/// Call `thunk` with a handler cluster of `types` (condition types or their names) and
/// `handlers`, as handler-bind* does.
fn callWithHandlers(types: Value, handlers: Value, thunk: Value) Value {
    var tbuf: [max_cluster]Value = undefined;
    var hbuf: [max_cluster]Value = undefined;
    const ts = vectorItems(types, &tbuf, "%call-with-handlers");
    const hs = vectorItems(handlers, &hbuf, "%call-with-handlers");
    if (ts.len != hs.len) rt.raise(.@"error", "%call-with-handlers needs as many handlers as types", .{});
    if (ts.len == 0) return func.call(thunk, 0, &.{});
    var frame: cond.Frame = undefined;
    cond.pushHandlers(&frame, ts, hs.ptr);
    const v = func.call(thunk, 0, &.{});
    cond.popFrame(&frame);
    return v;
}

/// Call `thunk` with a restart cluster of `names` (symbols), `fns` and `reports`, as
/// restart-bind* does.
fn callWithRestarts(restart_names: Value, fns: Value, reports: Value, thunk: Value) Value {
    var nbuf: [max_cluster]Value = undefined;
    var fbuf: [max_cluster]Value = undefined;
    var rbuf: [max_cluster]Value = undefined;
    const ns = vectorItems(restart_names, &nbuf, "%call-with-restarts");
    const fs = vectorItems(fns, &fbuf, "%call-with-restarts");
    const rs = vectorItems(reports, &rbuf, "%call-with-restarts");
    if (ns.len != fs.len or ns.len != rs.len) rt.raise(.@"error", "%call-with-restarts needs a function and a report per name", .{});
    if (ns.len == 0) return func.call(thunk, 0, &.{});
    var frame: cond.Frame = undefined;
    cond.pushRestarts(&frame, ns, fs.ptr, rs.ptr);
    const v = func.call(thunk, 0, &.{});
    cond.popFrame(&frame);
    return v;
}

/// Return the items of the vector `vs` as multiple values (the first, or nil).
fn applyValues(vs: Value) Value {
    var buf: [64]Value = undefined;
    const items = vectorItems(vs, &buf, "%apply-values");
    return sk_mv_set(@intCast(items.len), items.ptr);
}

/// Call `f` with the arguments in `args` (a vector); return a vector of all its values.
fn callWithValues(f: Value, args: Value) Value {
    var buf: [256]Value = undefined;
    const items = vectorItems(args, &buf, "%call-with-values");
    sk_mv_clear();
    const first = func.call(f, @intCast(items.len), items.ptr);
    const n = sk_mv_count_get();
    if (n < 0) return coll.vectorOf(&.{first});
    const values = sk_mv_buffer();
    var out = coll.vectorOf(&.{});
    for (0..@intCast(n)) |i| out = coll.vectorConj(out, values[i]);
    sk_mv_clear();
    return out;
}

var fn_names_lock: @import("platform").Mutex = .{};
var fn_names: std.StringHashMapUnmanaged([:0]const u8) = .empty;

/// A permanent C string for `name`, made once per name.
fn internedName(name: []const u8) [*:0]const u8 {
    gc.lockMutex(&fn_names_lock);
    defer fn_names_lock.unlock();
    if (fn_names.get(name)) |n| return n.ptr;
    const copy = std.heap.c_allocator.dupeSentinel(u8, name, 0) catch rt.fatal("out of memory", .{});
    fn_names.put(std.heap.c_allocator, copy, copy) catch rt.fatal("out of memory", .{});
    return copy.ptr;
}

fn namedCode(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    return func.call(func.capturedOf(self, 0), argc, argv);
}

/// `f` as a function whose name (in errors, %function-name) is `name`.
fn namedFn(name: Value, f: Value) Value {
    const s = @import("string.zig");
    if (!s.isString(name)) rt.raise(.type_error, "%named-fn needs a name, not {s}", .{readable(name)});
    return func.closure(namedCode, internedName(s.bytes(name)), &.{f});
}

/// An arity error about the function named `name`, called with `argc` arguments.
fn arityError(name: Value, argc: Value, message: Value) noreturn {
    const s = @import("string.zig");
    const c = cond.makeBuiltin(.arity_error, if (s.isString(message)) s.bytes(message) else "wrong number of arguments");
    coll.set(c, 2, coll.mapOf(&.{
        names.symbol(null, "function-name"),  name,
        names.symbol(null, "argument-count"), argc,
    }));
    cond.signalError(c);
}

// ---------------------------------------------------------------------------------------
// skein.core functions (core.zig's table includes these)

const Args = []const Value;

pub const Entry = struct {
    name: []const u8,
    min: u32,
    max: ?u32,
    impl: *const fn (Args) Value,
};

pub const entries = [_]Entry{
    .{ .name = "%copy-symbol", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return copySymbol(a[0]);
        }
    }.f },
    .{ .name = "%identity-table", .min = 0, .max = 0, .impl = struct {
        fn f(_: Args) Value {
            return identityTable();
        }
    }.f },
    .{ .name = "%identity-get", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return identityGet(a[0], a[1]);
        }
    }.f },
    .{ .name = "%identity-put!", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            return identityPut(a[0], a[1], a[2]);
        }
    }.f },
    .{ .name = "%f64-bits", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return f64Bits(a[0]);
        }
    }.f },
    .{ .name = "%f32-bits", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return f32Bits(a[0]);
        }
    }.f },
    .{ .name = "%decimal-to-float", .min = 4, .max = 4, .impl = struct {
        fn f(a: Args) Value {
            return decimalToFloat(a[0], a[1], a[2], a[3]);
        }
    }.f },
    .{ .name = "%generic?", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return Value.fromBool(a[0].isObjectOf(.function) and objects.genericOf(a[0]) != null);
        }
    }.f },
    .{ .name = "%arity-error-details", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return arityErrorDetails(a[0]);
        }
    }.f },
    .{ .name = "%function-name", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            if (!a[0].isObjectOf(.function)) return Value.nil;
            return @import("string.zig").make(func.name(a[0]));
        }
    }.f },
    // Natively every condition comes from Skein code or the runtime, and none carries a
    // source location of its own (messages include it where there is one).
    .{ .name = "%skein-error?", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return Value.fromBool(cond.isCondition(a[0]));
        }
    }.f },
    .{ .name = "%error-has-location?", .min = 1, .max = 1, .impl = struct {
        fn f(_: Args) Value {
            return Value.false;
        }
    }.f },
    .{ .name = "%core-function-names", .min = 0, .max = 0, .impl = struct {
        fn f(_: Args) Value {
            return coreFunctionNames();
        }
    }.f },
    .{ .name = "%core-function", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            const s = @import("string.zig");
            if (!s.isString(a[0])) return Value.nil;
            return core.function(s.bytes(a[0])) orelse Value.nil;
        }
    }.f },
    .{ .name = "%registered-core-vars", .min = 0, .max = 0, .impl = struct {
        fn f(_: Args) Value {
            return registeredCoreVars();
        }
    }.f },
    .{ .name = "%call-with-handlers", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            return callWithHandlers(a[0], a[1], a[2]);
        }
    }.f },
    .{ .name = "%call-with-restarts", .min = 4, .max = 4, .impl = struct {
        fn f(a: Args) Value {
            return callWithRestarts(a[0], a[1], a[2], a[3]);
        }
    }.f },
    .{ .name = "%apply-values", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return applyValues(a[0]);
        }
    }.f },
    .{ .name = "%call-with-values", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return callWithValues(a[0], a[1]);
        }
    }.f },
    .{ .name = "%named-fn", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return namedFn(a[0], a[1]);
        }
    }.f },
    .{ .name = "%add-method", .min = 5, .max = 5, .impl = struct {
        fn f(a: Args) Value {
            if (objects.genericOf(a[0]) == null) rt.raise(.type_error, "%add-method needs a generic function, not {s}", .{readable(a[0])});
            return objects.defineMethod(a[0], a[1], a[2], a[3], a[4]);
        }
    }.f },
    // Structs and defsoa at phase 1 (skein.compiler.env's %define-struct, M1.9 step 5)
    .{ .name = "%make-struct-def", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            return @import("structs.zig").defineStruct(a[0], a[1].isTruthy(), a[2]);
        }
    }.f },
    .{ .name = "%struct-constructor", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return @import("structs.zig").constructor(a[0]);
        }
    }.f },
    .{ .name = "%struct-predicate", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return @import("structs.zig").predicate(a[0]);
        }
    }.f },
    .{ .name = "%struct-accessor", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return @import("structs.zig").accessor(a[0], ux(a[1]));
        }
    }.f },
    .{ .name = "%make-soa-def", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return @import("structs.zig").defineSoa(a[0], a[1]);
        }
    }.f },
    .{ .name = "%soa-maker", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return @import("structs.zig").soaMaker(a[0]);
        }
    }.f },
    .{ .name = "%soa-field", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return @import("structs.zig").soaFieldFn(a[0], ux(a[1]));
        }
    }.f },
    .{ .name = "%arity-error", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            arityError(a[0], a[1], a[2]);
        }
    }.f },
};

// ---------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "symbol copies are equal but not identical" {
    coll.ensureConstants();
    const equal = @import("equal.zig");
    const a = names.symbol("ns", "x");
    const b = copySymbol(a);
    try testing.expect(a != b);
    try testing.expect(equal.equiv(a, b) and equal.equiv(b, a));
    try testing.expectEqual(equal.hashOf(a), equal.hashOf(b));
    try testing.expect(!equal.equiv(b, names.symbol(null, "x")));
    try testing.expect(!equal.equiv(b, names.symbol("ns", "y")));
    const m = coll.mapOf(&.{ a, fx(1) });
    try testing.expectEqual(@as(i64, 1), coll.mapGet(m, b).?.toFixnum());
}

test "identity tables match a model through collections" {
    coll.ensureConstants();
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    // Roots: the table and the keys made so far (vectors, which move when young).
    var roots: [2]Value = .{ identityTable(), coll.vectorOf(&.{}) };
    gc.addRoots(&roots);
    defer gc.removeRoots(&roots);
    // Model: key position -> value put for it (0 = none).
    var model: [600]i64 = @splat(0);
    for (0..3000) |step| {
        const n = coll.vectorCount(roots[1]);
        if (n < model.len and random.uintLessThan(u32, 3) == 0) {
            // A new key: an equal but distinct vector each time.
            roots[1] = coll.vectorConj(roots[1], coll.vectorOf(&.{fx(step % 5)}));
        } else if (n > 0) {
            const i = random.uintLessThan(usize, n);
            const k = coll.vectorNth(roots[1], i).?;
            if (random.boolean()) {
                const v: i64 = @intCast(step + 1);
                _ = identityPut(roots[0], k, Value.fromFixnum(v));
                model[i] = v;
            } else {
                const got = identityGet(roots[0], k);
                if (model[i] == 0) {
                    try testing.expectEqual(Value.nil, got);
                } else {
                    try testing.expectEqual(model[i], got.toFixnum());
                }
            }
        }
        if (step % 400 == 399) gc.collect(if (step % 800 == 799) .major else .minor);
    }
    // Every key, after a last collection.
    gc.collect(.minor);
    for (0..coll.vectorCount(roots[1])) |i| {
        const got = identityGet(roots[0], coll.vectorNth(roots[1], i).?);
        if (model[i] == 0) try testing.expectEqual(Value.nil, got) else try testing.expectEqual(model[i], got.toFixnum());
    }
}

test "decimal-to-float rounds correctly and reports overflow" {
    coll.ensureConstants();
    const f = names.keyword(null, "f64");
    const s = names.keyword(null, "f32");
    try testing.expectEqual(@as(f64, 0.1), num.toF64(decimalToFloat(Value.false, fx(1), Value.fromFixnum(-1), f)));
    try testing.expectEqual(@as(f64, -2.5e300), num.toF64(decimalToFloat(Value.true, fx(25), Value.fromFixnum(299), f)));
    try testing.expectEqual(Value.nil, decimalToFloat(Value.false, fx(1), Value.fromFixnum(400), f));
    try testing.expectEqual(Value.nil, decimalToFloat(Value.false, fx(1), Value.fromFixnum(39), s));
    try testing.expectEqual(@as(f32, 0.1), decimalToFloat(Value.false, fx(1), Value.fromFixnum(-1), s).toF32());
}
