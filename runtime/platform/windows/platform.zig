//! The platform layer for Windows (DESIGN §19.3): virtual memory, a mutex, a monotonic
//! clock and console output, on the Win32 API. platform/posix/ provides the same
//! declarations for macOS and Linux.

const std = @import("std");

pub const page_size_min = std.heap.page_size_min;

const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_DECOMMIT: u32 = 0x4000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_NOACCESS: u32 = 0x01;
const PAGE_READWRITE: u32 = 0x04;
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));

const SRWLOCK = extern struct { ptr: ?*anyopaque = null };

extern "kernel32" fn VirtualAlloc(address: ?*anyopaque, size: usize, allocation_type: u32, protect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(address: ?*anyopaque, size: usize, free_type: u32) callconv(.winapi) i32;
extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(frequency: *i64) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(file: ?*anyopaque, buffer: [*]const u8, count: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) i32;

/// The size of a virtual memory page.
pub fn pageSize() usize {
    return std.heap.pageSize();
}

pub const MemoryError = error{OutOfMemory};

/// Reserve `len` bytes of address space (a multiple of the page size) with no access.
/// Touching it faults until `commit` makes it usable.
pub fn reserve(len: usize) MemoryError![]align(page_size_min) u8 {
    const p = VirtualAlloc(null, len, MEM_RESERVE, PAGE_NOACCESS) orelse return error.OutOfMemory;
    return @as([*]align(page_size_min) u8, @ptrCast(@alignCast(p)))[0..len];
}

/// Make reserved memory readable and writable. Newly committed pages read as zero.
pub fn commit(mem: []align(page_size_min) u8) MemoryError!void {
    if (VirtualAlloc(mem.ptr, mem.len, MEM_COMMIT, PAGE_READWRITE) == null)
        return error.OutOfMemory;
}

/// Give committed memory back to the OS but keep the address range reserved.
pub fn decommit(mem: []align(page_size_min) u8) void {
    _ = VirtualFree(mem.ptr, mem.len, MEM_DECOMMIT);
}

/// Return reserved memory (committed or not) to the OS.
pub fn release(mem: []align(page_size_min) u8) void {
    _ = VirtualFree(mem.ptr, 0, MEM_RELEASE);
}

/// A mutual-exclusion lock that blocks in the OS when contended.
pub const Mutex = struct {
    inner: SRWLOCK = .{},

    pub fn lock(m: *Mutex) void {
        AcquireSRWLockExclusive(&m.inner);
    }

    pub fn unlock(m: *Mutex) void {
        ReleaseSRWLockExclusive(&m.inner);
    }
};

/// Nanoseconds from a monotonic clock with an arbitrary start.
pub fn monotonicNanos() u64 {
    var count: i64 = 0;
    var frequency: i64 = 1;
    _ = QueryPerformanceCounter(&count);
    _ = QueryPerformanceFrequency(&frequency);
    const ns = @as(u128, @intCast(count)) * std.time.ns_per_s / @as(u128, @intCast(frequency));
    return @intCast(ns);
}

/// Write bytes to standard output, ignoring errors.
pub fn writeStdout(bytes: []const u8) void {
    writeAll(GetStdHandle(STD_OUTPUT_HANDLE), bytes);
}

/// Write bytes to standard error, ignoring errors.
pub fn writeStderr(bytes: []const u8) void {
    writeAll(GetStdHandle(STD_ERROR_HANDLE), bytes);
}

fn writeAll(handle: ?*anyopaque, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const chunk: u32 = @intCast(@min(rest.len, std.math.maxInt(u32)));
        var written: u32 = 0;
        if (WriteFile(handle, rest.ptr, chunk, &written, null) == 0 or written == 0) return;
        rest = rest[written..];
    }
}
