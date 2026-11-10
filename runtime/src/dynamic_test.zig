//! Tests of dynamic bindings (dynamic.zig, D-076) that don't unwind or spawn tasks; the
//! native fixture native-dynamic.skn covers those, compared with `skein run`.

const std = @import("std");
const dynamic = @import("dynamic.zig");
const cond = @import("cond.zig");
const coll = @import("coll.zig");
const names = @import("names.zig");
const func = @import("func.zig");
const gc = @import("gc.zig");
const Value = @import("value.zig").Value;

const testing = std.testing;

extern fn sk_with_bindings(n: u32, vars: ?[*]const Value, symbols: Value, values: Value, f: Value) Value;
extern fn sk_dynamic_get(v: Value, name: [*:0]const u8, location: [*:0]const u8) Value;

fn setup() void {
    coll.ensureConstants();
    cond.ensureBuiltins();
}

var x_var: Value = undefined;
var y_var: Value = undefined;

fn read(v: Value) Value {
    return sk_dynamic_get(v, "test/v", "t.skn:1:1");
}

fn bind(v: Value, x: Value, f: Value) Value {
    return sk_with_bindings(1, &.{v}, coll.vectorOf(&.{names.symbol(null, "v")}), coll.vectorOf(&.{x}), f);
}

/// [*x* *y*], as seen inside a binding.
fn readBoth(_: Value, _: u32, _: [*]const Value) callconv(.c) Value {
    return coll.vectorOf(&.{ read(x_var), read(y_var) });
}

/// Inside (binding [*x* 2]): bind *x* to 3, set! it to 4, and return [inner outer].
fn nested(_: Value, _: u32, _: [*]const Value) callconv(.c) Value {
    const inner = bind(x_var, Value.fromFixnum(3), func.make(setAndRead, "set-and-read"));
    return coll.vectorOf(&.{ inner, read(x_var) });
}

fn setAndRead(_: Value, _: u32, _: [*]const Value) callconv(.c) Value {
    _ = dynamic.set(x_var, Value.fromFixnum(4));
    // A collection while the binding is in force keeps its values.
    _ = coll.vectorOf(&.{ Value.fromFixnum(1), Value.fromFixnum(2) });
    gc.collect(.major);
    return read(x_var);
}

fn captureInside(_: Value, _: u32, _: [*]const Value) callconv(.c) Value {
    return bind(x_var, Value.fromFixnum(5), func.make(captureNow, "capture"));
}

fn captureNow(_: Value, _: u32, _: [*]const Value) callconv(.c) Value {
    return dynamic.capture();
}

test "a binding is seen inside it, innermost first, and set! changes the innermost" {
    setup();
    x_var = names.makeVar("dyntest", "*x*");
    y_var = names.makeVar("dyntest", "*y*");
    names.setDynamic(x_var);
    names.setDynamic(y_var);
    names.setVar(x_var, Value.fromFixnum(1));
    names.setVar(y_var, names.keyword(null, "root"));

    try testing.expectEqual(Value.fromFixnum(1), read(x_var));
    const syms = coll.vectorOf(&.{ names.symbol(null, "*x*"), names.symbol(null, "*y*") });
    const vals = coll.vectorOf(&.{ Value.fromFixnum(2), Value.fromFixnum(7) });
    const both = sk_with_bindings(2, &.{ x_var, y_var }, syms, vals, func.make(readBoth, "read-both"));
    try testing.expectEqual(Value.fromFixnum(2), coll.vectorNth(both, 0).?);
    try testing.expectEqual(Value.fromFixnum(7), coll.vectorNth(both, 1).?);

    const r = bind(x_var, Value.fromFixnum(2), func.make(nested, "nested"));
    try testing.expectEqual(Value.fromFixnum(4), coll.vectorNth(r, 0).?);
    try testing.expectEqual(Value.fromFixnum(2), coll.vectorNth(r, 1).?);
    // Gone again afterwards.
    try testing.expectEqual(Value.fromFixnum(1), read(x_var));
    try testing.expectEqual(@as(?Value, null), dynamic.bound(x_var));
    try testing.expectEqual(cond.topFrame(), null);
}

test "a task's copy has one binding per var, the innermost" {
    setup();
    try testing.expectEqual(Value.nil, dynamic.capture());
    const copy = bind(x_var, Value.fromFixnum(9), func.make(captureInside, "capture-inside"));
    try testing.expectEqual(@as(usize, 2), coll.vectorCount(copy));
    try testing.expectEqual(x_var, coll.vectorNth(copy, 0).?);
    try testing.expectEqual(Value.fromFixnum(5), coll.vectorNth(copy, 1).?);
    var f: cond.Frame = undefined;
    try testing.expect(dynamic.pushCopy(&f, copy));
    try testing.expectEqual(Value.fromFixnum(5), read(x_var));
    _ = dynamic.set(x_var, Value.fromFixnum(6));
    try testing.expectEqual(Value.fromFixnum(6), read(x_var));
    // The copy itself is a value: set! made a new one for the frame.
    try testing.expectEqual(Value.fromFixnum(5), coll.vectorNth(copy, 1).?);
    cond.popFrame(&f);
    var g: cond.Frame = undefined;
    try testing.expect(!dynamic.pushCopy(&g, Value.nil));
}

test "def of a ^:dynamic var marks it" {
    const v = names.makeVar("dyntest", "plain");
    try testing.expect(!names.isDynamic(v));
    names.setDynamic(v);
    try testing.expect(names.isDynamic(v));
}
