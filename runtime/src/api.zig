//! The C ABI that compiled Skein code calls (D-044). include/skein.h declares these and
//! inlines the fixnum fast paths; everything else comes here.

const std = @import("std");
const rt = @import("rt.zig");
const num = @import("num.zig");
const string = @import("string.zig");
const func = @import("func.zig");
const print = @import("print.zig");
const gc = @import("gc.zig");
const names = @import("names.zig");
const coll = @import("coll.zig");
const equal = @import("equal.zig");
const core = @import("core.zig");
const Value = @import("value.zig").Value;

// skein.h spells the immediate constants out; keep them in step with value.zig.
comptime {
    std.debug.assert(@intFromEnum(Value.nil) == 0x03);
    std.debug.assert(@intFromEnum(Value.false) == 0x0B);
    std.debug.assert(@intFromEnum(Value.true) == 0x13);
    std.debug.assert(@intFromEnum(Value.unbound) == 0x1B);
    std.debug.assert(@intFromEnum(Value.fromChar(0)) == 0x23);
    std.debug.assert(@intFromEnum(Value.fromF32(0.0)) == 0x05);
}

/// Start the runtime on the calling (main) thread.
extern fn sk_mv_buffer() [*]Value;

export fn sk_init() void {
    _ = gc.attachThread();
    coll.ensureConstants();
    @import("cond.zig").ensureBuiltins();
    @import("objects.zig").ensureBuiltins();
    // The main thread's multiple-values buffer holds values between a return and the
    // let-values* that reads them. (Threads register theirs in M1.8 step 6.)
    gc.addRoots(sk_mv_buffer()[0..64]);
}

export fn sk_too_many_values(count: u32) noreturn {
    rt.raise(.unsupported_operation_error, "values with {d} values; the native runtime supports at most 64", .{count});
}

/// Finish normally: print GC statistics if SKEIN_GC_STATS is set.
export fn sk_finish() void {
    if (std.c.getenv("SKEIN_GC_STATS") != null) gc.printStats();
}

export fn sk_exit(status: c_int) noreturn {
    sk_finish();
    std.process.exit(@intCast(status));
}

// Garbage collection

/// Make `count` values starting at `slots` roots (a program's globals).
export fn sk_register_roots(slots: [*]Value, count: usize) void {
    gc.addRoots(slots[0..count]);
}

/// Stop for a pending collection; compiled code calls this when `sk_gc_pending` is set.
export fn sk_safepoint() void {
    gc.safepoint();
}

/// Collect now: a major collection if `major` is true, else a minor one.
export fn sk_collect(major: bool) void {
    gc.collect(if (major) .major else .minor);
}

// Constants

export fn sk_string(bytes: [*]const u8, len: usize) Value {
    return string.make(bytes[0..len]);
}

export fn sk_f64(x: f64) Value {
    return num.boxF64(x);
}

export fn sk_integer(text: [*:0]const u8) Value {
    return num.parseInteger(std.mem.span(text));
}

// Functions

export fn sk_fn(code: func.Code, name: [*:0]const u8) Value {
    return func.make(code, name);
}

export fn sk_call(f: Value, argc: u32, argv: [*]const Value) Value {
    return func.call(f, argc, argv);
}

export fn sk_arity_error(self: Value, argc: u32, defined_at: [*:0]const u8) Value {
    rt.raise(.arity_error, "wrong number of arguments ({d}) passed to {s} (defined at {s})", .{
        argc, func.name(self), std.mem.span(defined_at),
    });
}

export fn sk_unbound(name: [*:0]const u8, location: [*:0]const u8) Value {
    rt.raise(.unbound_var_error, "{s} is unbound at {s}", .{ std.mem.span(name), std.mem.span(location) });
}

// Numbers: the slow paths behind skein.h's inline fixnum cases.

export fn sk_add_slow(a: Value, b: Value) Value {
    return num.arith(.add, a, b);
}

export fn sk_sub_slow(a: Value, b: Value) Value {
    return num.arith(.sub, a, b);
}

export fn sk_mul_slow(a: Value, b: Value) Value {
    return num.arith(.mul, a, b);
}

export fn sk_div(a: Value, b: Value) Value {
    return num.arith(.div, a, b);
}

