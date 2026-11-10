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
const CONDITION_VARIABLE = extern struct { ptr: ?*anyopaque = null };
const INFINITE: u32 = 0xFFFFFFFF;

extern "kernel32" fn VirtualAlloc(address: ?*anyopaque, size: usize, allocation_type: u32, protect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(address: ?*anyopaque, size: usize, free_type: u32) callconv(.winapi) i32;
extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn SleepConditionVariableSRW(cv: *CONDITION_VARIABLE, lock: *SRWLOCK, milliseconds: u32, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn WakeAllConditionVariable(cv: *CONDITION_VARIABLE) callconv(.winapi) void;
extern "kernel32" fn GetCurrentThreadStackLimits(low: *usize, high: *usize) callconv(.winapi) void;
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(frequency: *i64) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn TryAcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) u8;
extern "kernel32" fn SwitchToThread() callconv(.winapi) i32;
extern "kernel32" fn CreateThread(attributes: ?*anyopaque, stack_size: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, parameter: ?*anyopaque, flags: u32, id: ?*u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CloseHandle(handle: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetActiveProcessorCount(group: u16) callconv(.winapi) u32;
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

    /// Lock `m` if it is free; return whether it did.
    pub fn tryLock(m: *Mutex) bool {
        return TryAcquireSRWLockExclusive(&m.inner) != 0;
    }
};

/// Give up the rest of this thread's time slice.
pub fn yieldThread() void {
    _ = SwitchToThread();
}

/// A condition variable, used with `Mutex`.
pub const Condition = struct {
    inner: CONDITION_VARIABLE = .{},

    /// Atomically unlock `m` and wait; `m` is locked again on return. Wakeups can be
    /// spurious, so callers re-check their condition in a loop.
    pub fn wait(cond: *Condition, m: *Mutex) void {
        _ = SleepConditionVariableSRW(&cond.inner, &m.inner, INFINITE, 0);
    }

    pub fn broadcast(cond: *Condition) void {
        WakeAllConditionVariable(&cond.inner);
    }

    /// Like `wait`, but return after at most `nanos` nanoseconds.
    pub fn timedWait(cond: *Condition, m: *Mutex, nanos: u64) void {
        const ms: u32 = @intCast(@max(1, @min(nanos / std.time.ns_per_ms, 0xFFFFFFFE)));
        _ = SleepConditionVariableSRW(&cond.inner, &m.inner, ms, 0);
    }
};

const ThreadStart = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;

const ThreadArg = struct { f: ThreadStart, arg: ?*anyopaque };

fn threadMain(p: ?*anyopaque) callconv(.winapi) u32 {
    const a: *ThreadArg = @ptrCast(@alignCast(p));
    const f = a.f;
    const arg = a.arg;
    std.heap.page_allocator.destroy(a);
    _ = f(arg);
    return 0;
}

/// Start a detached thread running `f(arg)` with a stack of `stack_size` bytes.
pub fn spawnThread(f: ThreadStart, arg: ?*anyopaque, stack_size: usize) bool {
    const a = std.heap.page_allocator.create(ThreadArg) catch return false;
    a.* = .{ .f = f, .arg = arg };
    const h = CreateThread(null, stack_size, threadMain, a, 0, null) orelse {
        std.heap.page_allocator.destroy(a);
        return false;
    };
    _ = CloseHandle(h);
    return true;
}

/// The number of CPUs online.
pub fn cpuCount() usize {
    const n = GetActiveProcessorCount(0xFFFF);
    return if (n > 0) n else 1;
}

/// The address range of the current thread's stack: [low, high). Stacks grow down.
pub const StackBounds = struct { low: usize, high: usize };

pub fn currentStackBounds() StackBounds {
    var low: usize = 0;
    var high: usize = 0;
    GetCurrentThreadStackLimits(&low, &high);
    return .{ .low = low, .high = high };
}

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

/// The process's environment, for spawning programs (std.process wants it passed in).
pub fn processEnviron() std.process.Environ {
    return .{ .block = .global };
}

// ---------------------------------------------------------------------------------------
// C libraries (the FFI, M1.10)

/// "windows": which entry of a deflibrary spec applies.
pub const os_name = "windows";

/// The separator of SKEIN_LIBRARY_PATH's directories.
pub const path_list_separator = ';';

/// Directories searched for C libraries before the system's places: none on Windows.
pub const library_directories: []const []const u8 = &.{};

/// Where a program's assets are, relative to the directory of its executable
/// (skein.io/resource-dir, D-073): the executable's own directory.
pub fn resourceSubdirectory(exe_dir: []const u8) []const u8 {
    _ = exe_dir;
    return "";
}

/// Where a packaged program keeps its C libraries, relative to the executable's directory
/// (D-069): beside it.
pub const executable_library_directories: []const []const u8 = &.{""};

extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn K32EnumProcessModules(process: *anyopaque, modules: [*]?*anyopaque, size: u32, needed: *u32) callconv(.winapi) i32;

/// Load the C library at `path` (UTF-8); null if it can't be loaded, with the reason in
/// `why` when there is room.
pub fn loadLibrary(path: [:0]const u8, why: []u8) ?*anyopaque {
    var wide: [1024]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], path) catch return null;
    wide[n] = 0;
    if (LoadLibraryW(@ptrCast(&wide))) |h| return h;
    const msg = std.fmt.bufPrint(why[0 .. why.len - 1], "error {d}", .{GetLastError()}) catch "";
    why[msg.len] = 0;
    return null;
}

/// The address of `name` in the library `handle`, or null.
pub fn librarySymbol(handle: *anyopaque, name: [:0]const u8) ?*anyopaque {
    return GetProcAddress(handle, name.ptr);
}

/// The address of `name` in any module the process has loaded, or null.
pub fn processSymbol(name: [:0]const u8) ?*anyopaque {
    var modules: [512]?*anyopaque = undefined;
    var needed: u32 = 0;
    if (K32EnumProcessModules(GetCurrentProcess(), &modules, @sizeOf(@TypeOf(modules)), &needed) == 0) return null;
    const count = @min(needed / @sizeOf(?*anyopaque), modules.len);
    for (modules[0..count]) |m| {
        if (m) |module| if (GetProcAddress(module, name.ptr)) |p| return p;
    }
    return null;
}
