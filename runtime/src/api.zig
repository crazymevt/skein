//! The C ABI that compiled Skein code calls (D-044). include/skein.h declares these and
//! inlines the fixnum fast paths; everything else comes here.

const std = @import("std");
const rt = @import("rt.zig");
const num = @import("num.zig");
const string = @import("string.zig");
const func = @import("func.zig");
const print = @import("print.zig");
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

export fn sk_init() void {}

export fn sk_exit(status: c_int) noreturn {
    std.process.exit(@intCast(status));
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
    rt.fatal("wrong number of arguments ({d}) passed to {s} (defined at {s})", .{
        argc, func.name(self), std.mem.span(defined_at),
    });
}

export fn sk_unbound(name: [*:0]const u8, location: [*:0]const u8) Value {
    rt.fatal("{s} is unbound at {s}", .{ std.mem.span(name), std.mem.span(location) });
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

/// Skein's = (value equality) for the types the runtime has so far.
export fn sk_equal_slow(a: Value, b: Value) Value {
    if (num.isNumber(a) and num.isNumber(b)) return Value.fromBool(num.numbersEqual(a, b));
    if (string.isString(a) and string.isString(b))
        return Value.fromBool(std.mem.eql(u8, string.bytes(a), string.bytes(b)));
    return Value.fromBool(a == b);
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
