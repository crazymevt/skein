//! Tests of conditions and restarts that don't unwind. Unwinding needs setjmp in compiled
//! C, so the native program tests in host/tests/backend-c.lisp cover it.

const std = @import("std");
const cond = @import("cond.zig");
const coll = @import("coll.zig");
const names = @import("names.zig");
const string = @import("string.zig");
const func = @import("func.zig");
const Value = @import("value.zig").Value;

const testing = std.testing;

fn setup() void {
    coll.ensureConstants();
    cond.ensureBuiltins();
}

test "built-in types form a hierarchy" {
    setup();
    const c = cond.makeBuiltin(.arithmetic_error, "division by zero");
    try testing.expect(cond.isA(c, cond.builtinType(.arithmetic_error)));
    try testing.expect(cond.isA(c, cond.builtinType(.@"error")));
    try testing.expect(cond.isA(c, cond.builtinType(.condition)));
    try testing.expect(!cond.isA(c, cond.builtinType(.warning)));
    try testing.expectEqualStrings("division by zero", string.bytes(cond.messageOf(c)));
    try testing.expectEqualStrings("skein.core/arithmetic-error", cond.typeName(cond.conditionType(c)));
}

test "condition types are found by name" {
    setup();
    const err = cond.builtinType(.@"error");
    try testing.expectEqual(err, cond.findType(names.symbol(null, "error"), "user"));
    try testing.expectEqual(cond.builtinType(.index_error), cond.findType(names.symbol(null, "index-error"), "user"));
    try testing.expectEqual(err, cond.findType(names.symbol("skein.core", "error"), null));
    const t = cond.defineType(names.symbol("t1", "unique-thing"), coll.vectorOf(&.{err}), coll.vectorOf(&.{}), Value.nil);
    // Unqualified, in its namespace, or anywhere if the name is unique.
    try testing.expectEqual(t, cond.findType(names.symbol(null, "unique-thing"), "t1"));
    try testing.expectEqual(t, cond.findType(names.symbol(null, "unique-thing"), "elsewhere"));
    // Redefinition keeps the type object.
    try testing.expectEqual(t, cond.defineType(names.symbol("t1", "unique-thing"), coll.vectorOf(&.{err}), coll.vectorOf(&.{}), Value.nil));
    try testing.expectEqual(names.symbol("t1", "unique-thing"), cond.typeNameSymbol(t));
}

fn constantly42(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = self;
    _ = argc;
    _ = argv;
    return Value.fromFixnum(42);
}

test "slots take initargs, then initforms" {
    setup();
    const initform = func.make(constantly42, "initform");
    const slots = coll.vectorOf(&.{
        coll.vectorOf(&.{ names.symbol(null, "a"), initform }),
        coll.vectorOf(&.{ names.symbol(null, "b"), Value.nil }),
    });
    _ = cond.defineType(names.symbol("t2", "with-slots"), coll.vectorOf(&.{cond.builtinType(.@"error")}), slots, Value.nil);
    const c = cond.makeCondition(names.symbol("t2", "with-slots"), &.{ names.keyword(null, "b"), Value.fromFixnum(7) });
    try testing.expectEqual(@as(i64, 42), cond.slotValue(c, "a").?.toFixnum());
    try testing.expectEqual(@as(i64, 7), cond.slotValue(c, "b").?.toFixnum());
    try testing.expectEqual(@as(?Value, null), cond.slotValue(c, "zzz"));
    try testing.expectEqualStrings("t2/with-slots {:a 42, :b 7}", string.bytes(cond.messageOf(c)));
}

var handled: usize = 0;

fn countingHandler(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = self;
    _ = argc;
    _ = argv;
    handled += 1;
    return Value.nil;
}

test "declining handlers all run, innermost first, each once" {
    setup();
    handled = 0;
    const h = func.make(countingHandler, "handler");
    var outer: cond.Frame = undefined;
    var outer_types = [_]Value{cond.builtinType(.condition)};
    const outer_fns = [_]Value{h};
    cond.pushHandlers(&outer, &outer_types, &outer_fns);
    var inner: cond.Frame = undefined;
    var inner_types = [_]Value{ names.symbol(null, "error"), cond.builtinType(.warning) };
    const inner_fns = [_]Value{ h, h };
    cond.pushHandlers(&inner, &inner_types, &inner_fns);
    // The symbol was resolved to the type.
    try testing.expectEqual(cond.builtinType(.@"error"), inner_types[0]);
    cond.signal(cond.makeBuiltin(.@"error", "x"));
    try testing.expectEqual(@as(usize, 2), handled);
    cond.popFrame(&inner);
    cond.popFrame(&outer);
    try testing.expectEqual(@as(?*cond.Frame, null), cond.topFrame());
}

test "restarts are listed innermost first and found by plain name" {
    setup();
    var f: cond.Frame = undefined;
    var restart_names = [_]Value{ names.symbol("some.ns", "retry"), names.symbol(null, "skip") };
    const fns = [_]Value{ func.make(constantly42, "r1"), func.make(constantly42, "r2") };
    const reports = [_]Value{ string.make("Try again"), Value.nil };
    cond.pushRestarts(&f, &restart_names, &fns, &reports);
    const list = cond.computeRestarts();
    try testing.expectEqual(@as(usize, 2), coll.ux(coll.get(list, 2)));
    const r = cond.findRestart(names.symbol(null, "retry"));
    try testing.expectEqual(names.symbol(null, "retry"), cond.restartName(r));
    try testing.expectEqualStrings("Try again", string.bytes(cond.restartReport(r)));
    try testing.expectEqualStrings("skip", string.bytes(cond.restartReport(cond.findRestart(names.symbol(null, "skip")))));
    try testing.expectEqual(@as(i64, 42), cond.invokeRestart(r, &.{}).toFixnum());
    cond.popFrame(&f);
    // A restart value outlives its frame but is no longer active.
    try testing.expectEqual(Value.nil, cond.findRestart(r));
    try testing.expectEqual(Value.nil, cond.findRestart(names.symbol(null, "retry")));
}
