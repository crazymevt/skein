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
