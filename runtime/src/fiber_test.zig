//! Fibers with the rest of the runtime (M2.2 step 2, D-074): objects that only a
//! suspended fiber's stack holds survive collections, each fiber has its own condition
//! frames, and errors unwind inside a fiber with other fibers switched in between.

const std = @import("std");
const fiber = @import("fiber.zig");
const gc = @import("gc.zig");
const cond = @import("cond.zig");
const coll = @import("coll.zig");
const func = @import("func.zig");
const rt = @import("rt.zig");
const Value = @import("value.zig").Value;

const testing = std.testing;

fn setup() void {
    coll.ensureConstants();
    cond.ensureBuiltins();
}

/// Run every fiber in turn until all are done, collecting between rounds.
fn runAll(fibers: []*fiber.Fiber, collect_every: usize) void {
    var done = std.bit_set.DynamicBitSetUnmanaged.initEmpty(std.heap.c_allocator, fibers.len) catch unreachable;
    defer done.deinit(std.heap.c_allocator);
    var left = fibers.len;
    var round: usize = 0;
    while (left > 0) : (round += 1) {
        for (fibers, 0..) |f, i| {
            if (done.isSet(i)) continue;
            if (fiber.run(f)) {
                done.set(i);
                left -= 1;
            }
        }
        if (collect_every != 0 and round % collect_every == 0) {
            gc.collect(if (round % (2 * collect_every) == 0) .major else .minor);
        }
    }
}

/// A list of `n` nodes built while yielding, held only on the fiber's stack; returns
/// whether it came out intact.
const Builder = struct {
    n: usize,
    ok: bool = false,

    fn node(id: usize, next: Value) Value {
        const h = gc.alloc(.tuple, 2);
        const v = Value.fromObject(h);
        h.valueSlots()[0] = Value.fromFixnum(@intCast(id));
        gc.store(h, &h.valueSlots()[1], next);
        return v;
    }

    fn job(arg: ?*anyopaque) void {
        const self: *Builder = @ptrCast(@alignCast(arg));
        var head = Value.nil;
        for (0..self.n) |i| {
            head = node(i, head);
            // Garbage in between, so collections have work.
            _ = gc.alloc(.tuple, 8);
            if (i % 25 == 0) fiber.yield();
        }
        var count: usize = 0;
        var it = head;
        while (it != Value.nil) : (it = it.toObject().valueSlots()[1]) {
            if (it.toObject().valueSlots()[0].toFixnum() != @as(i64, @intCast(self.n - 1 - count))) return;
            count += 1;
        }
        self.ok = count == self.n;
    }
};

test "objects held only by suspended fibers' stacks survive collections" {
    setup();
    var builders: [300]Builder = undefined;
    var fibers: [300]*fiber.Fiber = undefined;
    for (&builders, &fibers, 0..) |*b, *f, i| {
        b.* = .{ .n = 200 + i };
        f.* = fiber.spawn(Builder.job, b);
    }
    runAll(&fibers, 3);
    for (builders) |b| try testing.expect(b.ok);
}

test "each fiber has its own condition frames" {
    setup();
    const Frames = struct {
        ok: bool = false,
        fn job(arg: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(arg));
            // A new fiber starts with no frames, whatever the thread had.
            if (cond.topFrame() != null) return;
            var frame: cond.Frame = undefined;
            cond.pushFrame(&frame, .block);
            fiber.yield();
            if (cond.topFrame() != &frame) return;
            cond.popFrame(&frame);
            self.ok = cond.topFrame() == null;
        }
    };
    var outer: cond.Frame = undefined;
    cond.pushFrame(&outer, .block);
    defer cond.popFrame(&outer);
    var a: Frames = .{};
    var b: Frames = .{};
    var fibers = [_]*fiber.Fiber{ fiber.spawn(Frames.job, &a), fiber.spawn(Frames.job, &b) };
    runAll(&fibers, 0);
    try testing.expect(a.ok and b.ok);
    try testing.expectEqual(&outer, cond.topFrame().?);
}

extern fn sk_try_call(f: Value, argc: u32, argv: [*]const Value, ntypes: u32, types: [*]Value) Value;

/// A function that yields, allocates, then signals an error.
fn yieldThenFail(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = self;
    _ = argc;
    _ = argv;
    fiber.yield();
    _ = gc.alloc(.tuple, 4);
    fiber.yield();
    rt.raise(.@"error", "failed in a fiber", .{});
}

const Catcher = struct {
    caught: usize = 0,
    fn job(arg: ?*anyopaque) void {
        const self: *Catcher = @ptrCast(@alignCast(arg));
        for (0..5) |_| {
            var types = [_]Value{cond.builtinType(.@"error")};
            const r = sk_try_call(func.make(yieldThenFail, "fail"), 0, &.{}, 1, &types);
            // [0 condition]: caught by this fiber's own handler.
            if (coll.vectorNth(r, 0).?.toFixnum() == 0) self.caught += 1;
            fiber.yield();
        }
    }
};

