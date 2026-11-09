//! The platform layer for macOS and Linux (DESIGN §19.3): virtual memory, a mutex, a
//! monotonic clock and console output, on POSIX and libc. The Windows layer in
//! platform/windows/ provides the same declarations.

const std = @import("std");
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
};

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
