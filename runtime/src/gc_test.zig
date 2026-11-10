//! Stress tests for the garbage collector (M1.3), including random object graphs checked
//! against a model kept outside the heap.

const std = @import("std");
const gc = @import("gc.zig");
const object = @import("object.zig");
const Header = object.Header;
const Value = @import("value.zig").Value;
const testing = std.testing;

fn tuple(n: usize) Value {
    return Value.fromObject(gc.alloc(.tuple, n));
}

fn slots(v: Value) []Value {
    return v.toObject().valueSlots();
}

fn set(obj: Value, i: usize, v: Value) void {
    const h = obj.toObject();
    gc.store(h, &h.valueSlots()[i], v);
}

/// A node: slot 0 its id (a fixnum), then `fanout` child slots.
fn node(id: usize, fanout: usize) Value {
    const v = tuple(1 + fanout);
    slots(v)[0] = Value.fromFixnum(@intCast(id));
    for (slots(v)[1..]) |*s| s.* = Value.nil;
    return v;
}

fn idOf(v: Value) usize {
    return @intCast(slots(v)[0].toFixnum());
}

test "rooted objects survive minor and major collections and are updated when they move" {
    var roots: [64]Value = @splat(Value.nil);
    gc.addRoots(&roots);
    defer gc.removeRoots(&roots);
    for (&roots, 0..) |*r, i| r.* = node(i, 2);
    for (0..10) |round| {
        // Churn the nursery so the roots' objects have to move or be kept.
        for (0..2000) |_| _ = tuple(8);
        gc.collect(if (round % 3 == 2) .major else .minor);
        for (roots, 0..) |r, i| {
            try testing.expect(r.isObjectOf(.tuple));
            try testing.expectEqual(i, idOf(r));
            try testing.expect(r.toObject().gc.old);
        }
    }
}

test "objects that only the stack refers to are pinned, not moved" {
    var keep = node(7, 1);
    std.mem.doNotOptimizeAway(&keep);
    const address = @intFromPtr(keep.toObject());
    // An interior pointer is enough too.
    var inner_obj = tuple(4);
    std.mem.doNotOptimizeAway(&inner_obj);
    slots(inner_obj)[3] = Value.fromFixnum(33);
    var inner: *u64 = &inner_obj.toObject().payload()[3];
    std.mem.doNotOptimizeAway(&inner);
    inner_obj = Value.nil;
    std.mem.doNotOptimizeAway(&inner_obj);

    gc.collect(.minor);
    try testing.expectEqual(address, @intFromPtr(keep.toObject()));
    try testing.expectEqual(@as(usize, 7), idOf(keep));
    try testing.expectEqual(@as(u64, @intFromEnum(Value.fromFixnum(33))), inner.*);
    gc.collect(.major);
    try testing.expectEqual(@as(usize, 7), idOf(keep));
    try testing.expectEqual(@as(u64, @intFromEnum(Value.fromFixnum(33))), inner.*);
}

test "garbage is reclaimed: allocating far more than fits stays bounded" {
    const before = gc.stats().committed_segments;
    var roots: [1]Value = .{Value.nil};
    gc.addRoots(&roots);
    defer gc.removeRoots(&roots);
    // 400 MiB of short-lived objects, keeping a small changing live set.
    for (0..400_000) |i| {
        const v = tuple(127);
        if (i % 1000 == 0) roots[0] = v;
    }
    const after = gc.stats().committed_segments;
    try testing.expect(after < before + 200); // far less than 400 MiB / 256 KiB = 1600
    try testing.expect(gc.stats().minor_collections > 10);
}

test "long chains and cycles are traced without recursion" {
    var roots: [1]Value = .{Value.nil};
    gc.addRoots(&roots);
    defer gc.removeRoots(&roots);
    // A 200,000-node chain from the root.
    var head = Value.nil;
    for (0..200_000) |i| {
        const n = node(i, 1);
        slots(n)[1] = head;
        head = n;
    }
    roots[0] = head;
    head = Value.nil;
    // A big unreachable cycle.
    {
        const first = node(0, 1);
        var prev = first;
        for (1..50_000) |i| {
            const n = node(i, 1);
            slots(prev)[1] = n;
            prev = n;
        }
        slots(prev)[1] = first;
    }
    gc.collect(.major);
    gc.collect(.major);
    var count: usize = 0;
    var it = roots[0];
    while (it != Value.nil) : (it = slots(it)[1]) {
        try testing.expectEqual(199_999 - count, idOf(it));
        count += 1;
    }
    try testing.expectEqual(@as(usize, 200_000), count);
}

