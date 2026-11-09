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

pub fn name(v: Value) []const u8 {
    std.debug.assert(v.isObjectOf(.function));
    const p: [*:0]const u8 = @ptrFromInt(v.toObject().payload()[1]);
    return std.mem.span(p);
}

/// Call `f` with `args`; calling anything but a function is an error.
pub fn call(f: Value, argc: u32, argv: [*]const Value) Value {
    if (!f.isObjectOf(.function)) {
        const print = @import("print.zig");
        var buf: std.ArrayList(u8) = .empty;
        print.write(f, &buf, true);
        rt.fatal("{s} is not a function", .{buf.items});
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
