//! Software transactional memory (DESIGN §13.3, M2.10, D-092): refs, changed in `dosync`
//! transactions that are serializable, TL2-style. A global version clock stamps every
//! commit; each ref holds its value, the version of the commit that wrote it, and a lock
//! word that only commits take. A transaction reads the clock when it starts (its read
//! version), checks every ref it reads against it (an unlocked ref no newer than the read
//! version), and buffers its writes. At commit it locks the refs it writes, takes a write
//! version from the clock, checks that what it read is still that old, applies its
//! commutes, writes, and unlocks. A conflict, found at a read or at commit, runs the body
//! again from the start: the attempt runs in a block frame, which a conflict leaves.
//!
//! The running transaction is a frame on the fiber's condition chain, so a task the body
//! starts isn't in it, and code a transaction can repeat (channel operations, sleep,
//! on-main-thread, io!) refuses to run in one.

const std = @import("std");
const rt = @import("rt.zig");
const coll = @import("coll.zig");
const cond = @import("cond.zig");
const func = @import("func.zig");
const gc = @import("gc.zig");
const hash = @import("hash.zig");
const print = @import("print.zig");
const Value = @import("value.zig").Value;

// A ref: [value, version (fixnum), lock (nil, or the fixnum id of the committing
// transaction), identity hash].
const r_value = 0;
const r_version = 1;
const r_lock = 2;
const r_hash = 3;

/// The version of the last commit.
var clock = std.atomic.Value(i64).init(0);
/// Transaction ids, which lock words hold.
var next_id = std.atomic.Value(i64).init(1);
/// How many transactions are running, so code that may not run in one only looks for one
/// when there could be one.
var running = std.atomic.Value(u32).init(0);
var identity_counter = std.atomic.Value(u32).init(0);

/// How often a transaction may retry before it gives up (as Clojure's).
const max_tries = 10_000;

const Thunk = *const fn (ctx: *anyopaque) callconv(.c) Value;
extern fn sk_eval_block(body: Thunk, ctx: *anyopaque, token: *Value) Value;
extern fn sk_eval_unwind_protect(body: Thunk, cleanup: Thunk, ctx: *anyopaque) Value;
extern fn sk_return_from(token: Value, v: Value) noreturn;

// ---------------------------------------------------------------------------------------
// Refs

fn slots(r: Value) []Value {
    return coll.slots(r);
}

fn load(r: Value, i: usize) Value {
    return @atomicLoad(Value, &slots(r)[i], .acquire);
}

pub fn isRef(v: Value) bool {
    return v.isObjectOf(.ref);
}

pub fn makeRef(v: Value) Value {
    const id = hash.mix32(identity_counter.fetchAdd(1, .monotonic) +% 1);
    return coll.make(.ref, &.{ v, Value.fromFixnum(0), Value.nil, Value.fromFixnum(id) });
}

pub fn hashOf(r: Value) u32 {
    return @intCast(slots(r)[r_hash].toFixnum());
}

pub fn write(r: Value, out: *std.ArrayList(u8)) void {
    print.put(out, "#<ref ");
    print.write(load(r, r_value), out, true);
    print.put(out, ">");
}

fn checkRef(r: Value, what: []const u8) void {
    if (!isRef(r)) rt.raise(.type_error, "{s} needs a ref, not {s}", .{ what, typeName(r) });
}

fn typeName(v: Value) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    print.write(v, &buf, true);
    return buf.items;
}

/// The keys of a map, as a vector.
fn keysOf(m: Value) Value {
    const Ctx = struct {
        out: Value,
        fn add(c: *@This(), k: Value, _: Value) bool {
            c.out = coll.vectorConj(c.out, k);
            return true;
        }
    };
    var ctx: Ctx = .{ .out = coll.vectorOf(&.{}) };
    coll.mapEach(m, &ctx, Ctx.add);
    return ctx.out;
}

// ---------------------------------------------------------------------------------------
// Transactions

const Txn = struct {
    id: i64,
    /// The clock when the attempt began: every ref it reads must be no newer.
    rv: i64,
    body: Value,
    /// The block token of the attempt, which a conflict returns to.
    token: Value = Value.nil,
    retry: bool = false,
    /// ref -> true for the refs read (validated at commit).
    reads: Value,
    /// ref -> value: what the transaction wrote, which its own reads see.
    writes: Value,
    /// ref -> true for refs set by ref-set or alter (not only commuted).
    sets: Value,
    /// [ref f args] in order: commutes, applied again at commit to the latest values.
    commutes: Value,
    /// The refs this commit has locked so far.
    locked: Value,
};

/// The transaction this fiber is running, if any.
fn current() ?*Txn {
    if (running.load(.acquire) == 0) return null;
    var f = cond.topFrame();
    while (f) |fr| : (f = fr.prev) {
        if (fr.kind == @intFromEnum(cond.Kind.transaction))
            return @ptrFromInt(@as(usize, @intCast(fr.value.toFixnum())));
    }
    return null;
}