/// Zero a stretch of the stack below the caller, so that pointers left in dead frames
/// don't keep objects alive (the collector scans stacks conservatively).
noinline fn scrubStack() void {
    var buf: [64 * 1024]u8 = undefined;
    @memset(&buf, 0);
    std.mem.doNotOptimizeAway(&buf);
}

noinline fn makeBig(roots: []Value) void {
    const big = tuple(100_000); // 800 KiB: a large object
    for (slots(big), 0..) |*s, i| s.* = Value.fromFixnum(@intCast(i));
    set(big, 99_999, node(5, 0));
    roots[0] = big;
}

noinline fn checkBig(roots: []Value) !void {
    try testing.expectEqual(@as(i64, 12345), slots(roots[0])[12345].toFixnum());
    try testing.expectEqual(@as(usize, 5), idOf(slots(roots[0])[99_999]));
}

test "large objects survive while reachable and are freed after" {
    var roots: [1]Value = .{Value.nil};
    gc.addRoots(&roots);
    defer gc.removeRoots(&roots);
    // Everything that touches the object happens in other frames, so this one never
    // holds a pointer to it.
    makeBig(&roots);
    scrubStack();
    gc.collect(.minor);
    gc.collect(.major);
    try checkBig(&roots);
    roots[0] = Value.nil;
    // A conservative collector can't promise to free any one object (a stale stack word
    // may still point at it), but dropped large objects as a whole must come back:
    // 100 of them take 400 segments.
    const before = gc.stats().committed_segments;
    for (0..100) |_| makeBig(&roots);
    roots[0] = Value.nil;
    scrubStack();
    gc.collect(.major);
    try testing.expect(gc.stats().committed_segments < before + 40);
}

test "the write barrier keeps young objects that only old objects refer to" {
    var roots: [1]Value = .{Value.nil};
    gc.addRoots(&roots);
    defer gc.removeRoots(&roots);
    roots[0] = node(1, 4);
    gc.collect(.minor); // roots[0] is now old
    try testing.expect(roots[0].toObject().gc.old);
    for (1..5) |i| set(roots[0], i, node(100 + i, 0)); // young objects, old parent
    for (0..5000) |_| _ = tuple(16);
    gc.collect(.minor);
    for (1..5) |i| try testing.expectEqual(100 + i, idOf(slots(roots[0])[i]));
    gc.collect(.major);
    for (1..5) |i| try testing.expectEqual(100 + i, idOf(slots(roots[0])[i]));
}

/// The model of a random graph: each node's children, by id.
const Model = struct {
    children: std.ArrayList([4]?usize) = .empty,

    fn deinit(m: *Model) void {
        m.children.deinit(testing.allocator);
    }
};

fn checkGraph(roots: []const Value, root_ids: []const ?usize, model: *const Model) !void {
    var seen: std.AutoHashMap(usize, void) = .init(testing.allocator);
    defer seen.deinit();
    var stack: std.ArrayList(struct { Value, usize }) = .empty;
    defer stack.deinit(testing.allocator);
    for (roots, root_ids) |r, id| {
        if (id) |i| {
            try testing.expect(r.isObjectOf(.tuple));
            try stack.append(testing.allocator, .{ r, i });
        } else try testing.expectEqual(Value.nil, r);
    }
    while (stack.pop()) |entry| {
        const v, const id = entry;
        try testing.expectEqual(id, idOf(v));
        if ((try seen.getOrPut(id)).found_existing) continue;
        for (model.children.items[id], 1..) |child, k| {
            const s = slots(v)[k];
            if (child) |c| {
                try testing.expect(s.isObjectOf(.tuple));
                try stack.append(testing.allocator, .{ s, c });
            } else try testing.expectEqual(Value.nil, s);
        }
    }
}