test "errors unwind inside a fiber while others are switched in between" {
    setup();
    var catchers: [50]Catcher = @splat(.{});
    var fibers: [50]*fiber.Fiber = undefined;
    for (&catchers, &fibers) |*c, *f| f.* = fiber.spawn(Catcher.job, c);
    runAll(&fibers, 7);
    for (catchers) |c| try testing.expectEqual(@as(usize, 5), c.caught);
}

fn recurseForever(depth: usize) usize {
    var pad: [512]u8 = undefined;
    std.mem.doNotOptimizeAway(&pad);
    pad[0] = @truncate(depth);
    return recurseForever(depth + 1) +% pad[0];
}

fn overflowStack(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = self;
    _ = argc;
    _ = argv;
    return Value.fromFixnum(@intCast(recurseForever(0) & 0xff));
}

const Overflower = struct {
    caught: usize = 0,
    fn job(arg: ?*anyopaque) void {
        const self: *Overflower = @ptrCast(@alignCast(arg));
        for (0..3) |_| {
            var types = [_]Value{cond.builtinType(.stack_overflow)};
            const r = sk_try_call(func.make(overflowStack, "overflow"), 0, &.{}, 1, &types);
            if (coll.vectorNth(r, 0).?.toFixnum() == 0) self.caught += 1;
            fiber.yield();
        }
    }
};

test "a stack overflow is an error in the fiber, which it can handle again and again" {
    setup();
    var a: Overflower = .{};
    var b: Overflower = .{};
    var fibers = [_]*fiber.Fiber{ fiber.spawn(Overflower.job, &a), fiber.spawn(Overflower.job, &b) };
    runAll(&fibers, 0);
    try testing.expectEqual(@as(usize, 3), a.caught);
    try testing.expectEqual(@as(usize, 3), b.caught);
    // The pooled stacks work as before.
    var builder: Builder = .{ .n = 100 };
    var more = [_]*fiber.Fiber{fiber.spawn(Builder.job, &builder)};
    runAll(&more, 1);
    try testing.expect(builder.ok);
}

// ---------------------------------------------------------------------------------------
// The scheduler on one thread (step 4)

const sched = @import("sched.zig");

test "the scheduler runs ready fibers in turn" {
    setup();
    const Turns = struct {
        id: u8,
        log: *std.ArrayList(u8),
        fn job(arg: ?*anyopaque) void {
            const t: *@This() = @ptrCast(@alignCast(arg));
            for (0..3) |_| {
                t.log.append(testing.allocator, t.id) catch unreachable;
                sched.yield();
            }
        }
    };
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    var turns = [_]Turns{ .{ .id = 'a', .log = &log }, .{ .id = 'b', .log = &log }, .{ .id = 'c', .log = &log } };
    for (&turns) |*t| sched.spawn(Turns.job, t);
    try testing.expectEqual(@as(usize, 3), sched.runUntilIdle());
    try testing.expectEqualStrings("abcabcabc", log.items);
}

test "a parked fiber runs again once it's woken" {
    setup();
    const Shared = struct {
        sleeper: ?*fiber.Fiber = null,
        log: [4]u8 = undefined,
        n: usize = 0,
        fn note(s: *@This(), c: u8) void {
            s.log[s.n] = c;
            s.n += 1;
        }
        fn sleepJob(arg: ?*anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(arg));
            s.sleeper = sched.currentFiber();
            s.note('p');
            sched.park();
            s.note('r');
        }
        fn wakeJob(arg: ?*anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(arg));
            s.note('w');
            sched.wake(s.sleeper.?);
            s.note('d');
        }
    };
    var s: Shared = .{};
    sched.spawn(Shared.sleepJob, &s);
    sched.spawn(Shared.wakeJob, &s);
    try testing.expectEqual(@as(usize, 2), sched.runUntilIdle());
    try testing.expectEqualStrings("pwdr", s.log[0..s.n]);
}

/// The exit test of M2.2: 100,000 fibers, all alive at once, each building a list that
/// only its stack holds while it yields, with garbage in between; collections happen as
/// they allocate.
const Worker = struct {
    ok: bool = false,
    fn job(arg: ?*anyopaque) void {
        const self: *Worker = @ptrCast(@alignCast(arg));
        var head = Value.nil;
        for (0..8) |i| {
            head = Builder.node(i, head);
            _ = gc.alloc(.tuple, 32);
            sched.yield();
        }
        var count: usize = 0;
        var it = head;
        while (it != Value.nil) : (it = it.toObject().valueSlots()[1]) {
            if (it.toObject().valueSlots()[0].toFixnum() != @as(i64, @intCast(7 - count))) return;
            count += 1;
        }
        self.ok = count == 8;
    }
};

test "100,000 fibers that yield and allocate run under collections" {
    setup();
    const count = 100_000;
    const workers = try testing.allocator.alloc(Worker, count);
    defer testing.allocator.free(workers);
    const before = gc.stats();
    for (workers) |*w| {
        w.* = .{};
        sched.spawn(Worker.job, w);
    }
    try testing.expectEqual(@as(usize, count), sched.runUntilIdle());
    for (workers) |w| try testing.expect(w.ok);
    const after = gc.stats();
    try testing.expect(after.minor_collections + after.major_collections >
        before.minor_collections + before.major_collections + 5);
}
