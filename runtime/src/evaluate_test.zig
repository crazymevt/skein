//! Tests of the registry and hooks behind eval (evaluate.zig, D-078). Programs built with
//! --eval are tested by the native fixture native-eval.skn, compared with `skein run`.

const std = @import("std");
const coll = @import("coll.zig");
const core = @import("core.zig");
const func = @import("func.zig");
const names = @import("names.zig");
const string = @import("string.zig");
const Value = @import("value.zig").Value;

const testing = std.testing;

extern fn sk_eval_register_ns(info: *const Value) void;
extern fn sk_eval_register_var(ns: [*:0]const u8, name: [*:0]const u8, v: Value, flags: u32) void;

fn call(name: []const u8, args: []const Value) Value {
    return func.call(core.function(name).?, @intCast(args.len), args.ptr);
}

var info: Value = undefined;

fn plusOne(_: Value, _: u32, argv: [*]const Value) callconv(.c) Value {
    return Value.fromFixnum(argv[0].toFixnum() + 1);
}

test "a program's namespaces and vars are registered for the model" {
    coll.ensureConstants();
    try testing.expectEqual(Value.nil, call("%eval-registry", &.{}));
    info = coll.mapOf(&.{ names.keyword(null, "name"), string.make("evaltest") });
    sk_eval_register_ns(&info);
    const v = names.makeVar("evaltest", "x");
    sk_eval_register_var("evaltest", "x", v, 1 | 4);
    sk_eval_register_var("evaltest", "declared", Value.nil, 2);
    const reg = call("%eval-registry", &.{});
    try testing.expectEqual(info, coll.vectorNth(coll.vectorNth(reg, 0).?, 0).?);
    const vars = coll.vectorNth(reg, 1).?;
    try testing.expectEqual(@as(usize, 2), coll.vectorCount(vars));
    const x = coll.vectorNth(vars, 0).?;
    try testing.expectEqualStrings("x", string.bytes(coll.vectorNth(x, 1).?));
    try testing.expectEqual(v, coll.vectorNth(x, 2).?);
    try testing.expectEqual(Value.true, coll.vectorNth(x, 3).?);
    try testing.expectEqual(Value.false, coll.vectorNth(x, 4).?);
    try testing.expectEqual(Value.true, coll.vectorNth(x, 5).?);
    try testing.expectEqual(Value.true, coll.vectorNth(coll.vectorNth(vars, 1).?, 4).?);

    // The model reads and sets the real var.
    const unbound = names.keyword(null, "unbound");
    try testing.expectEqual(unbound, call("%runtime-var-value", &.{ v, unbound }));
    _ = call("%set-runtime-var-value!", &.{ v, Value.fromFixnum(3) });
    try testing.expectEqual(Value.fromFixnum(3), names.varValue(v));
}

test "an installed function runs behind eval and its relatives" {
    coll.ensureConstants();
    _ = call("%install-evaluator!", &.{coll.mapOf(&.{ string.make("eval"), func.make(plusOne, "plus-one") })});
    try testing.expectEqual(Value.fromFixnum(42), call("eval", &.{Value.fromFixnum(41)}));
}