/// Signal an error if called in a transaction: `what` would run again on a retry.
pub fn forbidInTransaction(what: []const u8) void {
    if (current() != null)
        rt.raise(.@"error", "{s} can't run in a transaction (dosync): a retry would run it again", .{what});
}

/// Give up this attempt and run the transaction again.
fn conflict(tx: *Txn) noreturn {
    tx.retry = true;
    sk_return_from(tx.token, Value.nil);
}

/// A ref's committed value, checked as a read of `tx` (TL2): unlocked and no newer than
/// the transaction's read version, before and after the value is read.
fn readCommitted(tx: *Txn, r: Value) Value {
    const lock1 = load(r, r_lock);
    const v1 = load(r, r_version);
    const value = load(r, r_value);
    const lock2 = load(r, r_lock);
    const v2 = load(r, r_version);
    if (lock1 != Value.nil or lock2 != Value.nil or v1 != v2 or v1.toFixnum() > tx.rv) conflict(tx);
    return value;
}

fn txRead(tx: *Txn, r: Value) Value {
    if (coll.mapGet(tx.writes, r)) |v| return v;
    const v = readCommitted(tx, r);
    tx.reads = coll.mapAssoc(tx.reads, r, Value.true);
    return v;
}

fn txSet(tx: *Txn, r: Value, v: Value, what: []const u8) Value {
    if (coll.mapGet(tx.sets, r) == null and coll.mapGet(tx.writes, r) != null)
        rt.raise(.@"error", "{s} after commute of the same ref in one transaction", .{what});
    tx.writes = coll.mapAssoc(tx.writes, r, v);
    tx.sets = coll.mapAssoc(tx.sets, r, Value.true);
    return v;
}

fn needTransaction(what: []const u8) *Txn {
    return current() orelse rt.raise(.@"error", "{s} needs a transaction: call it in dosync", .{what});
}

/// deref of a ref: in a transaction, its view; else the committed value.
pub fn deref(r: Value) Value {
    if (current()) |tx| return txRead(tx, r);
    return load(r, r_value);
}

fn refSet(r: Value, v: Value) Value {
    checkRef(r, "ref-set");
    return txSet(needTransaction("ref-set"), r, v, "ref-set");
}

/// (f current args...), with the arguments after the first two of a.
fn apply(f: Value, current_value: Value, rest: []const Value) Value {
    var buf: [16]Value = undefined;
    if (rest.len + 1 > buf.len) rt.raise(.@"error", "alter and commute take at most 15 arguments for f", .{});
    buf[0] = current_value;
    @memcpy(buf[1 .. rest.len + 1], rest);
    return func.call(f, @intCast(rest.len + 1), &buf);
}

fn alter(a: []const Value) Value {
    checkRef(a[0], "alter");
    const tx = needTransaction("alter");
    return txSet(tx, a[0], apply(a[1], txRead(tx, a[0]), a[2..]), "alter");
}

/// commute: the transaction sees (f value args...) now; at commit f runs again on the
/// latest committed value, so concurrent commutes of a ref don't conflict.
fn commute(a: []const Value) Value {
    checkRef(a[0], "commute");
    const tx = needTransaction("commute");
    const r = a[0];
    const base = if (coll.mapGet(tx.writes, r)) |v| v else readCommitted(tx, r);
    const v = apply(a[1], base, a[2..]);
    tx.writes = coll.mapAssoc(tx.writes, r, v);
    var args = coll.vectorOf(&.{});
    for (a[2..]) |x| args = coll.vectorConj(args, x);
    tx.commutes = coll.vectorConj(tx.commutes, coll.vectorOf(&.{ r, a[1], args }));
    return v;
}

/// ensure: read the ref in the transaction. Transactions are serializable, so every read
/// is protected as Clojure's ensure protects one.
fn ensure(r: Value) Value {
    checkRef(r, "ensure");
    return txRead(needTransaction("ensure"), r);
}

// Committing

fn unlockAll(tx: *Txn) void {
    const locked = tx.locked;
    for (0..coll.vectorCount(locked)) |i| {
        const r = coll.vectorNth(locked, i).?;
        if (load(r, r_lock) == Value.fromFixnum(tx.id)) @atomicStore(Value, &slots(r)[r_lock], Value.nil, .release);
    }
    tx.locked = coll.vectorOf(&.{});
}

const Commit = struct { tx: *Txn, ok: bool = false };

