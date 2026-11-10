//! Functions (DESIGN §17.3). Compiled code has one C entry point per function,
//!
//!   sk_value code(sk_value self, uint32_t argc, const sk_value *argv)
//!
//! that checks the argument count and picks the arity. `self` is the function object, so
//! a function can call itself and, from M1.4, reach its captured values.

const std = @import("std");
const object = @import("object.zig");
const rt = @import("rt.zig");
const Value = @import("value.zig").Value;

pub const Code = *const fn (self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value;

/// A function object for `code`, printed with `fn_name` (a C string that must stay valid).
pub fn make(code: Code, fn_name: [*:0]const u8) Value {
    const h = rt.alloc(.function, 2);
    h.payload()[0] = @intFromPtr(code);
    h.payload()[1] = @intFromPtr(fn_name);
    return Value.fromObject(h);
}

/// A closure made by the runtime: `code` reads `captured` with `capturedOf`.
pub fn closure(code: Code, fn_name: [*:0]const u8, captured: []const Value) Value {
    const h = rt.alloc(.function, 2 + captured.len);
    h.payload()[0] = @intFromPtr(code);
    h.payload()[1] = @intFromPtr(fn_name);
    @memcpy(h.valueSlots()[0..captured.len], captured);
    return Value.fromObject(h);
}

/// A closure that is never moved or freed, for tables the collector doesn't scan (generic
/// functions, M1.12). Its captured values are stored with the write barrier.
pub fn permanentClosure(code: Code, fn_name: [*:0]const u8, captured: []const Value) Value {
    const gc = @import("gc.zig");
    const h = gc.allocPermanent(.function, 2 + captured.len);
    h.payload()[0] = @intFromPtr(code);
    h.payload()[1] = @intFromPtr(fn_name);
    for (captured, 0..) |v, i| gc.store(h, &h.valueSlots()[i], v);
    return Value.fromObject(h);
}

/// Captured value `i` of a closure.
pub fn capturedOf(self: Value, i: usize) Value {
    return self.toObject().valueSlots()[i];
}

/// The code pointer of a function object.
pub fn codeOf(v: Value) Code {
    return @ptrFromInt(v.toObject().payload()[0]);
}

pub fn name(v: Value) []const u8 {
    std.debug.assert(v.isObjectOf(.function));
    const p: [*:0]const u8 = @ptrFromInt(v.toObject().payload()[1]);
    return std.mem.span(p);
}

/// Call `f` with `args`; calling anything but a function is an error.
pub fn call(f: Value, argc: u32, argv: [*]const Value) Value {
    // A keyword looks itself up in its argument: (:a m) and (:a m default).
    if (f.isObjectOf(.keyword)) {
        if (argc < 1 or argc > 2) rt.raise(.arity_error, "wrong number of arguments ({d}) passed to a keyword", .{argc});
        const args = [_]Value{ argv[0], f, if (argc == 2) argv[1] else Value.nil };
        return call(@import("core.zig").function("get").?, 3, &args);
    }
    // Maps and sets look up their argument; vectors give the element at an index.
    const coll = @import("coll.zig");
    if (coll.isMap(f) or coll.isSet(f)) {
        if (argc < 1 or argc > 2) rt.raise(.arity_error, "a map or set called with {d} arguments; expected 1 or 2", .{argc});
        const args = [_]Value{ f, argv[0], if (argc == 2) argv[1] else Value.nil };
        return call(@import("core.zig").function("get").?, 3, &args);
    }
    if (coll.isVector(f)) {
        if (argc != 1) rt.raise(.arity_error, "a vector called with {d} arguments; expected 1", .{argc});
        const args = [_]Value{ f, argv[0] };
        return call(@import("core.zig").function("nth").?, 2, &args);
    }
    if (!f.isObjectOf(.function)) {
        const print = @import("print.zig");
        var buf: std.ArrayList(u8) = .empty;
        print.write(f, &buf, true);
        rt.raise(.not_callable_error, "{s} is not a function", .{buf.items});
    }
    const code: Code = @ptrFromInt(f.toObject().payload()[0]);
    return code(f, argc, argv);
}

test "functions call their code with themselves" {
    const Impl = struct {
        fn code(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
            _ = self;
            return Value.fromFixnum(@as(i64, argc) * 10 + argv[0].toFixnum());
        }
    };
    const f = make(Impl.code, "test-fn");
    const args = [_]Value{ Value.fromFixnum(3), Value.nil };
    try std.testing.expectEqual(@as(i64, 23), call(f, 2, &args).toFixnum());
    try std.testing.expectEqualStrings("test-fn", name(f));
}
