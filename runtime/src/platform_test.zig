//! Tests of the platform layer: the same tests run against platform/posix on macOS and
//! Linux and against platform/windows on Windows.

const std = @import("std");
const platform = @import("platform");
const testing = std.testing;

test "page size is a power of two of at least 4 KiB" {
    const size = platform.pageSize();
    try testing.expect(size >= 4096 and std.math.isPowerOfTwo(size));
}

test "reserve, commit, decommit and release" {
    const page = platform.pageSize();
    const memory = try platform.reserve(16 * page);
    defer platform.release(memory);
    // Commit the middle of the range, use it, give it back, and commit it again.
    const middle: []align(platform.page_size_min) u8 = @alignCast(memory[4 * page .. 8 * page]);
    try platform.commit(middle);
    for (middle) |b| try testing.expectEqual(@as(u8, 0), b);
    @memset(middle, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), middle[middle.len - 1]);
    platform.decommit(middle);
    try platform.commit(middle);
    try testing.expectEqual(@as(u8, 0), middle[0]);
}

test "the monotonic clock never goes backwards" {
    var last = platform.monotonicNanos();
    for (0..10_000) |_| {
        const now = platform.monotonicNanos();
        try testing.expect(now >= last);
        last = now;
    }
}

test "the mutex excludes other threads" {
    const Shared = struct {
        mutex: platform.Mutex = .{},
        counter: u64 = 0,

        fn work(s: *@This()) void {
            for (0..100_000) |_| {
                s.mutex.lock();
                // A read-modify-write that loses updates without the lock.
                const v = s.counter;
                std.mem.doNotOptimizeAway(v);
                s.counter = v + 1;
                s.mutex.unlock();
            }
        }
    };
    var shared: Shared = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.work, .{&shared});
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u64, 400_000), shared.counter);
}

test "console output does not fail" {
    platform.writeStderr("");
    platform.writeStdout("");
}

test "the stack bounds contain the current stack" {
    const bounds = platform.currentStackBounds();
    var local: u64 = 0;
    std.mem.doNotOptimizeAway(&local);
    const here = @intFromPtr(&local);
    try testing.expect(bounds.low < here and here < bounds.high);
    try testing.expect(bounds.high - bounds.low >= 64 * 1024);
}

test "a condition variable wakes a waiting thread" {
    const Shared = struct {
        mutex: platform.Mutex = .{},
        cond: platform.Condition = .{},
        ready: bool = false,

        fn waiter(s: *@This()) void {
            s.mutex.lock();
            defer s.mutex.unlock();
            while (!s.ready) s.cond.wait(&s.mutex);
        }
    };
    var shared: Shared = .{};
    const t = try std.Thread.spawn(.{}, Shared.waiter, .{&shared});
    shared.mutex.lock();
    shared.ready = true;
    shared.cond.broadcast();
    shared.mutex.unlock();
    t.join();
}
