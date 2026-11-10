//! Waiting (M2.3 step 2, D-075): what tasks, nurseries and channels wait with. A waiter
//! is a record on the waiting code's stack: in a fiber on a worker it parks the fiber, so
//! the worker runs others; on any other thread (the main thread, a foreign one) it waits
//! on a condition variable.
//!
//! Waiters queue under a key, the identity number of what they wait for (objects move in
//! collections; their identities don't). Whoever changes that thing notifies one or all
//! of its waiters. A waiter may also have a deadline, kept in a timer queue that the
//! scheduler's monitor thread fires.
//!
//! The protocol: with the lock that guards the thing held, check it; if it isn't ready,
//! `enqueue` a waiter, release the lock and `block`. The notifier changes the thing under
//! the same lock and calls `notifyOne` or `notifyAll`. A notification that comes between
//! the release and `block` isn't lost: `block` returns at once. Wake-ups can be spurious,
//! so the waiter checks again in a loop.

const std = @import("std");
const platform = @import("platform");
const sched = @import("sched.zig");
const gc = @import("gc.zig");
const rt = @import("rt.zig");

const Fiber = @import("fiber.zig").Fiber;
const alloc = std.heap.c_allocator;

pub const Waiter = struct {
    /// The waiting fiber, or null on a thread that isn't a worker.
    fiber: ?*Fiber,
    notified: std.atomic.Value(bool) = .init(false),
    /// Its place in a queue (key 0: in none).
    key: u64 = 0,
    prev: ?*Waiter = null,
    next: ?*Waiter = null,
    /// For a thread: what it sleeps on.
    lock: platform.Mutex = .{},
    cond: platform.Condition = .{},

    /// A waiter for the code running now.
    pub fn init() Waiter {
        return .{ .fiber = if (sched.inFiber()) sched.currentFiber() else null };
    }
};

// ---------------------------------------------------------------------------------------
// Queues

var lock: platform.Mutex = .{};
const Queue = struct { head: ?*Waiter = null, tail: ?*Waiter = null };
var queues: std.AutoHashMapUnmanaged(u64, Queue) = .empty;

/// Queue `w` under `key` (non-zero), oldest first.
pub fn enqueue(key: u64, w: *Waiter) void {
    std.debug.assert(key != 0 and w.key == 0);
    lock.lock();
    defer lock.unlock();
    const entry = queues.getOrPut(alloc, key) catch rt.fatal("out of memory (a wait queue)", .{});
    if (!entry.found_existing) entry.value_ptr.* = .{};
    const q = entry.value_ptr;
    w.key = key;
    w.prev = q.tail;
    w.next = null;
    if (q.tail) |t| t.next = w else q.head = w;
    q.tail = w;
}

/// Take `w` out of its queue, if it's in one (a waiter does when it stops waiting).
pub fn remove(w: *Waiter) void {
    lock.lock();
    defer lock.unlock();
    unlink(w);
}

fn unlink(w: *Waiter) void {
    if (w.key == 0) return;
    const q = queues.getPtr(w.key).?;
    if (w.prev) |p| p.next = w.next else q.head = w.next;
    if (w.next) |n| n.prev = w.prev else q.tail = w.prev;
    if (q.head == null) _ = queues.remove(w.key);
    w.key = 0;
    w.prev = null;
    w.next = null;
}

/// Wake the oldest waiter under `key`, taking it out of the queue; false if none waits.
pub fn notifyOne(key: u64) bool {
    lock.lock();
    defer lock.unlock();
    const q = queues.getPtr(key) orelse return false;
    const w = q.head.?;
    unlink(w);
    notify(w);
    return true;
}

/// Wake every waiter under `key`, emptying its queue.
pub fn notifyAll(key: u64) void {
    lock.lock();
    defer lock.unlock();
    while (queues.getPtr(key)) |q| {
        const w = q.head.?;
        unlink(w);
        notify(w);
    }
}

fn setWaiter(f: *Fiber, w: ?*Waiter) void {
    lock.lock();
    defer lock.unlock();
    f.waiter = w;
}

/// Wake fiber `f` if it's blocked on a waiter, as if it had been notified: a cancelled
/// task's fiber, which then finds its cancellation. Does nothing otherwise.
pub fn interrupt(f: *Fiber) void {
    lock.lock();
    defer lock.unlock();
    if (f.waiter) |p| notify(@ptrCast(@alignCast(p)));
}

