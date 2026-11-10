//! The fiber scheduler (M2.3, D-075; DESIGN §13.1, §17.4): worker threads, one per CPU,
//! each with a deque of ready fibers, plus a shared injection queue. A worker runs its own
//! newest fiber first, then the injection queue's oldest, then steals another worker's
//! oldest; with nothing to do it sleeps until there is. Fibers move between workers.
//!
//! A fiber yields to let others run, or parks until something wakes it; the waits of
//! tasks and channels park. A fiber that has run for about 10 ms yields at its next
//! safepoint in compiled code: a monitor thread asks for it through sk_gc_pending's
//! preemption bit.

const std = @import("std");
const platform = @import("platform");
const fiber = @import("fiber.zig");
const wait = @import("wait.zig");
const gc = @import("gc.zig");
const rt = @import("rt.zig");
const Value = @import("value.zig").Value;

const Fiber = fiber.Fiber;
const alloc = std.heap.c_allocator;

/// How long a fiber runs before it's asked to yield, and how often the monitor looks.
const slice_ns: u64 = 10 * std.time.ns_per_ms;
const monitor_ns: u64 = 5 * std.time.ns_per_ms;
/// The longest an idle worker sleeps before looking again.
const idle_ns: u64 = 100 * std.time.ns_per_ms;
const worker_stack_size: usize = 8 * 1024 * 1024;

// ---------------------------------------------------------------------------------------
// Queues

/// A queue of fibers behind a lock: the owner takes from the back, others from the front.
const Deque = struct {
    lock: platform.Mutex = .{},
    items: std.ArrayList(*Fiber) = .empty,
    head: usize = 0,
    /// How many fibers it holds: kept under the lock, read without it (`anyWork`).
    count: std.atomic.Value(usize) = .init(0),

    fn len(q: *Deque) usize {
        return q.count.load(.acquire);
    }

    fn pushBack(q: *Deque, f: *Fiber) void {
        q.lock.lock();
        defer q.lock.unlock();
        q.items.append(alloc, f) catch rt.fatal("out of memory (a run queue)", .{});
        q.count.store(q.items.items.len - q.head, .release);
    }

    fn popBack(q: *Deque) ?*Fiber {
        q.lock.lock();
        defer q.lock.unlock();
        if (q.items.items.len == q.head) return null;
        const f = q.items.pop().?;
        q.compact();
        return f;
    }

    fn popFront(q: *Deque) ?*Fiber {
        q.lock.lock();
        defer q.lock.unlock();
        if (q.items.items.len == q.head) return null;
        const f = q.items.items[q.head];
        q.head += 1;
        q.compact();
        return f;
    }

    /// With the lock held, after taking a fiber.
    fn compact(q: *Deque) void {
        const rest = q.items.items.len - q.head;
        if (rest == 0) {
            q.items.clearRetainingCapacity();
            q.head = 0;
        } else if (q.head > 1024 and q.head * 2 > q.items.items.len) {
            std.mem.copyForwards(*Fiber, q.items.items[0..rest], q.items.items[q.head..]);
            q.items.shrinkRetainingCapacity(rest);
            q.head = 0;
        }
        q.count.store(rest, .release);
    }
};

// ---------------------------------------------------------------------------------------
// Workers

const Worker = struct {
    index: usize,
    deque: Deque = .{},
    /// The fiber it runs now, and since when (for preemption).
    running: std.atomic.Value(?*Fiber) = .init(null),
    slice_start: std.atomic.Value(u64) = .init(0),
    /// Set by the monitor when `running` should yield at its next safepoint.
    preempt: std.atomic.Value(bool) = .init(false),
};

var workers: []Worker = &.{};
var injection: Deque = .{};

var start_lock: platform.Mutex = .{};
var started = std.atomic.Value(bool).init(false);

var idle_lock: platform.Mutex = .{};
var idle_wake: platform.Condition = .{};
var sleepers: usize = 0;
/// Bumped whenever work is queued, so a worker about to sleep sees work it would miss.
var work_epoch = std.atomic.Value(u64).init(0);

/// Preemption requests not yet taken: sk_gc_pending's preemption bit is set while any is.
var preempt_requests = std.atomic.Value(u32).init(0);

/// The worker this thread is, or null.
threadlocal var my_worker_tls: ?*Worker = null;

/// Not inlined: a fiber can continue on another worker after a switch (D-075).
noinline fn myWorker() ?*Worker {
    return my_worker_tls;
}

/// How many workers there are (starting them if needed).
pub fn workerCount() usize {
    ensureStarted();
    return workers.len;
}