/// Comparison `op`: 0 <, 1 >, 2 <=, 3 >=, 4 == (numeric equality).
export fn sk_compare_slow(op: c_int, a: Value, b: Value) Value {
    const name = switch (op) {
        0 => "<",
        1 => ">",
        2 => "<=",
        3 => ">=",
        else => "==",
    };
    const order = num.compare(name, a, b) orelse return Value.false;
    return Value.fromBool(switch (op) {
        0 => order == .lt,
        1 => order == .gt,
        2 => order != .gt,
        3 => order != .lt,
        else => order == .eq,
    });
}

/// Skein's = (value equality).
export fn sk_equal_slow(a: Value, b: Value) Value {
    return Value.fromBool(equal.equiv(a, b));
}

// Names, vars and core functions (M1.4)

fn optional(text: ?[*:0]const u8) ?[]const u8 {
    return if (text) |t| std.mem.span(t) else null;
}

export fn sk_keyword(ns: ?[*:0]const u8, name: [*:0]const u8) Value {
    return names.keyword(optional(ns), std.mem.span(name));
}

export fn sk_symbol(ns: ?[*:0]const u8, name: [*:0]const u8) Value {
    return names.symbol(optional(ns), std.mem.span(name));
}

/// A new unbound var ns/name.
export fn sk_var(ns: [*:0]const u8, name: [*:0]const u8) Value {
    return names.makeVar(std.mem.span(ns), std.mem.span(name));
}

/// Set a var's value (def); returns the var.
export fn sk_var_set(v: Value, x: Value) Value {
    names.setVar(v, x);
    return v;
}

/// The function object of skein.core/`name`; the program stops if the runtime lacks it.
export fn sk_core(name: [*:0]const u8) Value {
    return core.function(std.mem.span(name)) orelse
        rt.fatal("the native runtime has no skein.core/{s}", .{std.mem.span(name)});
}

/// The built-in condition type skein.core/`name` (the value of its var).
export fn sk_builtin_condition_type(name: [*:0]const u8) Value {
    return @import("cond.zig").findType(names.symbol("skein.core", std.mem.span(name)), null);
}

// Collections built from compiled literals

export fn sk_list_of(count: usize, items: [*]const Value) Value {
    return coll.listOf(items[0..count]);
}

export fn sk_vector_of(count: usize, items: [*]const Value) Value {
    return coll.vectorOf(items[0..count]);
}

/// A map of `count` values: keys and values alternating.
export fn sk_map_of(count: usize, kvs: [*]const Value) Value {
    return coll.mapOf(kvs[0..count]);
}

export fn sk_set_of(count: usize, items: [*]const Value) Value {
    return coll.setOf(items[0..count]);
}

/// The rest parameter's value: a list of the arguments from `from` on, or nil.
export fn sk_rest_list(argc: u32, argv: [*]const Value, from: u32) Value {
    if (argc <= from) return Value.nil;
    return coll.listOf(argv[from..argc]);
}

// Closures: a function object with captured values after its code and name.

export fn sk_closure(code: func.Code, name: [*:0]const u8, count: usize, captured: [*]const Value) Value {
    const h = rt.alloc(.function, 2 + count);
    h.payload()[0] = @intFromPtr(code);
    h.payload()[1] = @intFromPtr(name);
    @memcpy(h.valueSlots()[0..count], captured[0..count]);
    return Value.fromObject(h);
}

/// Set captured value `i` of a closure (letfn ties mutually recursive closures this way).
export fn sk_closure_set(f: Value, i: usize, v: Value) void {
    const h = f.toObject();
    gc.store(h, &h.valueSlots()[i], v);
}

/// A check that `v` is a number, for the one-argument cases of + and *.
export fn sk_check_number(name: [*:0]const u8, v: Value) Value {
    if (!num.isNumber(v)) num.notANumber(std.mem.span(name), v);
    return v;
}

// Printing

/// print, println, pr and prn: `readably` as pr does, `newline` as println does.
export fn sk_print(argc: u32, argv: [*]const Value, readably: bool, newline: bool) Value {
    print.printValues(argv[0..argc], readably, newline);
    return Value.nil;
}
