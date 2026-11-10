//! Dynamic vars (DESIGN §4.3, M2.4, D-076), matching Phase 0
//! (host/src/runtime/namespaces.lisp).
//!
//! A `binding` is a frame on the condition chain (cond.zig), so a non-local exit drops it
//! and each fiber has its own. Its value is a vector [var value var value ...]; `set!`
//! replaces it with one whose value for the var has changed. A read of a ^:dynamic var
//! looks for the innermost frame that binds it, else takes the root value.
//!
//! A task gets a copy of the bindings in force where it's spawned (`capture`), which it
//! pushes as one such frame when it starts (`pushCopy`): its `set!` changes only its own.
//!
//! Vars are resolved by the compiler; whether a var is ^:dynamic is also a flag on the var
//! object, which `def` sets, for a binding of a var that didn't exist yet when the binding
//! was compiled (Phase 0 checks it when the binding runs).

const std = @import("std");
const cond = @import("cond.zig");
const coll = @import("coll.zig");
const names = @import("names.zig");
const func = @import("func.zig");
const rt = @import("rt.zig");
const Value = @import("value.zig").Value;

const Frame = cond.Frame;

const Binding = struct { frame: *Frame, index: usize };

/// The innermost binding of `v`, if any.
fn find(v: Value) ?Binding {
    var f = cond.topFrame();
    while (f) |fr| : (f = fr.prev) {
        if (fr.kind != @intFromEnum(cond.Kind.dynamic)) continue;
        for (0..fr.count) |i| {
            if (coll.vectorNth(fr.value, 2 * i).? == v) return .{ .frame = fr, .index = i };
        }
    }
    return null;
}

/// The value of the innermost binding of `v`, or null if nothing binds it.
pub fn bound(v: Value) ?Value {
    const b = find(v) orelse return null;
    return coll.vectorNth(b.frame.value, 2 * b.index + 1).?;
}

/// Set the innermost binding of `v` to `x`; an error if nothing binds it.
pub fn set(v: Value, x: Value) Value {
    const b = find(v) orelse rt.raise(.@"error", "cannot set! {s}/{s} outside a binding of it", .{ names.varNamespaceName(v), names.varName(v) });
    b.frame.value = coll.vectorAssoc(b.frame.value, 2 * b.index + 1, x);
    return x;
}

/// Push `f` binding the vars and values in `pairs` ([var value ...], `n` pairs).
fn push(f: *Frame, pairs: Value, n: usize) void {
    cond.pushFrame(f, .dynamic);
    f.count = @intCast(n);
    f.value = pairs;
}

/// The bindings in force, one per var (the innermost), as [var value ...], or nil if
/// there are none: what a task spawned here starts with.
pub fn capture() Value {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(std.heap.c_allocator);
    var f = cond.topFrame();
    while (f) |fr| : (f = fr.prev) {
        if (fr.kind != @intFromEnum(cond.Kind.dynamic)) continue;
        outer: for (0..fr.count) |i| {
            const v = coll.vectorNth(fr.value, 2 * i).?;
            var j: usize = 0;
            while (j < items.items.len) : (j += 2) if (items.items[j] == v) continue :outer;
            items.appendSlice(std.heap.c_allocator, &.{ v, coll.vectorNth(fr.value, 2 * i + 1).? }) catch
                rt.fatal("out of memory (dynamic bindings)", .{});
        }
    }
    if (items.items.len == 0) return Value.nil;
    return coll.vectorOf(items.items);
}

/// Push `f` binding what `capture` returned (nothing for nil); pop it with cond.popFrame.
/// Returns whether it pushed a frame.
pub fn pushCopy(f: *Frame, copy: Value) bool {
    if (copy == Value.nil) return false;
    push(f, copy, coll.vectorCount(copy) / 2);
    return true;
}

fn symbolText(s: Value, buf: []u8) []const u8 {
    return if (names.nsOf(s)) |ns|
        std.fmt.bufPrint(buf, "{s}/{s}", .{ ns, names.nameOf(s) }) catch names.nameOf(s)
    else
        names.nameOf(s);
}

// ---------------------------------------------------------------------------------------
// The C interface

/// Read the ^:dynamic var `v`: its innermost binding, else its root value.
export fn sk_dynamic_get(v: Value, name: [*:0]const u8, location: [*:0]const u8) Value {
    if (bound(v)) |x| return x;
    const root = names.varValue(v);
    return if (root != Value.unbound) root else sk_unbound(name, location);
}

extern fn sk_unbound(name: [*:0]const u8, location: [*:0]const u8) Value;

/// (set! *x* value) of a ^:dynamic var.
export fn sk_set_dynamic(v: Value, x: Value) Value {
    return set(v, x);
}

/// def of a ^:dynamic var marks it.
export fn sk_var_set_dynamic(v: Value) void {
    names.setDynamic(v);
}

/// binding: call `f` with the `n` vars bound to the values in the vector `values`.
/// `symbols` is a vector of the names the binding used, for its errors.
export fn sk_with_bindings(n: u32, vars: ?[*]const Value, symbols: Value, values: Value, f: Value) Value {
    var buf: [256]u8 = undefined;
    // [var value ...], made one pair at a time: the values stay reachable from `values`.
    var pairs = coll.vectorTransient(coll.vectorOf(&.{}));
    for (0..n) |i| {
        const v = vars.?[i];
        if (!names.isDynamic(v)) {
            // A var nothing defined: a name the compiler couldn't resolve.
            if (names.varValue(v) == Value.unbound) {
                const s = coll.vectorNth(symbols, i).?;
                rt.raise(.@"error", "unable to resolve symbol `{s}` in binding", .{symbolText(s, &buf)});
            }
            rt.raise(.@"error", "binding needs a ^:dynamic var, and {s}/{s} isn't one", .{ names.varNamespaceName(v), names.varName(v) });
        }
        pairs = coll.tvectorConj(pairs, v);
        pairs = coll.tvectorConj(pairs, coll.vectorNth(values, i).?);
    }
    // The frame, on this stack (which the collector scans), holds the vector.
    var frame: Frame = undefined;
    push(&frame, coll.tvectorPersistent(pairs), n);
    const r = func.call(f, 0, &.{});
    cond.popFrame(&frame);
    return r;
}