fn ensureStarted() void {
    if (started.load(.acquire)) return;
    start_lock.lock();
    defer start_lock.unlock();
    if (started.load(.acquire)) return;
    const n = @max(platform.cpuCount(), 2);
    workers = alloc.alloc(Worker, n) catch rt.fatal("out of memory (workers)", .{});
    for (workers, 0..) |*w, i| w.* = .{ .index = i };
    for (workers) |*w| {
        if (!platform.spawnThread(workerMain, w, worker_stack_size))
            rt.fatal("could not start a worker thread", .{});
    }
    if (!platform.spawnThread(monitorMain, null, 256 * 1024))
        rt.fatal("could not start the scheduler's monitor thread", .{});
    started.store(true, .release);
}

extern fn sk_mv_buffer() [*]Value;

fn workerMain(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const w: *Worker = @ptrCast(@alignCast(arg));
    _ = gc.attachThread();
    gc.addRoots(sk_mv_buffer()[0..64]);
    my_worker_tls = w;
    _ = fiber.current();
    while (true) {
        const f = findWork(w) orelse {
            sleepUntilWork();
            continue;
        };
        runFiber(w, f);
    }
}

/// Run `f` until it finishes, yields or parks, then put it where it belongs.
fn runFiber(w: *Worker, f: *Fiber) void {
    f.sched_state.store(.running, .release);
    f.runnable = false;
    w.slice_start.store(platform.monotonicNanos(), .release);
    w.running.store(f, .release);
    const finished = fiber.run(f);
    w.running.store(null, .release);
    if (w.preempt.swap(false, .acq_rel)) takePreemptRequest();
    if (finished) return;
    if (f.runnable) {
        // Yielded (or preempted): to the back of the shared queue, after the others.
        f.sched_state.store(.queued, .release);
        enqueueShared(f);
        return;
    }
    // Parking: unless a wake came while it was switching away, it waits for one.
    if (f.sched_state.cmpxchgStrong(.parking, .parked, .acq_rel, .acquire)) |state| {
        std.debug.assert(state == .wake_requested);
        f.sched_state.store(.queued, .release);
        w.deque.pushBack(f);
        notifyWork();
    }
}

fn findWork(w: *Worker) ?*Fiber {
    if (w.deque.popBack()) |f| return f;
    if (injection.popFront()) |f| return f;
    // Steal the oldest fiber of another worker, starting after this one.
    for (1..workers.len) |k| {
        const other = &workers[(w.index + k) % workers.len];
        if (other.deque.popFront()) |f| return f;
    }
    return null;
}

fn anyWork() bool {
    if (injection.len() > 0) return true;
    for (workers) |*w| if (w.deque.len() > 0) return true;
    return false;
}

const Sleep = struct { epoch: u64 };

fn sleepBlocking(arg: ?*anyopaque) void {
    const s: *Sleep = @ptrCast(@alignCast(arg));
    idle_lock.lock();
    defer idle_lock.unlock();
    if (work_epoch.load(.acquire) != s.epoch) return;
    sleepers += 1;
    idle_wake.timedWait(&idle_lock, idle_ns);
    sleepers -= 1;
}

/// Sleep until work is queued (or a while has passed), letting collections go on.
fn sleepUntilWork() void {
    var s: Sleep = .{ .epoch = work_epoch.load(.acquire) };
    if (anyWork()) return;
    gc.blocking(sleepBlocking, &s);
}

fn notifyWork() void {
    _ = work_epoch.fetchAdd(1, .acq_rel);
    idle_lock.lock();
    defer idle_lock.unlock();
    if (sleepers > 0) idle_wake.broadcast();
}

fn enqueueShared(f: *Fiber) void {
    injection.pushBack(f);
    notifyWork();
}

/// Queue a ready fiber: on this worker's deque, or the shared queue from other threads.
fn enqueue(f: *Fiber) void {
    if (myWorker()) |w| {
        w.deque.pushBack(f);
        notifyWork();
    } else enqueueShared(f);
}

// ---------------------------------------------------------------------------------------
// Preemption

var monitor_lock: platform.Mutex = .{};
var monitor_wake: platform.Condition = .{};

