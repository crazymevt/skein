//! Fibers (M2.2, D-074; DESIGN §17.4): each runs on a stack of its own, reserved with a
//! guard page and committed as it's touched, and switches to other fibers in user space.
//! A fiber runs one job at a time; when the job finishes the fiber goes back to a pool
//! and is reused, stack and all, for a later job. Each OS thread also has a fiber that
//! stands for its own stack, so fibers can switch back to it.
//!
//! The collector scans the stack each thread is running on, and every suspended fiber's
//! from where it stopped; registers are spilled onto the stack before every switch. Each
//! fiber has its own chain of condition frames, saved and restored by the switch.

const std = @import("std");
const platform = @import("platform");
const rt = @import("rt.zig");
const gc = @import("gc.zig");
const cond = @import("cond.zig");

/// The usable stack of a fiber, above its guard page (D-024).
pub const default_stack_size: usize = 256 * 1024;

pub const Job = *const fn (?*anyopaque) void;

pub const Fiber = struct {
    ctx: platform.FiberContext = .{},
    /// Running on some thread; suspended (its stack holds live values from `scan_low`
    /// up); or idle in the pool.
    state: enum { running, suspended, idle } = .idle,
    scan_low: usize = 0,
    /// Its condition frames while it isn't running.
    cond_state: cond.FiberState = .{},
    /// What the fiber runs next; null while it's idle in the pool.
    job: ?Job = null,
    job_arg: ?*anyopaque = null,
    /// The fiber that last ran this one, which it switches back to when it yields or
    /// finishes.
    resumer: ?*Fiber = null,
    /// Set when its job has returned.
    done: bool = false,
    /// Set by a fiber that yields to be run again soon (sched.zig).
    runnable: bool = false,
    next_idle: ?*Fiber = null,
    /// Every fiber ever made, threads' own included, for the collector.
    next_all: ?*Fiber = null,
};

/// The fiber running on this OS thread.
threadlocal var current_fiber: ?*Fiber = null;

const alloc = std.heap.c_allocator;

var lock: platform.Mutex = .{};
var pool: ?*Fiber = null;
var all: ?*Fiber = null;

/// How many fibers have been made, and how many are idle in the pool (for tests).
pub var made: usize = 0;
pub var idle: usize = 0;

fn register(f: *Fiber) void {
    lock.lock();
    defer lock.unlock();
    f.next_all = all;
    all = f;
    gc.scan_suspended_fibers = scanSuspended;
}

/// For the collector, with the world stopped: each suspended fiber's live stack.
fn scanSuspended(visit: *const fn (usize, usize) void) void {
    var it = all;
    while (it) |f| : (it = f.next_all) {
        if (f.state == .suspended) visit(f.scan_low, f.ctx.high);
    }
}

/// The fiber running now (this thread's own, if no other).
pub fn current() *Fiber {
    if (current_fiber) |f| return f;
    // Threads' fibers are never freed: the list of all fibers may point at them.
    _ = gc.attachThread();
    platform.prepareThreadForFibers();
    const f = alloc.create(Fiber) catch rt.fatal("out of memory (a fiber)", .{});
    f.* = .{ .state = .running };
    platform.initThreadFiber(&f.ctx);
    register(f);
    current_fiber = f;
    return f;
}

// ---------------------------------------------------------------------------------------
// The pool of idle fibers

fn take() *Fiber {
    lock.lock();
    if (pool) |f| {
        pool = f.next_idle;
        idle -= 1;
        lock.unlock();
        f.next_idle = null;
        return f;
    }
    made += 1;
    lock.unlock();
    const f = alloc.create(Fiber) catch rt.fatal("out of memory (a fiber)", .{});
    f.* = .{};
    platform.createFiber(&f.ctx, default_stack_size, fiberMain, f) catch
        rt.fatal("out of memory (a fiber's stack)", .{});
    register(f);
    return f;
}

fn give(f: *Fiber) void {
    lock.lock();
    defer lock.unlock();
    f.next_idle = pool;
    pool = f;
    idle += 1;
}

/// A fiber's life: run each job it's given, then switch back to whoever ran it.
fn fiberMain(arg: ?*anyopaque) callconv(.c) noreturn {
    const self: *Fiber = @ptrCast(@alignCast(arg));
    // On Windows the stack's top is known only now that it runs.
    gc.setStackHigh(self.ctx.high);
    while (true) {
        self.job.?(self.job_arg);
        self.job = null;
        self.done = true;
        // The fiber that ran it puts it back in the pool once it has switched away.
        switchTo(self.resumer.?);
    }
}

// ---------------------------------------------------------------------------------------
// Running and switching

/// A fiber that will run `job(arg)` when it's run: an idle one, or a new one.
pub fn spawn(job: Job, arg: ?*anyopaque) *Fiber {
    const f = take();
    f.job = job;
    f.job_arg = arg;
    f.done = false;
    f.cond_state = .{};
    return f;
}

/// Run `f` until it yields or its job finishes. Returns true if the job finished, and
/// `f` is then back in the pool.
pub fn run(f: *Fiber) bool {
    f.resumer = current();
    switchTo(f);
    if (!f.done) return false;
    f.done = false;
    give(f);
    return true;
}

