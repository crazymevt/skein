//! Watches and validators on atoms and refs (M2.11, D-093), as Clojure's. A validator is a
//! function of a proposed new value: when it returns false or nil (or signals), the
//! change doesn't happen. A watch is a function of (key reference old new), called after
//! each change, on the thread that made it; watches are a map of key to function, so
//! adding one with a key that's there replaces it.

const std = @import("std");
const rt = @import("rt.zig");
const gc = @import("gc.zig");
const coll = @import("coll.zig");
const func = @import("func.zig");
const print = @import("print.zig");
const Value = @import("value.zig").Value;

const Slots = struct { watches: usize, validator: usize };

/// Where an atom or a ref keeps its watches and validator.
fn slotsOf(r: Value) ?Slots {
    if (r.isObjectOf(.atom)) return .{ .watches = 2, .validator = 3 };
    if (r.isObjectOf(.ref)) return .{ .watches = 4, .validator = 5 };
    return null;
}

fn check(r: Value, comptime what: []const u8) Slots {
    return slotsOf(r) orelse {
        var out: std.ArrayList(u8) = .empty;
        print.write(r, &out, true);
        rt.raise(.type_error, what ++ " needs an atom or a ref, not {s}", .{out.items});
    };
}

fn load(r: Value, i: usize) Value {
    return @atomicLoad(Value, &coll.slots(r)[i], .acquire);
}

fn casSlot(r: Value, i: usize, old: Value, new: Value) bool {
    const h = r.toObject();
    if (@cmpxchgStrong(Value, &h.valueSlots()[i], old, new, .acq_rel, .acquire) != null) return false;
    gc.barrier(h, new);
    return true;
}

/// Check `v` with the validator of `r`, if it has one: an error if it rejects it.
pub fn validate(r: Value, v: Value) void {
    const s = slotsOf(r) orelse return;
    const f = load(r, s.validator);
    if (f == Value.nil) return;
    const ok = func.call(f, 1, &.{v});
    if (ok == Value.nil or ok == Value.false) {
        var out: std.ArrayList(u8) = .empty;
        print.write(v, &out, true);
        rt.raise(.@"error", "the validator rejected the new value {s}", .{out.items});
    }
}

/// Call the watches of `r` for a change from `old` to `new`.
pub fn notify(r: Value, old: Value, new: Value) void {
    const s = slotsOf(r) orelse return;
    const watches = load(r, s.watches);
    if (watches == Value.nil) return;
    const Call = struct {
        r: Value,
        old: Value,
        new: Value,
        fn each(c: *@This(), k: Value, f: Value) bool {
            _ = func.call(f, 4, &.{ k, c.r, c.old, c.new });
            return true;
        }
    };
    var ctx: Call = .{ .r = r, .old = old, .new = new };
    coll.mapEach(watches, &ctx, Call.each);
}

/// True if `r` has a watch or a validator (the slow path of a change).
pub fn watched(r: Value) bool {
    const s = slotsOf(r) orelse return false;
    return load(r, s.watches) != Value.nil or load(r, s.validator) != Value.nil;
}

fn updateWatches(r: Value, key: Value, f: ?Value, comptime what: []const u8) void {
    const s = check(r, what);
    while (true) {
        const old = load(r, s.watches);
        var m = if (old == Value.nil) coll.mapOf(&.{}) else old;
        m = if (f) |w| coll.mapAssoc(m, key, w) else coll.mapDissoc(m, key);
        const new = if (coll.mapCount(m) == 0) Value.nil else m;
        if (casSlot(r, s.watches, old, new)) return;
    }
}

const Args = []const Value;
const CoreEntry = @import("compiler.zig").Entry;

pub const entries = [_]CoreEntry{
    // (add-watch reference key f): call (f key reference old new) after each change.
    .{ .name = "add-watch", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            if (!a[2].isObjectOf(.function)) rt.raise(.type_error, "add-watch needs a function", .{});
            updateWatches(a[0], a[1], a[2], "add-watch");
            return a[0];
        }
    }.f },
    .{ .name = "remove-watch", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            updateWatches(a[0], a[1], null, "remove-watch");
            return a[0];
        }
    }.f },
    // (set-validator! reference f): f must accept the current value; nil removes it.
    .{ .name = "set-validator!", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            const s = check(a[0], "set-validator!");
            const r = a[0];
            const v = a[1];
            if (v != Value.nil) {
                if (!v.isObjectOf(.function)) rt.raise(.type_error, "set-validator! needs a function or nil", .{});
                // An atom's value and a ref's committed value are both slot 0.
                const ok = func.call(v, 1, &.{load(r, 0)});
                if (ok == Value.nil or ok == Value.false) rt.raise(.@"error", "the validator rejects the current value", .{});
            }
            const h = r.toObject();
            @atomicStore(Value, &h.valueSlots()[s.validator], v, .release);
            gc.barrier(h, v);
            return Value.nil;
        }
    }.f },
    .{ .name = "get-validator", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return load(a[0], check(a[0], "get-validator").validator);
        }
    }.f },
};
