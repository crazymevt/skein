//! The fiber scheduler (M2.2 step 4, D-074; DESIGN §13.1): a run queue of fibers on one
//! thread. A fiber yields to let the others run, or parks until something wakes it (the
//! channels, sleeps and joins of M2.3 park and wake fibers). M2.3 spreads the queue over
//! worker threads with work stealing.

const std = @import("std");
const fiber = @import("fiber.zig");
const rt = @import("rt.zig");

const Fiber = fiber.Fiber;

/// Fibers ready to run, oldest first.
var queue: std.ArrayList(*Fiber) = .empty;
var head: usize = 0;
const alloc = std.heap.c_allocator;

fn push(f: *Fiber) void {
    queue.append(alloc, f) catch rt.fatal("out of memory (the run queue)", .{});
}

fn pop() ?*Fiber {
    if (head == queue.items.len) {
        queue.clearRetainingCapacity();
        head = 0;
        return null;
    }
    const f = queue.items[head];
    head += 1;
    // Drop the used front of the queue once it's most of it.
    if (head > 4096 and head * 2 > queue.items.len) {
        const rest = queue.items.len - head;
        std.mem.copyForwards(*Fiber, queue.items[0..rest], queue.items[head..]);
        queue.shrinkRetainingCapacity(rest);
        head = 0;
    }
    return f;
}

/// Start `job(arg)` in a new fiber; it runs when the scheduler gets to it.
pub fn spawn(job: fiber.Job, arg: ?*anyopaque) void {
    push(fiber.spawn(job, arg));
}

/// In a fiber: let the others run, and continue after them.
pub fn yield() void {
    const self = fiber.current();
    self.runnable = true;
    fiber.yield();
}

/// In a fiber: stop until `wake` is called on it.
pub fn park() void {
    fiber.current().runnable = false;
    fiber.yield();
}

/// Make a parked fiber run again.
pub fn wake(f: *Fiber) void {
    push(f);
}

/// The running fiber, for `wake` later.
pub fn currentFiber() *Fiber {
    return fiber.current();
}

/// On a thread's own stack: run fibers until none is ready. Returns how many finished.
pub fn runUntilIdle() usize {
    var finished: usize = 0;
    while (pop()) |f| {
        f.runnable = false;
        if (fiber.run(f)) {
            finished += 1;
        } else if (f.runnable) {
            push(f);
        }
    }
    return finished;
}