fn commitBody(ctx: *anyopaque) callconv(.c) Value {
    const c: *Commit = @ptrCast(@alignCast(ctx));
    const tx = c.tx;
    const me = Value.fromFixnum(tx.id);
    // Lock what it writes; a ref another commit holds is a conflict.
    var it = keysOf(tx.writes);
    for (0..coll.vectorCount(it)) |i| {
        const r = coll.vectorNth(it, i).?;
        if (@cmpxchgStrong(Value, &slots(r)[r_lock], Value.nil, me, .acq_rel, .acquire) != null) return Value.nil;
        tx.locked = coll.vectorConj(tx.locked, r);
    }
    const wv = clock.fetchAdd(1, .acq_rel) + 1;
    // What it read must not have changed since it began.
    if (wv != tx.rv + 1) {
        it = keysOf(tx.reads);
        for (0..coll.vectorCount(it)) |i| {
            const r = coll.vectorNth(it, i).?;
            const lock = load(r, r_lock);
            if ((lock != Value.nil and lock != me) or load(r, r_version).toFixnum() > tx.rv) return Value.nil;
        }
    }
    // Commutes of refs it didn't set run again on the latest values, in order.
    var fresh = coll.mapOf(&.{});
    for (0..coll.vectorCount(tx.commutes)) |i| {
        const op = coll.vectorNth(tx.commutes, i).?;
        const r = coll.vectorNth(op, 0).?;
        if (coll.mapGet(tx.sets, r) != null) continue;
        const base = coll.mapGet(fresh, r) orelse load(r, r_value);
        const args = coll.vectorNth(op, 2).?;
        var rest: [15]Value = undefined;
        const n = coll.vectorCount(args);
        for (0..n) |k| rest[k] = coll.vectorNth(args, k).?;
        fresh = coll.mapAssoc(fresh, r, apply(coll.vectorNth(op, 1).?, base, rest[0..n]));
    }
    it = keysOf(tx.writes);
    for (0..coll.vectorCount(it)) |i| {
        const r = coll.vectorNth(it, i).?;
        const v = coll.mapGet(fresh, r) orelse coll.mapGet(tx.writes, r).?;
        const h = r.toObject();
        gc.store(h, &h.valueSlots()[r_value], v);
        @atomicStore(Value, &slots(r)[r_version], Value.fromFixnum(wv), .release);
    }
    c.ok = true;
    return Value.nil;
}

fn commitCleanup(ctx: *anyopaque) callconv(.c) Value {
    const c: *Commit = @ptrCast(@alignCast(ctx));
    unlockAll(c.tx);
    return Value.nil;
}

/// Commit tx; false on a conflict. Locks are released however the commit ends (a commute
/// function can signal an error).
fn commit(tx: *Txn) bool {
    if (coll.mapCount(tx.writes) == 0) return true; // read-only: each read was checked
    var c: Commit = .{ .tx = tx };
    _ = sk_eval_unwind_protect(commitBody, commitCleanup, &c);
    return c.ok;
}

fn attemptBody(ctx: *anyopaque) callconv(.c) Value {
    const tx: *Txn = @ptrCast(@alignCast(ctx));
    return func.call(tx.body, 0, &.{});
}

/// Wait a little before trying again, longer the more tries failed.
fn backoff(tries: u32) void {
    const sched = @import("sched.zig");
    if (tries < 8 or !sched.inFiber()) {
        if (sched.inFiber()) sched.yield();
        return;
    }
    const spins = @min(tries, 64);
    for (0..spins) |_| sched.yield();
}

/// dosync: run body (a function of no arguments) in a transaction and return its value. In
/// a transaction already, it joins it.
pub fn dosync(body: Value) Value {
    if (current() != null) return func.call(body, 0, &.{});
    _ = running.fetchAdd(1, .acq_rel);
    defer _ = running.fetchSub(1, .acq_rel);
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (tries == max_tries)
            rt.raise(.@"error", "the transaction retried {d} times: other transactions keep changing what it reads", .{max_tries});
        if (tries > 0) backoff(tries);
        const empty = coll.mapOf(&.{});
        var tx: Txn = .{ .id = next_id.fetchAdd(1, .monotonic), .rv = clock.load(.acquire), .body = body, .reads = empty, .writes = empty, .sets = empty, .commutes = coll.vectorOf(&.{}), .locked = coll.vectorOf(&.{}) };
        var frame: cond.Frame = undefined;
        cond.pushFrame(&frame, .transaction);
        frame.value = Value.fromFixnum(@intCast(@intFromPtr(&tx)));
        const v = sk_eval_block(attemptBody, &tx, &tx.token);
        cond.popFrame(&frame);
        if (tx.retry) continue;
        if (commit(&tx)) return v;
    }
}

// ---------------------------------------------------------------------------------------
// skein.core functions (core.zig's table includes these)

const Args = []const Value;
const CoreEntry = @import("compiler.zig").Entry;

pub const entries = [_]CoreEntry{
    .{ .name = "ref", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return makeRef(a[0]);
        }
    }.f },
    .{ .name = "ref?", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return Value.fromBool(isRef(a[0]));
        }
    }.f },
    .{ .name = "%dosync", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return dosync(a[0]);
        }
    }.f },
    .{ .name = "%in-transaction?", .min = 0, .max = 0, .impl = struct {
        fn f(_: Args) Value {
            return Value.fromBool(current() != null);
        }
    }.f },
    .{ .name = "ref-set", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return refSet(a[0], a[1]);
        }
    }.f },
    .{ .name = "alter", .min = 2, .max = null, .impl = struct {
        fn f(a: Args) Value {
            return alter(a);
        }
    }.f },
    .{ .name = "commute", .min = 2, .max = null, .impl = struct {
        fn f(a: Args) Value {
            return commute(a);
        }
    }.f },
    .{ .name = "ensure", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return ensure(a[0]);
        }
    }.f },
};