test "random graphs match a model across many collections" {
    var prng = std.Random.DefaultPrng.init(0x6c);
    const random = prng.random();
    var model: Model = .{};
    defer model.deinit();
    var roots: [32]Value = @splat(Value.nil);
    var root_ids: [32]?usize = @splat(null);
    gc.addRoots(&roots);
    defer gc.removeRoots(&roots);

    for (0..60) |round| {
        for (0..3000) |_| {
            switch (random.uintLessThan(u8, 10)) {
                // A new node in a random root.
                0...3 => {
                    const id = model.children.items.len;
                    try model.children.append(testing.allocator, @splat(null));
                    const r = random.uintLessThan(usize, roots.len);
                    roots[r] = node(id, 4);
                    root_ids[r] = id;
                },
                // Link one rooted node to another rooted node (or clear a link).
                4...7 => {
                    const a = random.uintLessThan(usize, roots.len);
                    if (root_ids[a] == null) continue;
                    const k = random.uintLessThan(usize, 4);
                    const b = random.uintLessThan(usize, roots.len);
                    set(roots[a], 1 + k, roots[b]);
                    model.children.items[root_ids[a].?][k] = root_ids[b];
                },
                // Drop a root; follow a link from it first sometimes.
                8 => {
                    const a = random.uintLessThan(usize, roots.len);
                    const k = random.uintLessThan(usize, 4);
                    if (root_ids[a]) |id| {
                        roots[a] = slots(roots[a])[1 + k];
                        root_ids[a] = model.children.items[id][k];
                    }
                },
                // Garbage.
                else => _ = tuple(random.uintLessThan(usize, 300)),
            }
        }
        gc.collect(if (round % 7 == 6) .major else .minor);
        try checkGraph(&roots, &root_ids, &model);
    }
}

test "threads allocate and collect concurrently" {
    const Worker = struct {
        fn run(seed: u64, ok: *std.atomic.Value(bool)) void {
            _ = gc.attachThread();
            defer gc.detachThread();
            var roots: [1]Value = .{Value.nil};
            gc.addRoots(&roots);
            defer gc.removeRoots(&roots);
            var prng = std.Random.DefaultPrng.init(seed);
            const random = prng.random();
            // Build a list of 20,000 nodes, with garbage in between, collecting at times.
            for (0..20_000) |i| {
                const n = node(i, 1);
                slots(n)[1] = roots[0];
                roots[0] = n;
                _ = tuple(random.uintLessThan(usize, 64));
                if (i % 5000 == 4999) gc.collect(if (random.boolean()) .minor else .major);
            }
            var count: usize = 0;
            var it = roots[0];
            while (it != Value.nil) : (it = slots(it)[1]) {
                if (idOf(it) != 19_999 - count) return;
                count += 1;
            }
            if (count == 20_000) ok.store(true, .release);
        }

        fn join(arg: ?*anyopaque) void {
            const t: *std.Thread = @ptrCast(@alignCast(arg));
            t.join();
        }
    };
    var ok: [4]std.atomic.Value(bool) = undefined;
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        ok[i] = .init(false);
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ i + 1, &ok[i] });
    }
    // This thread is attached too, so it waits in a blocking call, where collections
    // can go ahead without it.
    for (&threads) |*t| gc.blocking(Worker.join, t);
    for (&ok) |*o| try testing.expect(o.load(.acquire));
}

test "finalizers run for objects that die, minor and major" {
    const Counter = struct {
        var dead: usize = 0;
        fn f(_: *Header) void {
            dead += 1;
        }
    };
    Counter.dead = 0;
    var roots: [2]Value = .{ Value.nil, Value.nil };
    gc.addRoots(&roots);
    defer gc.removeRoots(&roots);
    // Many die young; one survives a minor collection (moving) and dies in a major one;
    // one lives on. A stale stack word may keep a dead object alive (the stack is scanned
    // conservatively), so the young ones are counted with some slack.
    const Make = struct {
        noinline fn make(r: []Value) void {
            for (0..100) |_| gc.addFinalizer(tuple(2).toObject(), Counter.f);
            r[0] = tuple(2);
            gc.addFinalizer(r[0].toObject(), Counter.f);
            r[1] = tuple(2);
            gc.addFinalizer(r[1].toObject(), Counter.f);
        }
    };
    Make.make(&roots);
    scrubStack();
    gc.collect(.minor);
    const young = Counter.dead;
    try testing.expect(young >= 95 and young <= 100);
    roots[0] = Value.nil;
    scrubStack();
    gc.collect(.major);
    try testing.expect(Counter.dead >= young + 1);
    const after = Counter.dead;
    gc.collect(.major);
    try testing.expectEqual(after, Counter.dead);
    // The live one is still finalizable, and not finalized.
    try testing.expect(roots[1].isObject());
}


