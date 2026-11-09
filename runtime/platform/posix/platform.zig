//! The platform layer for macOS and Linux (DESIGN §19.3): virtual memory, a mutex, a
//! monotonic clock and console output, on POSIX and libc. The Windows layer in
//! platform/windows/ provides the same declarations.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

pub const page_size_min = std.heap.page_size_min;

/// The size of a virtual memory page.
pub fn pageSize() usize {
    return std.heap.pageSize();
}

pub const MemoryError = error{OutOfMemory};

/// Reserve `len` bytes of address space (a multiple of the page size) with no access.
/// Touching it faults until `commit` makes it usable.
pub fn reserve(len: usize) MemoryError![]align(page_size_min) u8 {
    return posix.mmap(null, len, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch
        error.OutOfMemory;
}

/// Make reserved memory readable and writable. Newly committed pages read as zero.
pub fn commit(mem: []align(page_size_min) u8) MemoryError!void {
    if (c.mprotect(@ptrCast(mem.ptr), mem.len, .{ .READ = true, .WRITE = true }) != 0)
        return error.OutOfMemory;
}

/// Give committed memory back to the OS but keep the address range reserved.
pub fn decommit(mem: []align(page_size_min) u8) void {
    // Mapping fresh no-access pages over the range drops the old ones.
    _ = posix.mmap(mem.ptr, mem.len, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0) catch {};
}

/// Return reserved memory (committed or not) to the OS.
pub fn release(mem: []align(page_size_min) u8) void {
    posix.munmap(mem);
}

/// A mutual-exclusion lock that blocks in the OS when contended.
pub const Mutex = struct {
    inner: c.pthread_mutex_t = .{},

    pub fn lock(m: *Mutex) void {
        _ = c.pthread_mutex_lock(&m.inner);
    }

    pub fn unlock(m: *Mutex) void {
        _ = c.pthread_mutex_unlock(&m.inner);
    }

    /// Lock `m` if it is free; return whether it did.
    pub fn tryLock(m: *Mutex) bool {
        return c.pthread_mutex_trylock(&m.inner) == .SUCCESS;
    }
};

/// Give up the rest of this thread's time slice.
pub fn yieldThread() void {
    _ = c.sched_yield();
}

/// A condition variable, used with `Mutex`.
pub const Condition = struct {
    inner: c.pthread_cond_t = .{},

    /// Atomically unlock `m` and wait; `m` is locked again on return. Wakeups can be
    /// spurious, so callers re-check their condition in a loop.
    pub fn wait(cond: *Condition, m: *Mutex) void {
        _ = c.pthread_cond_wait(&cond.inner, &m.inner);
    }

    pub fn broadcast(cond: *Condition) void {
        _ = c.pthread_cond_broadcast(&cond.inner);
    }

    /// Like `wait`, but return after at most `nanos` nanoseconds.
    pub fn timedWait(cond: *Condition, m: *Mutex, nanos: u64) void {
        var now: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK.REALTIME, &now);
        const total = @as(u64, @intCast(now.nsec)) + nanos;
        var until: c.timespec = now;
        until.sec += @intCast(total / std.time.ns_per_s);
        until.nsec = @intCast(total % std.time.ns_per_s);
        _ = c.pthread_cond_timedwait(&cond.inner, &m.inner, &until);
    }
};

/// Start a detached thread running `f(arg)` with a stack of `stack_size` bytes.
pub fn spawnThread(f: *const fn (?*anyopaque) callconv(.c) ?*anyopaque, arg: ?*anyopaque, stack_size: usize) bool {
    var attr: c.pthread_attr_t = undefined;
    if (c.pthread_attr_init(&attr) != .SUCCESS) return false;
    defer _ = c.pthread_attr_destroy(&attr);
    _ = c.pthread_attr_setstacksize(&attr, stack_size);
    var thread: c.pthread_t = undefined;
    if (c.pthread_create(&thread, &attr, f, arg) != .SUCCESS) return false;
    _ = c.pthread_detach(thread);
    return true;
}

extern "c" fn sysconf(name: c_int) c_long;

/// The number of CPUs online.
pub fn cpuCount() usize {
    const name: c_int = if (builtin.os.tag == .macos) 58 else 84; // _SC_NPROCESSORS_ONLN
    const n = sysconf(name);
    return if (n > 0) @intCast(n) else 1;
}

/// The address range of the current thread's stack: [low, high). Stacks grow down.
pub const StackBounds = struct { low: usize, high: usize };

extern "c" fn pthread_get_stackaddr_np(thread: c.pthread_t) ?*anyopaque;
extern "c" fn pthread_get_stacksize_np(thread: c.pthread_t) usize;
extern "c" fn pthread_getattr_np(thread: c.pthread_t, attr: *c.pthread_attr_t) c_int;
extern "c" fn pthread_attr_getstack(attr: *const c.pthread_attr_t, addr: *?*anyopaque, size: *usize) c_int;

pub fn currentStackBounds() StackBounds {
    const self = c.pthread_self();
    switch (builtin.os.tag) {
        .macos => {
            const high = @intFromPtr(pthread_get_stackaddr_np(self));
            return .{ .low = high - pthread_get_stacksize_np(self), .high = high };
        },
        else => {
            var attr: c.pthread_attr_t = undefined;
            var addr: ?*anyopaque = null;
            var size: usize = 0;
            if (pthread_getattr_np(self, &attr) != 0) @panic("pthread_getattr_np failed");
            defer _ = c.pthread_attr_destroy(&attr);
            _ = pthread_attr_getstack(&attr, &addr, &size);
            return .{ .low = @intFromPtr(addr), .high = @intFromPtr(addr) + size };
        },
    }
}

/// Nanoseconds from a monotonic clock with an arbitrary start.
pub fn monotonicNanos() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Write bytes to standard output, ignoring errors.
pub fn writeStdout(bytes: []const u8) void {
    writeAll(1, bytes);
}

/// Write bytes to standard error, ignoring errors.
pub fn writeStderr(bytes: []const u8) void {
    writeAll(2, bytes);
}

fn writeAll(fd: c.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}