/// The monitor thread: every few milliseconds, or sooner when a timer is due, it fires
/// the timers that are due (wait.zig) and asks fibers that have run too long to yield.
fn monitorMain(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    monitor_lock.lock();
    var next_timer: ?u64 = null;
    while (true) {
        var sleep_ns = monitor_ns;
        if (next_timer) |t| sleep_ns = @max(@min(sleep_ns, t -| platform.monotonicNanos()), 1);
        monitor_wake.timedWait(&monitor_lock, sleep_ns);
        const now = platform.monotonicNanos();
        next_timer = wait.fireTimers(now);
        for (workers) |*w| {
            if (w.running.load(.acquire) == null) continue;
            if (now -| w.slice_start.load(.acquire) < slice_ns) continue;
            if (w.preempt.swap(true, .acq_rel)) continue;
            if (preempt_requests.fetchAdd(1, .acq_rel) == 0)
                _ = @atomicRmw(u8, &gc.sk_gc_pending, .Or, gc.pending_preemption, .acq_rel);
        }
    }
}

/// A waiter's timer was added (wait.zig): the monitor recomputes how long it sleeps.
pub fn timerAdded() void {
    ensureStarted();
    monitor_lock.lock();
    defer monitor_lock.unlock();
    monitor_wake.broadcast();
}

fn takePreemptRequest() void {
    if (preempt_requests.fetchSub(1, .acq_rel) == 1)
        _ = @atomicRmw(u8, &gc.sk_gc_pending, .And, ~gc.pending_preemption, .acq_rel);
}

/// At a safepoint in compiled code: if this fiber was asked to, yield to the others.
pub fn preemptionPoint() void {
    if (@atomicLoad(u8, &gc.sk_gc_pending, .acquire) & gc.pending_preemption == 0) return;
    const w = myWorker() orelse return;
    if (!w.preempt.swap(false, .acq_rel)) return;
    takePreemptRequest();
    // Only a fiber the worker runs yields: not the worker's own loop.
    if (w.running.load(.acquire) != fiber.current()) return;
    yield();
}

// ---------------------------------------------------------------------------------------
// The API

/// Start `job(arg)` in a new fiber, which a worker runs.
pub fn spawn(job: fiber.Job, arg: ?*anyopaque) void {
    ensureStarted();
    const f = fiber.spawn(job, arg);
    f.sched_state.store(.queued, .release);
    enqueue(f);
}

/// True when running in a fiber on a worker, where waiting parks instead of blocking.
pub fn inFiber() bool {
    const w = myWorker() orelse return false;
    return w.running.load(.acquire) == fiber.current();
}

/// The running fiber, for `wake` later.
pub fn currentFiber() *Fiber {
    return fiber.current();
}

/// In a fiber: let others run, and continue after them.
pub fn yield() void {
    fiber.current().runnable = true;
    fiber.yield();
}

/// In a fiber: stop until `wake` is called on it. Returns at once if a wake came since it
/// last parked, so callers check what they wait for in a loop.
pub fn park() void {
    const self = fiber.current();
    if (self.sched_state.cmpxchgStrong(.running, .parking, .acq_rel, .acquire)) |state| {
        // A wake already came.
        std.debug.assert(state == .wake_requested);
        self.sched_state.store(.running, .release);
        return;
    }
    self.runnable = false;
    fiber.yield();
}

/// Make `f` run again if it's parked, or keep its next park from waiting.
pub fn wake(f: *Fiber) void {
    while (true) {
        const state = f.sched_state.load(.acquire);
        switch (state) {
            .parked => if (f.sched_state.cmpxchgWeak(.parked, .queued, .acq_rel, .acquire) == null) {
                enqueue(f);
                return;
            },
            .running, .parking => if (f.sched_state.cmpxchgWeak(state, .wake_requested, .acq_rel, .acquire) == null) return,
            .queued, .wake_requested => return,
        }
    }
}

/// Waits, on a thread that isn't a worker (the main thread, a test), until `done` has
/// been called `n` times, letting collections go on.
pub const WaitGroup = struct {
    remaining: std.atomic.Value(usize),
    lock: platform.Mutex = .{},
    finished: platform.Condition = .{},

    pub fn init(n: usize) WaitGroup {
        return .{ .remaining = .init(n) };
    }

    /// Under the lock, so the waiter can't return (and free the group, often on its
    /// stack) before this has finished with it.
    pub fn done(g: *WaitGroup) void {
        g.lock.lock();
        defer g.lock.unlock();
        if (g.remaining.fetchSub(1, .acq_rel) == 1) g.finished.broadcast();
    }

    fn waitBlocking(arg: ?*anyopaque) void {
        const g: *WaitGroup = @ptrCast(@alignCast(arg));
        g.lock.lock();
        defer g.lock.unlock();
        while (g.remaining.load(.acquire) != 0) g.finished.timedWait(&g.lock, idle_ns);
    }

    pub fn wait(g: *WaitGroup) void {
        gc.blocking(waitBlocking, g);
    }
};