test "callbacks from C enter and leave the runtime: from blocking calls and other threads" {
    const Callback = struct {
        /// What a callback does: build a list on the stack only, collecting meanwhile.
        fn work(ok: *std.atomic.Value(bool)) void {
            var head = Value.nil;
            for (0..3000) |i| {
                const n = node(i, 1);
                slots(n)[1] = head;
                head = n;
                _ = tuple(16);
                if (i % 1000 == 999) gc.collect(if (i % 2000 == 999) .minor else .major);
            }
            var count: usize = 0;
            var it = head;
            while (it != Value.nil) : (it = slots(it)[1]) {
                if (idOf(it) != 2999 - count) return;
                count += 1;
            }
            if (count == 3000) ok.store(true, .release);
        }

        /// C, called by Skein as a blocking call, calls back.
        fn fromBlocking(arg: ?*anyopaque) void {
            const ok: *std.atomic.Value(bool) = @ptrCast(@alignCast(arg));
            const e = gc.enterFromC();
            defer gc.leaveToC(e);
            if (e != .native) return;
            work(ok);
        }

        /// A thread the runtime doesn't know calls back, twice.
        fn fromForeignThread(ok: *std.atomic.Value(bool)) void {
            for (0..2) |_| {
                var done: std.atomic.Value(bool) = .init(false);
                const e = gc.enterFromC();
                if (e == .attached) work(&done);
                gc.leaveToC(e);
                if (!done.load(.acquire)) return;
            }
            ok.store(true, .release);
        }

        fn join(arg: ?*anyopaque) void {
            const t: *std.Thread = @ptrCast(@alignCast(arg));
            t.join();
        }
    };
    _ = gc.attachThread();
    var foreign_ok: [2]std.atomic.Value(bool) = .{ .init(false), .init(false) };
    var threads: [2]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Callback.fromForeignThread, .{&foreign_ok[i]});
    var blocking_ok: std.atomic.Value(bool) = .init(false);
    gc.blocking(Callback.fromBlocking, &blocking_ok);
    for (&threads) |*t| gc.blocking(Callback.join, t);
    try testing.expect(blocking_ok.load(.acquire));
    for (&foreign_ok) |*o| try testing.expect(o.load(.acquire));
    // The foreign threads left: collections don't wait for them.
    gc.collect(.major);
}

test "a permanent allocation during another thread's collection parks for it" {
    // Regression (M2.6): allocPermanent waited for a collection without parking, so the
    // collector waited for that thread forever. One thread makes permanent objects while
    // another collects again and again.
    const Worker = struct {
        fn permanents(done: *std.atomic.Value(bool)) void {
            _ = gc.attachThread();
            defer gc.detachThread();
            for (0..20_000) |_| _ = gc.allocPermanent(.tuple, 2);
            done.store(true, .release);
        }
        fn collections(done: *std.atomic.Value(bool)) void {
            _ = gc.attachThread();
            defer gc.detachThread();
            while (!done.load(.acquire)) gc.collect(.minor);
        }
        fn join(arg: ?*anyopaque) void {
            const t: *std.Thread = @ptrCast(@alignCast(arg));
            t.join();
        }
    };
    var done = std.atomic.Value(bool).init(false);
    var a = try std.Thread.spawn(.{}, Worker.permanents, .{&done});
    var b = try std.Thread.spawn(.{}, Worker.collections, .{&done});
    gc.blocking(Worker.join, &a);
    gc.blocking(Worker.join, &b);
    try testing.expect(done.load(.acquire));
}