/// How many waiters are queued under `key` (for tests).
pub fn waiting(key: u64) usize {
    lock.lock();
    defer lock.unlock();
    var n: usize = 0;
    var it = if (queues.getPtr(key)) |q| q.head else null;
    while (it) |w| : (it = w.next) n += 1;
    return n;
}

/// Wake `w` (it may be in no queue: a cancellation wakes its task's current waiter).
pub fn notify(w: *Waiter) void {
    // A waiter can return as soon as it sees `notified`, and it's usually on its stack:
    // nothing here touches it after that.
    if (w.fiber) |f| {
        w.notified.store(true, .release);
        sched.wake(f);
    } else {
        w.lock.lock();
        defer w.lock.unlock();
        w.notified.store(true, .release);
        w.cond.broadcast();
    }
}

// ---------------------------------------------------------------------------------------
// Timers: deadlines of parked fibers, fired by the scheduler's monitor thread

const Timer = struct { deadline: u64, waiter: *Waiter };

fn earlier(_: void, a: Timer, b: Timer) std.math.Order {
    return std.math.order(a.deadline, b.deadline);
}

var timer_lock: platform.Mutex = .{};
var timers = std.PriorityQueue(Timer, void, earlier).initContext({});

fn addTimer(w: *Waiter, deadline: u64) void {
    timer_lock.lock();
    timers.push(alloc, .{ .deadline = deadline, .waiter = w }) catch rt.fatal("out of memory (timers)", .{});
    timer_lock.unlock();
    // After the timer lock: the monitor takes its own lock, then this one.
    sched.timerAdded();
}

fn removeTimer(w: *Waiter) void {
    timer_lock.lock();
    defer timer_lock.unlock();
    for (timers.items, 0..) |t, i| {
        if (t.waiter == w) {
            _ = timers.popIndex(i);
            return;
        }
    }
}

/// For the monitor: wake the fibers whose deadlines have passed; return the next
/// deadline, or null.
pub fn fireTimers(now: u64) ?u64 {
    timer_lock.lock();
    defer timer_lock.unlock();
    while (timers.peek()) |t| {
        if (t.deadline > now) return t.deadline;
        _ = timers.pop();
        // The waiter is still blocked: it takes its own timer out before it returns.
        sched.wake(t.waiter.fiber.?);
    }
    return null;
}

// ---------------------------------------------------------------------------------------
// Blocking

pub const Outcome = enum { notified, deadline, tick };

/// Wait until `w` is notified, `deadline` (monotonic nanoseconds) passes, or, on a thread
/// that isn't a worker, `tick` nanoseconds have gone by (so it can do other work, like the
/// main thread's queue, and come back). The caller has queued `w` if it waits for a
/// notification, and takes it out of its queue afterwards unless it was notified.
pub fn block(w: *Waiter, deadline: ?u64, tick: ?u64) Outcome {
    if (w.fiber) |self| {
        std.debug.assert(self == sched.currentFiber());
        if (deadline) |d| addTimer(w, d);
        defer if (deadline != null) removeTimer(w);
        setWaiter(self, w);
        defer setWaiter(self, null);
        while (true) {
            if (w.notified.load(.acquire)) return .notified;
            if (deadline) |d| if (platform.monotonicNanos() >= d) return .deadline;
            sched.park();
        }
    }
    var call: ThreadWait = .{ .w = w, .deadline = deadline, .tick = tick };
    gc.blocking(threadWait, &call);
    return call.outcome;
}

const ThreadWait = struct { w: *Waiter, deadline: ?u64, tick: ?u64, outcome: Outcome = .notified };

fn threadWait(arg: ?*anyopaque) void {
    const c: *ThreadWait = @ptrCast(@alignCast(arg));
    const w = c.w;
    const start = platform.monotonicNanos();
    w.lock.lock();
    defer w.lock.unlock();
    while (!w.notified.load(.acquire)) {
        const now = platform.monotonicNanos();
        var until: u64 = std.math.maxInt(u64);
        if (c.deadline) |d| {
            if (now >= d) {
                c.outcome = .deadline;
                return;
            }
            until = d;
        }
        if (c.tick) |t| {
            if (now >= start + t) {
                c.outcome = .tick;
                return;
            }
            until = @min(until, start + t);
        }
        // Wake at least once a second to look again.
        w.cond.timedWait(&w.lock, @min(until - now, std.time.ns_per_s));
    }
    c.outcome = .notified;
}