/// Switch back to the fiber that ran this one; return when it's run again.
pub fn yield() void {
    switchTo(current().resumer.?);
}

/// Where a fiber that overflowed its stack continues, in the room the platform opened
/// below it (D-024): signal the error there, like any other.
export fn sk_stack_overflow() callconv(.c) noreturn {
    rt.raise(.stack_overflow, "stack overflow: the fiber used all of its {d} KB stack", .{default_stack_size / 1024});
}

const Switch = struct { from: *Fiber, to: *Fiber };

extern fn sk_spill_registers_and_call(f: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void;

fn switchTo(to: *Fiber) void {
    var s: Switch = .{ .from = current(), .to = to };
    // With the registers spilled above this point, the suspended stack holds every value.
    sk_spill_registers_and_call(switchSpilled, &s);
}

fn switchSpilled(arg: ?*anyopaque) callconv(.c) void {
    const s: *Switch = @ptrCast(@alignCast(arg));
    var marker: usize = 0;
    std.mem.doNotOptimizeAway(&marker);
    const from = s.from;
    const to = s.to;
    from.scan_low = @intFromPtr(&marker);
    platform.fiberSwitchingOut(&from.ctx, @intFromPtr(&marker));
    from.cond_state = cond.saveFiberState();
    from.state = if (from.done) .idle else .suspended;
    // Whoever switches back to `from` sets these for it.
    to.state = .running;
    cond.restoreFiberState(to.cond_state);
    platform.fiberSwitchingIn(&to.ctx);
    current_fiber = to;
    gc.setStackHigh(to.ctx.high);
    platform.switchFiber(&from.ctx, &to.ctx);
}

// ---------------------------------------------------------------------------------------
// Tests (allocation, collections and conditions in fibers are in fiber_test.zig)

const testing = std.testing;

test "two fibers take turns" {
    const Counter = struct {
        n: usize = 0,
        fn job(arg: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(arg));
            for (0..1000) |_| {
                self.n += 1;
                yield();
            }
        }
    };
    var a: Counter = .{};
    var b: Counter = .{};
    const fa = spawn(Counter.job, &a);
    const fb = spawn(Counter.job, &b);
    var turns: usize = 0;
    var a_done = false;
    var b_done = false;
    while (!(a_done and b_done)) : (turns += 1) {
        if (!a_done) a_done = run(fa);
        if (!b_done) b_done = run(fb);
        try testing.expect(a.n == b.n or a.n == b.n + 1);
    }
    try testing.expectEqual(@as(usize, 1000), a.n);
    try testing.expectEqual(@as(usize, 1000), b.n);
    try testing.expectEqual(@as(usize, 1001), turns);
}

test "100,000 fibers each suspended at once, then finished" {
    const Job1 = struct {
        fn job(arg: ?*anyopaque) void {
            const n: *usize = @ptrCast(@alignCast(arg));
            yield();
            n.* += 1;
        }
    };
    const count = 100_000;
    const fibers = try testing.allocator.alloc(*Fiber, count);
    defer testing.allocator.free(fibers);
    var finished: usize = 0;
    for (fibers) |*f| {
        f.* = spawn(Job1.job, &finished);
        try testing.expect(!run(f.*));
    }
    for (fibers) |f| try testing.expect(run(f));
    try testing.expectEqual(@as(usize, count), finished);
    // They are all idle now, and reused for the next jobs.
    const before = made;
    for (0..1000) |_| {
        const f = spawn(Job1.job, &finished);
        _ = run(f);
        _ = run(f);
    }
    try testing.expectEqual(before, made);
}

test "a fiber can use most of its stack" {
    const Deep = struct {
        fn recurse(depth: usize) usize {
            var pad: [1024]u8 = undefined;
            std.mem.doNotOptimizeAway(&pad);
            pad[0] = @truncate(depth);
            return if (depth == 0) pad[0] else recurse(depth - 1) + pad[0];
        }
        fn job(arg: ?*anyopaque) void {
            const out: *usize = @ptrCast(@alignCast(arg));
            out.* = recurse(200); // about 200 KB of the 256 KB
        }
    };
    var out: usize = 0;
    try testing.expect(run(spawn(Deep.job, &out)));
    try testing.expect(out > 0);
}

test "floating-point state and registers survive switches" {
    const Float = struct {
        fn job(arg: ?*anyopaque) void {
            const out: *f64 = @ptrCast(@alignCast(arg));
            var x: f64 = 1.0;
            for (0..10) |i| {
                x = x * 1.5 + @as(f64, @floatFromInt(i));
                yield();
            }
            out.* = x;
        }
    };
    var a: f64 = 0;
    var b: f64 = 0;
    const fa = spawn(Float.job, &a);
    const fb = spawn(Float.job, &b);
    var a_done = false;
    var b_done = false;
    while (!(a_done and b_done)) {
        if (!a_done) a_done = run(fa);
        if (!b_done) b_done = run(fb);
    }
    try testing.expectEqual(a, b);
    var expected: f64 = 1.0;
    for (0..10) |i| expected = expected * 1.5 + @as(f64, @floatFromInt(i));
    try testing.expectEqual(expected, a);
}
