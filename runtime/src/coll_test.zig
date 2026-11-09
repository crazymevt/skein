//! Tests of the persistent collections (M1.4): randomized operations checked against
//! models (ArrayList, AutoHashMap), persistence of old versions, transients, hash
//! collisions, garbage collections in between, and hashes and printing that match
//! Phase 0's.

const std = @import("std");
const gc = @import("gc.zig");
const coll = @import("coll.zig");
const equal = @import("equal.zig");
const names = @import("names.zig");
const num = @import("num.zig");
const string = @import("string.zig");
const print = @import("print.zig");
const Value = @import("value.zig").Value;
const testing = std.testing;

fn int(n: i64) Value {
    return num.fromI128(n);
}

fn printed(v: Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    print.write(v, &out, true);
    return out.items;
}

fn expectPrinted(expected: []const u8, v: Value) !void {
    try testing.expectEqualStrings(expected, try printed(v));
}

test "hashes match Phase 0's hash-of" {
    coll.ensureConstants();
    const cases = [_]struct { Value, u32 }{
        .{ int(0), 0 },
        .{ int(1), 1364076727 },
        .{ int(-1), 2039857924 },
        .{ int(-5), 3259012296 },
        .{ num.parseInteger("2305843009213693952"), 4276485314 },
        .{ num.parseInteger("-98765432109876543210"), 3099610871 },
        .{ num.boxF64(1.5), 2321223580 },
        .{ num.boxF64(0.0), 0 },
        .{ num.boxF64(-0.0), 0 },
        .{ Value.fromF32(1.5), 2321223580 },
        .{ string.make("abc"), 482950588 },
        .{ string.make("héllo"), 1472820488 },
        .{ names.keyword(null, "k"), 504291544 },
        .{ names.keyword("ns", "k"), 3177073433 },
        .{ names.symbol(null, "sym"), 162143021 },
        .{ names.symbol("ns", "sym"), 1295643607 },
        .{ coll.vectorOf(&.{ int(1), int(2) }), 1213202630 },
        .{ coll.listOf(&.{ int(1), int(2) }), 1213202630 },
        .{ coll.mapOf(&.{ names.keyword(null, "a"), int(1) }), 2648385476 },
        .{ coll.setOf(&.{ int(1), int(2) }), 3896902397 },
        .{ Value.nil, 0 },
        .{ Value.true, 1231 },
        .{ Value.false, 1237 },
        .{ Value.fromChar('c'), 2622321114 },
        .{ coll.empty_list, 1364076727 },
        .{ coll.empty_vector, 1364076727 },
        .{ coll.empty_map, 0 },
        .{ coll.vectorOf(&.{ string.make("x"), names.keyword(null, "y"), num.boxF64(3.5) }), 3961311990 },
    };
    for (cases, 0..) |c, i| {
        if (equal.hashOf(c[0]) != c[1]) {
            std.debug.print("case {d} ({s}): got {d}, want {d}\n", .{ i, try printed(c[0]), equal.hashOf(c[0]), c[1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "vectors match an ArrayList model, and old versions don't change" {
    coll.ensureConstants();
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    var model: std.ArrayList(i64) = .empty;
    defer model.deinit(testing.allocator);
    var v = coll.empty_vector;
    // Snapshots of earlier versions and what they held.
    var snaps: [8]Value = undefined;
    var snap_models: [8]std.ArrayList(i64) = @splat(.empty);
    defer for (&snap_models) |*m| m.deinit(testing.allocator);
    for (0..20_000) |step| {
        const r = random.uintLessThan(u8, 10);
        if (r < 6 or model.items.len == 0) {
            const x = random.int(i32);
            v = coll.vectorConj(v, int(x));
            try model.append(testing.allocator, x);
        } else if (r < 8) {
            const i = random.uintLessThan(usize, model.items.len);
            const x = random.int(i32);
            v = coll.vectorAssoc(v, i, int(x));
            model.items[i] = x;
        } else {
            v = coll.vectorPop(v);
            _ = model.pop();
        }
        if (step % 2500 == 0) {
            const k = step / 2500;
            snaps[k] = v;
            snap_models[k].clearRetainingCapacity();
            try snap_models[k].appendSlice(testing.allocator, model.items);
            gc.collect(if (k % 2 == 0) .minor else .major);
        }
    }
    try testing.expectEqual(model.items.len, coll.vectorCount(v));
    for (model.items, 0..) |x, i| try testing.expectEqual(x, coll.vectorNth(v, i).?.toFixnum());
    for (snaps, snap_models) |s, m| {
        try testing.expectEqual(m.items.len, coll.vectorCount(s));
        for (m.items, 0..) |x, i| try testing.expectEqual(x, coll.vectorNth(s, i).?.toFixnum());
    }
}

test "transient vectors grow past several trie levels and shrink back" {
    coll.ensureConstants();
    var t = coll.vectorTransient(coll.empty_vector);
    const n = 40_000; // 32^3 = 32768, so the trie gets a third level
    for (0..n) |i| t = coll.tvectorConj(t, int(@intCast(i)));
    t = coll.tvectorAssoc(t, 12345, int(-1));
    for (0..n - 10) |_| t = coll.tvectorPop(t);
    const v = coll.tvectorPersistent(t);
    try testing.expectEqual(@as(usize, 10), coll.vectorCount(v));
    for (0..10) |i| try testing.expectEqual(@as(i64, @intCast(i)), coll.vectorNth(v, i).?.toFixnum());
    // Big persistent vectors too.
    var big = coll.empty_vector;
    for (0..n) |i| big = coll.vectorConj(big, int(@intCast(i)));
    gc.collect(.major);
    try testing.expectEqual(@as(i64, 33000), coll.vectorNth(big, 33000).?.toFixnum());
    var p = big;
    for (0..n - 1) |_| p = coll.vectorPop(p);
    try testing.expectEqual(@as(usize, 1), coll.vectorCount(p));
    try testing.expectEqual(@as(usize, n), coll.vectorCount(big));
}

/// A key that collides with `k` (same hash, different value): fold32 XORs the two halves,
/// so adding the same 32-bit chunk above and below cancels out.
fn collider(k: i64) Value {
    const big: i128 = (@as(i128, k) << 64) | (@as(i128, k) << 32) | k;
    return num.fromI128(big);
}

test "maps match a HashMap model, with collisions, transients and old versions" {
    coll.ensureConstants();
    var prng = std.Random.DefaultPrng.init(2);
    const random = prng.random();
    var model: std.AutoHashMap(i64, i64) = .init(testing.allocator);
    defer model.deinit();
    var m = coll.empty_map;
    const key = struct {
        fn of(k: i64) Value {
            // Keys >= 1000 are colliding bignums.
            return if (k < 1000) int(k) else collider(k - 1000 + 1);
        }
    }.of;
    var saved = m;
    var saved_model: std.AutoHashMap(i64, i64) = .init(testing.allocator);
    defer saved_model.deinit();
    for (0..30_000) |step| {
        const k: i64 = if (random.boolean()) random.intRangeLessThan(i64, 0, 600) else random.intRangeLessThan(i64, 1000, 1040);
        if (random.uintLessThan(u8, 3) < 2) {
            const val = random.int(i32);
            m = coll.mapAssoc(m, key(k), int(val));
            try model.put(k, val);
        } else {
            m = coll.mapDissoc(m, key(k));
            _ = model.remove(k);
        }
        if (step == 15_000) {
            saved = m;
            saved_model = try model.clone();
            gc.collect(.major);
        }
        if (step % 5000 == 0) gc.collect(.minor);
    }
    try testing.expectEqual(model.count(), coll.mapCount(m));
    var it = model.iterator();
    while (it.next()) |e| try testing.expectEqual(e.value_ptr.*, coll.mapGet(m, key(e.key_ptr.*)).?.toFixnum());
    try testing.expectEqual(saved_model.count(), coll.mapCount(saved));
    var it2 = saved_model.iterator();
    while (it2.next()) |e| try testing.expectEqual(e.value_ptr.*, coll.mapGet(saved, key(e.key_ptr.*)).?.toFixnum());
    try testing.expectEqual(@as(?Value, null), coll.mapGet(m, int(99999)));

    // The same through a transient, then back to a persistent map.
    var t = coll.mapTransient(coll.empty_map);
    var tm: std.AutoHashMap(i64, i64) = .init(testing.allocator);
    defer tm.deinit();
    for (0..10_000) |_| {
        const k: i64 = if (random.boolean()) random.intRangeLessThan(i64, 0, 300) else random.intRangeLessThan(i64, 1000, 1020);
        if (random.uintLessThan(u8, 3) < 2) {
            const val = random.int(i32);
            t = coll.tmapAssoc(t, key(k), int(val));
            try tm.put(k, val);
        } else {
            t = coll.tmapDissoc(t, key(k));
            _ = tm.remove(k);
        }
    }
    const p = coll.tmapPersistent(t);
    try testing.expectEqual(tm.count(), coll.mapCount(p));
    var it3 = tm.iterator();
    while (it3.next()) |e| try testing.expectEqual(e.value_ptr.*, coll.mapGet(p, key(e.key_ptr.*)).?.toFixnum());
}

test "small maps stay array maps in insertion order, then become HAMTs" {
    coll.ensureConstants();
    var m = coll.empty_map;
    for (0..8) |i| m = coll.mapAssoc(m, names.keyword(null, &.{@intCast('a' + i)}), int(@intCast(i)));
    try testing.expect(m.isObjectOf(.array_map));
    try expectPrinted("{:a 0, :b 1, :c 2, :d 3, :e 4, :f 5, :g 6, :h 7}", m);
    m = coll.mapAssoc(m, names.keyword(null, "i"), int(8));
    try testing.expect(m.isObjectOf(.hash_map));
    // Back down through a transient: an array map again.
    var t = coll.mapTransient(m);
    t = coll.tmapDissoc(t, names.keyword(null, "a"));
    try testing.expect(coll.tmapPersistent(t).isObjectOf(.array_map));
}

test "sets, equality across types, and printing" {
    coll.ensureConstants();
    var s = coll.empty_set;
    for (0..100) |i| s = coll.setConj(s, int(@intCast(i % 37)));
    try testing.expectEqual(@as(usize, 37), coll.setCount(s));
    s = coll.setDisj(s, int(5));
    try testing.expect(!coll.setContains(s, int(5)) and coll.setContains(s, int(6)));
    try testing.expect(equal.equiv(coll.vectorOf(&.{ int(1), int(2) }), coll.listOf(&.{ int(1), int(2) })));
    try testing.expect(!equal.equiv(coll.vectorOf(&.{int(1)}), coll.vectorOf(&.{num.boxF64(1.0)})));
    try testing.expect(equal.equiv(coll.setOf(&.{ int(1), int(2) }), coll.setOf(&.{ int(2), int(1) })));
    try testing.expect(equal.equiv(coll.mapOf(&.{ int(1), string.make("a") }), coll.mapOf(&.{ int(1), string.make("a") })));
    try expectPrinted("[1 \"s\" \\c]", coll.vectorOf(&.{ int(1), string.make("s"), Value.fromChar('c') }));
    try expectPrinted("(1 2)", coll.listOf(&.{ int(1), int(2) }));
    try expectPrinted("()", coll.empty_list);
    try expectPrinted("#{1}", coll.setOf(&.{int(1)}));
    try expectPrinted(":ns/k", names.keyword("ns", "k"));
    try expectPrinted("ns/sym", names.symbol("ns", "sym"));
    try expectPrinted("#<atom [1 2]>", coll.makeAtom(coll.vectorOf(&.{ int(1), int(2) })));
    // Phase 0 prints this 12-entry map in this order.
    var m = coll.empty_map;
    for (0..12) |i| m = coll.mapAssoc(m, int(@intCast(i)), int(@intCast(i * i)));
    try expectPrinted("{0 0, 11 121, 7 49, 4 16, 2 4, 3 9, 6 36, 8 64, 5 25, 10 100, 9 81, 1 1}", m);
}

test "atoms compare and set" {
    coll.ensureConstants();
    const a = coll.makeAtom(int(1));
    try testing.expect(coll.atomCompareAndSet(a, int(1), int(2)));
    try testing.expect(!coll.atomCompareAndSet(a, int(1), int(3)));
    try testing.expectEqual(@as(i64, 2), coll.atomGet(a).toFixnum());
    _ = coll.atomReset(a, coll.vectorOf(&.{int(9)}));
    gc.collect(.minor);
    try expectPrinted("#<atom [9]>", a);
}

test "atoms lose no updates when threads race" {
    // Regression (M1.8 step 6): a successful compare-and-set stored the slot again,
    // which could undo another thread's newer value.
    coll.ensureConstants();
    const a = coll.makeAtom(int(0));
    const Worker = struct {
        fn run(at: Value) void {
            for (0..10_000) |_| {
                while (true) {
                    const old = coll.atomGet(at);
                    if (coll.atomCompareAndSet(at, old, int(old.toFixnum() + 1))) break;
                }
            }
        }
        fn join(arg: ?*anyopaque) void {
            const t: *std.Thread = @ptrCast(@alignCast(arg));
            t.join();
        }
    };
    // More threads than cores, so that some are preempted between the two stores.
    var threads: [24]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{a});
    for (&threads) |*t| gc.blocking(Worker.join, t);
    try testing.expectEqual(@as(i64, 240_000), coll.atomGet(a).toFixnum());
}
